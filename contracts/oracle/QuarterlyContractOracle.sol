// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "../utilities/AdminUpgradeable.sol";
import "../interfaces/IQuarterlyContractOracle.sol";
import "../interfaces/IAccessControl.sol";
import "../utilities/AddressCache.sol";

/**
 * @title OracleRouter
 *
 * @dev A contract for providing contracts with access to asset prices from multiple data
 * oracles including Chainlink and Band Protocol.
 */
contract QuarterlyContractOracle is AdminUpgradeable, AddressCache, IQuarterlyContractOracle {
    mapping(bytes32 => PriceData) public prices;
    IAccessControl accessCtrl;

    bytes32 private constant ROLE_ORACLE_SERVER = "ORACLE_SERVER";
    event PriceUpdated(bytes32 symbol, uint256 price, uint256 time);

    modifier onlyOracleServerRole() {
        require(accessCtrl.hasRole(ROLE_ORACLE_SERVER, msg.sender), "QuarterlyContractOracle: not ORACLE_SERVER role");
        _;
    }

    function initialize(address _admin) public initializer {
        AdminUpgradeable.__AdminUpgradeable_init(_admin);
    }

    function isOracleServerRole(address account) public view returns (bool) {
        return accessCtrl.hasRole(ROLE_ORACLE_SERVER, account);
    }

    function updateAddressCache(IAddressStorage _addressStorage) public override onlyAdmin {
        accessCtrl = IAccessControl(
            _addressStorage.getAddressWithRequire("AccessControl", "AccessControl address not valid")
        );

        emit CachedAddressUpdated("AccessControl", address(accessCtrl));
    }

    function getQuarterlyContractPrice(bytes32 symbol) external view override returns (PriceData memory) {
        return prices[symbol];
    }

    function setQuarterlyContractPrice(
        bytes32 symbol,
        uint256 price,
        uint256 time
    ) external override onlyOracleServerRole {
        require(!isFrozen(symbol), "OracleRouter: price frozen");
        PriceData memory newPriceData = PriceData({updateTime: time, price: price, frozen: false});
        prices[symbol] = newPriceData;
        emit PriceUpdated(symbol, price, time);
    }

    // set Frozen to forbid set price
    function setFrozen(bytes32 currencyKey, bool isFrozen) public override {
        PriceData memory data = prices[currencyKey];
        prices[currencyKey] = PriceData({price: data.price, updateTime: data.updateTime, frozen: isFrozen});
    }

    function isFrozen(bytes32 currencyKey) public view override returns (bool) {
        return prices[currencyKey].frozen;
    }
}
