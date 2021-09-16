// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/SafeCastUpgradeable.sol";
import "../interfaces/IChainlinkOracle.sol";
import "../interfaces/IPrices.sol";
import "../utilities/AdminUpgradeable.sol";
import "../interfaces/IPrices.sol";
import "../interfaces/IDexOracle.sol";
import "../libs/SafeDecimalMath.sol";
import "../interfaces/IQuarterlyContractOracle.sol";

/**
 * @title OracleRouter
 *
 * @dev A contract for providing contracts with access to asset prices from multiple data
 * oracles including Chainlink Protocol.
 */
contract OracleRouter is AdminUpgradeable, IPrices {
    using SafeCastUpgradeable for int256;
    using SafeDecimalMath for uint256;
    using SafeMathUpgradeable for uint256;

    event GlobalStalePeriodUpdated(uint256 oldStalePeriod, uint256 newStalePeriod);
    event StalePeriodOverrideUpdated(bytes32 currencyKey, uint256 oldStalePeriod, uint256 newStalePeriod);
    event ChainlinkOracleAdded(bytes32 currencyKey, address oracle);
    event QuarterlyContractOracleAdded(bytes32 currencyKey, address oracle);
    event OracleRemoved(bytes32 currencyKey, address oracle);

    modifier onlyOracleSet(bytes32 currencyKey) {
        if (currencyKey != FUSD) {
            OracleSettings memory settings = oracleSettings[currencyKey];
            require(settings.oracleAddress != address(0), "OracleRouter: oracle not set");
        }
        _;
    }
    struct OracleSettings {
        uint8 oracleType;
        address oracleAddress;
    }

    uint256 public globalStalePeriod;
    mapping(bytes32 => uint256) public stalePeriodOverrides;
    mapping(bytes32 => OracleSettings) public oracleSettings;

    bytes32 public constant override FUSD = "FUSD";

    uint8 public constant ORACLE_TYPE_CHAINLINK = 1;
    uint8 public constant ORACLE_TYPE_QUARTERLY_CONTRACT = 2;
    uint8 public constant ORACLE_TYPE_DEX = 3;

    uint8 private constant OUTPUT_PRICE_DECIMALS = 18;

    function initialize(address _admin) public initializer {
        AdminUpgradeable.__AdminUpgradeable_init(_admin);
    }

    function isFrozen(bytes32 currencyKey) external view override onlyOracleSet(currencyKey) returns (bool) {
        OracleSettings memory settings = oracleSettings[currencyKey];
        if (settings.oracleType == ORACLE_TYPE_QUARTERLY_CONTRACT) {
            return IQuarterlyContractOracle(settings.oracleAddress).isFrozen(currencyKey);
        } else {
            return false;
        }
    }

    function setFrozen(bytes32 currencyKey, bool frozen) external override onlyOracleSet(currencyKey) {
        OracleSettings memory settings = oracleSettings[currencyKey];
        if (settings.oracleType == ORACLE_TYPE_QUARTERLY_CONTRACT) {
            return IQuarterlyContractOracle(settings.oracleAddress).setFrozen(currencyKey, frozen);
        }
    }

    function getPrice(bytes32 currencyKey) external view override returns (uint256) {
        (uint256 price, ) = _getPriceData(currencyKey);
        return price;
    }

    function getPriceAndUpdatedTime(bytes32 currencyKey) external view returns (uint256 price, uint256 time) {
        (price, time) = _getPriceData(currencyKey);
    }

    function isPriceStaled(bytes32 currencyKey) external view returns (bool) {
        if (currencyKey == FUSD) return false;
        (, uint256 time) = _getPriceData(currencyKey);
        return _isUpdateTimeStaled(time, getStalePeriodForCurrency(currencyKey));
    }

    function exchange(
        bytes32 sourceKey,
        uint256 sourceAmount,
        bytes32 destKey
    ) external view override returns (uint256) {
        if (sourceKey == destKey) return sourceAmount;

        (uint256 sourcePrice, uint256 sourceTime) = _getPriceData(sourceKey);
        (uint256 destPrice, uint256 destTime) = _getPriceData(destKey);

        require(
            !_isUpdateTimeStaled(sourceTime, getStalePeriodForCurrency(sourceKey)) &&
                !_isUpdateTimeStaled(destTime, getStalePeriodForCurrency(destKey)),
            "OracleRouter: staled price data"
        );

        return sourceAmount.multiplyDecimalRound(sourcePrice).divideDecimalRound(destPrice);
    }

    function getStalePeriodForCurrency(bytes32 currencyKey) public view returns (uint256) {
        uint256 overridenPeriod = stalePeriodOverrides[currencyKey];
        return overridenPeriod == 0 ? globalStalePeriod : overridenPeriod;
    }

    function setGlobalStalePeriod(uint256 newStalePeriod) external onlyAdmin {
        uint256 oldStalePeriod = globalStalePeriod;
        globalStalePeriod = newStalePeriod;
        emit GlobalStalePeriodUpdated(oldStalePeriod, newStalePeriod);
    }

    function setStalePeriodOverride(bytes32 currencyKey, uint256 newStalePeriod) external onlyAdmin {
        uint256 oldStalePeriod = stalePeriodOverrides[currencyKey];
        stalePeriodOverrides[currencyKey] = newStalePeriod;
        emit StalePeriodOverrideUpdated(currencyKey, oldStalePeriod, newStalePeriod);
    }

    function addChainlinkOracle(
        bytes32 currencyKey,
        address oracleAddress,
        bool removeExisting
    ) external onlyAdmin {
        _addChainlinkOracle(currencyKey, oracleAddress, removeExisting);
    }

    function addChainlinkOracles(
        bytes32[] calldata currencyKeys,
        address[] calldata oracleAddresses,
        bool removeExisting
    ) external onlyAdmin {
        require(
            currencyKeys.length == oracleAddresses.length,
            "OracleRouter - ChainlinkOracle : array length mismatch"
        );

        for (uint256 ind = 0; ind < currencyKeys.length; ind++) {
            _addChainlinkOracle(currencyKeys[ind], oracleAddresses[ind], removeExisting);
        }
    }

    function addQuarterlyContractOracle(
        bytes32 currencyKey,
        address oracleAddress,
        bool removeExisting
    ) external onlyAdmin {
        _addQuarterlyContractOracle(currencyKey, oracleAddress, removeExisting);
    }

    function addQuarterlyContractOracles(
        bytes32[] calldata currencyKeys,
        address[] calldata oracleAddresses,
        bool removeExisting
    ) external onlyAdmin {
        require(
            currencyKeys.length == oracleAddresses.length,
            "OracleRouter - QuarterlyContractOracle : array length mismatch"
        );

        for (uint256 ind = 0; ind < currencyKeys.length; ind++) {
            _addQuarterlyContractOracle(currencyKeys[ind], oracleAddresses[ind], removeExisting);
        }
    }

    function addDexOracle(
        bytes32 currencyKey,
        address oracleAddress,
        bool removeExisting
    ) external onlyAdmin {
        _addDexOracle(currencyKey, oracleAddress, removeExisting);
    }

    function addDexOracles(
        bytes32[] calldata currencyKeys,
        address[] calldata oracleAddresses,
        bool removeExisting
    ) external onlyAdmin {
        require(currencyKeys.length == oracleAddresses.length, "OracleRouter - DexOracle : array length mismatch");

        for (uint256 ind = 0; ind < currencyKeys.length; ind++) {
            _addDexOracle(currencyKeys[ind], oracleAddresses[ind], removeExisting);
        }
    }

    function removeOracle(bytes32 currencyKey) external onlyAdmin {
        _removeOracle(currencyKey);
    }

    function _addDexOracle(
        bytes32 currencyKey,
        address oracleAddress,
        bool removeExisting
    ) private {
        require(currencyKey != bytes32(0), "OracleRouter - DexOracle : empty currency key");
        require(oracleAddress != address(0), "OracleRouter - DexOracle: empty oracle address");

        if (oracleSettings[currencyKey].oracleAddress != address(0)) {
            require(removeExisting, "OracleRouter - DexOracle : oracle already exists");
            _removeOracle(currencyKey);
        }

        oracleSettings[currencyKey] = OracleSettings({oracleType: ORACLE_TYPE_DEX, oracleAddress: oracleAddress});

        emit QuarterlyContractOracleAdded(currencyKey, oracleAddress);
    }

    function _addQuarterlyContractOracle(
        bytes32 currencyKey,
        address oracleAddress,
        bool removeExisting
    ) private {
        require(currencyKey != bytes32(0), "OracleRouter - QuarterlyContractOracle : empty currency key");
        require(oracleAddress != address(0), "OracleRouter - QuarterlyContractOracle : empty oracle address");

        if (oracleSettings[currencyKey].oracleAddress != address(0)) {
            require(removeExisting, "OracleRouter - QuarterlyContractOracle : oracle already exists");
            _removeOracle(currencyKey);
        }

        oracleSettings[currencyKey] = OracleSettings({
            oracleType: ORACLE_TYPE_QUARTERLY_CONTRACT,
            oracleAddress: oracleAddress
        });

        emit QuarterlyContractOracleAdded(currencyKey, oracleAddress);
    }

    function _addChainlinkOracle(
        bytes32 currencyKey,
        address oracleAddress,
        bool removeExisting
    ) private {
        require(currencyKey != bytes32(0), "OracleRouter - ChainlinkOracle : empty currency key");
        require(oracleAddress != address(0), "OracleRouter - ChainlinkOracle : empty oracle address");

        if (oracleSettings[currencyKey].oracleAddress != address(0)) {
            require(removeExisting, "OracleRouter - ChainlinkOracle : oracle already exists");
            _removeOracle(currencyKey);
        }

        oracleSettings[currencyKey] = OracleSettings({oracleType: ORACLE_TYPE_CHAINLINK, oracleAddress: oracleAddress});

        emit ChainlinkOracleAdded(currencyKey, oracleAddress);
    }

    function _removeOracle(bytes32 currencyKey) private onlyOracleSet(currencyKey) {
        OracleSettings memory settings = oracleSettings[currencyKey];
        delete oracleSettings[currencyKey];
        emit OracleRemoved(currencyKey, settings.oracleAddress);
    }

    function _getPriceData(bytes32 currencyKey)
        private
        view
        onlyOracleSet(currencyKey)
        returns (uint256 price, uint256 updateTime)
    {
        if (currencyKey == FUSD) return (SafeDecimalMath.unit(), block.timestamp);

        OracleSettings memory settings = oracleSettings[currencyKey];

        if (settings.oracleType == ORACLE_TYPE_CHAINLINK) {
            (, int256 rawAnswer, , uint256 rawUpdateTime, ) = IChainlinkOracle(settings.oracleAddress)
                .latestRoundData();

            uint8 oraclePriceDecimals = IChainlinkOracle(settings.oracleAddress).decimals();
            if (oraclePriceDecimals == OUTPUT_PRICE_DECIMALS) {
                price = rawAnswer.toUint256();
            } else if (oraclePriceDecimals > OUTPUT_PRICE_DECIMALS) {
                // Too many decimals
                price = rawAnswer.toUint256().div(10**uint256(oraclePriceDecimals - OUTPUT_PRICE_DECIMALS));
            } else {
                // Too few decimals
                price = rawAnswer.toUint256().mul(10**uint256(OUTPUT_PRICE_DECIMALS - oraclePriceDecimals));
            }

            updateTime = rawUpdateTime;
        } else if (settings.oracleType == ORACLE_TYPE_QUARTERLY_CONTRACT) {
            // oracle sever will set OUTPUT_PRICE_DECIMALS data
            IQuarterlyContractOracle.PriceData memory priceRes = IQuarterlyContractOracle(settings.oracleAddress)
                .getQuarterlyContractPrice(currencyKey);
            price = priceRes.price;
            updateTime = priceRes.updateTime;
        } else if (settings.oracleType == ORACLE_TYPE_DEX) {
            (price, updateTime) = IDexOracle(settings.oracleAddress).getPrice();
        } else {
            price = 0;
            updateTime = 0;
            require(false, "OracleRouter: unknown oracle type");
        }
    }

    function _isUpdateTimeStaled(uint256 updateTime, uint256 stalePeriod) private view returns (bool) {
        return updateTime.add(stalePeriod) < block.timestamp;
    }
}
