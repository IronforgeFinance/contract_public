// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../interfaces/IAsset.sol";
import "../interfaces/IAddressStorage.sol";
import "../interfaces/IPrices.sol";
import "../interfaces/IConfig.sol";
import "../utilities/AdminUpgradeable.sol";
import "../utilities/AddressCache.sol";
import "../libs/SafeDecimalMath.sol";
import "../interfaces/IMinerReward.sol";
import "../interfaces/IExchangeSystem.sol";
import "../interfaces/IAssetSystem.sol";
import "../interfaces/ICollateralSystem.sol";

contract ExchangeSystem is AdminUpgradeable, AddressCache, IExchangeSystem {
    using SafeMath for uint256;
    using SafeDecimalMath for uint256;

    event ExchangeAsset(
        address fromAddress,
        bytes32 sourceKey,
        uint256 sourceAmount,
        address destAddress,
        bytes32 destKey,
        uint256 destRecived,
        uint256 feeForPool,
        uint256 feeForFoundation
    );
    event FoundationFeeHolderChanged(address oldHolder, address newHolder);
    event ExitPositionOnlyChanged(bool oldValue, bool newValue);
    event PendingExchangeAdded(
        uint256 id,
        address fromAddress,
        address destAddress,
        uint256 fromAmount,
        bytes32 fromCurrency,
        bytes32 toCurrency,
        uint256 pendingDestAmount
    );
    event PendingExchangeSettled(
        uint256 id,
        address settler,
        uint256 destRecived,
        uint256 destAmount,
        uint256 feeForPool,
        uint256 feeForFoundation,
        uint256 fromCurrencyPrice,
        uint256 toCurrencyPrice
    );
    event PendingExchangeReverted(uint256 id);

    struct PendingExchangeEntry {
        uint64 id;
        uint64 timestamp;
        address fromAddress;
        address destAddress;
        uint256 fromAmount;
        bytes32 fromCurrency;
        bytes32 toCurrency;
        uint256 pendingDestAmount;
    }

    struct PendingMintOrBurnEntry {
        uint256 id;
        address user;
        bytes32 stakeCurrency;
        uint256 stakeAmount;
        bytes32 entryType;
    }

    event PendingMintOrBurnSettled(
        uint256 id,
        address user,
        bytes32 stakeCurrency,
        uint256 stakeAmount,
        bytes32 entryType
    );

    IAddressStorage assetsStorage;
    IPrices prices;
    IConfig config;
    IMinerReward exchangeReward;
    ICollateralSystem collateralSystem;

    address rewardSys;
    address foundationFeeHolder;

    bool public exitPositionOnly;

    uint256 public lastPendingExchangeEntryId;
    mapping(uint256 => PendingExchangeEntry) public pendingExchangeEntries;

    bytes32 constant TYPE_MINT = "MINT";
    bytes32 constant TYPE_BURN = "BURN";

    mapping(uint256 => PendingMintOrBurnEntry) public pendingMintOrBurnEntries;

    bytes32 private constant EXCHANGE_REWARD_KEY = "MinerReward";
    bytes32 private constant ASSETS_KEY = "AssetSystem";
    bytes32 private constant PRICES_KEY = "Prices";
    bytes32 private constant CONFIG_KEY = "Config";
    bytes32 private constant REWARD_SYS_KEY = "RewardSystem";
    bytes32 private constant CONFIG_FEE_SPLIT = "FoundationFeeSplit";
    bytes32 private constant CONFIG_TRADE_SETTLEMENT_DELAY = "TradeSettlementDelay";
    bytes32 private constant CONFIG_TRADE_REVERT_DELAY = "TradeRevertDelay";
    bytes32 private constant ROLE_PURGE_ASSET = "PURGE_ASSET";
    bytes32 private constant COLLATERAL_SYSTEM_KEY = "CollateralSystem";

    bytes32 private constant FUSD_KEY = "FUSD";

    modifier onlyPurgeAsset(address asset) {
        IAssetSystem assetSystem = IAssetSystem(address(assetsStorage));
        require(assetSystem.isAsset(asset), "ExchangeSystem: not PurgeAsset");
        _;
    }

    function initialize(address _admin) public initializer {
        AdminUpgradeable.__AdminUpgradeable_init(_admin);
    }

    function updateAddressCache(IAddressStorage _addressStorage) public override onlyAdmin {
        assetsStorage = IAddressStorage(_addressStorage.getAddressWithRequire(ASSETS_KEY, ""));
        prices = IPrices(_addressStorage.getAddressWithRequire(PRICES_KEY, ""));
        config = IConfig(_addressStorage.getAddressWithRequire(CONFIG_KEY, ""));
        rewardSys = _addressStorage.getAddressWithRequire(REWARD_SYS_KEY, "");
        exchangeReward = IMinerReward(_addressStorage.getAddressWithRequire(EXCHANGE_REWARD_KEY, ""));
        collateralSystem = ICollateralSystem(_addressStorage.getAddressWithRequire(COLLATERAL_SYSTEM_KEY, ""));

        emit CachedAddressUpdated(ASSETS_KEY, address(assetsStorage));
        emit CachedAddressUpdated(PRICES_KEY, address(prices));
        emit CachedAddressUpdated(CONFIG_KEY, address(config));
        emit CachedAddressUpdated(REWARD_SYS_KEY, address(rewardSys));
        emit CachedAddressUpdated(EXCHANGE_REWARD_KEY, address(exchangeReward));
    }

    function setFoundationFeeHolder(address _foundationFeeHolder) public override onlyAdmin {
        require(_foundationFeeHolder != address(0), "ExchangeSystem: zero address");
        require(_foundationFeeHolder != foundationFeeHolder, "ExchangeSystem: foundation fee holder not changed");

        address oldHolder = foundationFeeHolder;
        foundationFeeHolder = _foundationFeeHolder;

        emit FoundationFeeHolderChanged(oldHolder, foundationFeeHolder);
    }

    function setExitPositionOnly(bool newValue) public override onlyAdmin {
        require(exitPositionOnly != newValue, "ExchangeSystem: value not changed");

        bool oldValue = exitPositionOnly;
        exitPositionOnly = newValue;

        emit ExitPositionOnlyChanged(oldValue, newValue);
    }

    /**
     * called by external
     */
    function exchange(
        bytes32 sourceKey,
        uint256 sourceAmount,
        address destAddress,
        bytes32 destKey
    ) external override returns (uint256) {
        return _exchange(msg.sender, sourceKey, sourceAmount, destAddress, destKey);
    }

    /**
     * called by external
     */
    function exchangeFromCollateral(
        bytes32 sourceKey,
        uint256 sourceAmount,
        address destAddress,
        bytes32 destKey,
        bytes32 stakeCurrency,
        uint256 stakeAmount
    ) external override returns (uint256) {
        uint256 entryId = _exchange(msg.sender, sourceKey, sourceAmount, destAddress, destKey);
        PendingMintOrBurnEntry memory newEntry = PendingMintOrBurnEntry({
            id: entryId,
            user: destAddress,
            stakeCurrency: stakeCurrency,
            stakeAmount: stakeAmount,
            entryType: TYPE_MINT
        });
        // Mint is from FUSD to non-fusd
        // Burn is from non-fusd to FUSD
        if (destKey == "FUSD") {
            newEntry.entryType = TYPE_BURN;
        }
        pendingMintOrBurnEntries[entryId] = newEntry;
        return entryId;
    }

    function settle(uint256 pendingExchangeEntryId) external override {
        _settle(pendingExchangeEntryId, msg.sender);
    }

    // revert is a deprecated builtin symbol
    function rollback(uint256 pendingExchangeEntryId) external override {
        _revert(pendingExchangeEntryId);
    }

    function _exchange(
        address fromAddress,
        bytes32 sourceKey,
        uint256 sourceAmount,
        address destAddress,
        bytes32 destKey
    ) private returns (uint256) {
        console.log("ExchangeSystem::_exchange");

        if (exitPositionOnly) {
            require(destKey == FUSD_KEY, "ExchangeSystem: can only exit position");
        }
        IAssetSystem assetSystem = IAssetSystem(address(assetsStorage));
        console.log("assetSystem.isForbidden(destKey): %s", assetSystem.isForbidden(destKey));
        require(!assetSystem.isForbidden(destKey), "ExchangeSystem: dest is forbid");

        // We don't need the return value here. It's just for preventing entering invalid trades
        assetsStorage.getAddressWithRequire(destKey, "ExchangeSystem: dest asset not found");

        IAsset source = IAsset(
            assetsStorage.getAddressWithRequire(sourceKey, "ExchangeSystem: source asset not found")
        );

        source.transferFrom(fromAddress, address(this), sourceAmount);

        uint256 pendingDestAmount = prices.exchange(sourceKey, sourceAmount, destKey);

        // Record the pending entry
        PendingExchangeEntry memory newPendingEntry = PendingExchangeEntry({
            id: uint64(++lastPendingExchangeEntryId),
            timestamp: uint64(block.timestamp),
            fromAddress: fromAddress,
            destAddress: destAddress,
            fromAmount: sourceAmount,
            fromCurrency: sourceKey,
            toCurrency: destKey,
            pendingDestAmount: pendingDestAmount
        });
        pendingExchangeEntries[uint256(newPendingEntry.id)] = newPendingEntry;

        // Emit event for off-chain indexing
        emit PendingExchangeAdded(
            newPendingEntry.id,
            fromAddress,
            destAddress,
            sourceAmount,
            sourceKey,
            destKey,
            pendingDestAmount
        );
        return uint256(newPendingEntry.id);
    }

    function settlementDelayPassed(uint256 pendingExchangeEntryId) public view override returns (bool) {
        uint256 settlementDelay = config.getUint(CONFIG_TRADE_SETTLEMENT_DELAY);
        require(settlementDelay > 0, "ExchangeSystem: settlement delay not set");
        PendingExchangeEntry memory exchangeEntry = pendingExchangeEntries[pendingExchangeEntryId];
        require(exchangeEntry.id > 0, "ExchangeSystem: pending entry not found");
        return block.timestamp >= exchangeEntry.timestamp + settlementDelay;
    }

    function canOnlyBeReverted(uint256 pendingExchangeEntryId) public view override returns (bool) {
        uint256 revertDelay = config.getUint(CONFIG_TRADE_REVERT_DELAY);
        require(revertDelay > 0, "ExchangeSystem: revert delay not set");
        PendingExchangeEntry memory exchangeEntry = pendingExchangeEntries[pendingExchangeEntryId];
        require(exchangeEntry.id > 0, "ExchangeSystem: pending entry not found");
        return block.timestamp > exchangeEntry.timestamp + revertDelay;
    }

    function deviationSatisfied(uint256 pendingExchangeEntryId)
        public
        view
        override
        returns (bool satisfied, uint256 destAmount)
    {
        PendingExchangeEntry memory exchangeEntry = pendingExchangeEntries[pendingExchangeEntryId];
        destAmount = prices.exchange(exchangeEntry.fromCurrency, exchangeEntry.fromAmount, exchangeEntry.toCurrency);
        uint256 deviation = 0;
        uint256 deviationConfig = config.getUint("DeviationExchange");
        if (exchangeEntry.pendingDestAmount > destAmount) {
            deviation = exchangeEntry.pendingDestAmount.sub(destAmount).divideDecimal(exchangeEntry.pendingDestAmount);
        } else {
            deviation = destAmount.sub(exchangeEntry.pendingDestAmount).divideDecimal(exchangeEntry.pendingDestAmount);
        }
        console.log("pendingDestAmount: %s, destAmount: %s", exchangeEntry.pendingDestAmount, destAmount);
        console.log("deviation: %s, deviationConfig: %s", deviation, deviationConfig);
        satisfied = deviation <= deviationConfig;
    }

    function _settle(uint256 pendingExchangeEntryId, address settler) private {
        PendingExchangeEntry memory exchangeEntry = pendingExchangeEntries[pendingExchangeEntryId];
        {
            require(exchangeEntry.id > 0, "ExchangeSystem: pending entry not found");
            require(settlementDelayPassed(pendingExchangeEntryId), "ExchangeSystem: settlement delay not passed");
            require(!canOnlyBeReverted(pendingExchangeEntryId), "ExchangeSystem: trade can only be reverted now");
        }

        IAsset source = IAsset(
            assetsStorage.getAddressWithRequire(exchangeEntry.fromCurrency, "ExchangeSystem: source asset not found")
        );
        IAsset dest = IAsset(
            assetsStorage.getAddressWithRequire(exchangeEntry.toCurrency, "ExchangeSystem: dest asset not found")
        );

        (bool satisfied, uint256 destAmount) = deviationSatisfied(pendingExchangeEntryId);
        if (!satisfied) {
            // auto return value to user
            _revert(pendingExchangeEntryId);
        } else {
            // This might cause a transaction to deadlock, but impact would be negligible
            require(destAmount > 0, "ExchangeSystem: zero dest amount");

            uint256 feeRate = config.getUint(exchangeEntry.toCurrency);
            uint256 destReceived = destAmount.multiplyDecimal(SafeDecimalMath.unit().sub(feeRate));
            uint256 fee = destAmount.sub(destReceived);

            // Fee going into the pool, to be adjusted based on foundation split
            uint256 feeForPoolInUsd = prices.exchange(exchangeEntry.toCurrency, fee, prices.FUSD());

            // Split the fee between pool and foundation when both holder and ratio are set
            uint256 foundationSplit;
            if (foundationFeeHolder == address(0)) {
                foundationSplit = 0;
            } else {
                uint256 splitRatio = config.getUint(CONFIG_FEE_SPLIT);

                if (splitRatio == 0) {
                    foundationSplit = 0;
                } else {
                    foundationSplit = feeForPoolInUsd.multiplyDecimal(splitRatio);
                    feeForPoolInUsd = feeForPoolInUsd.sub(foundationSplit);
                }
            }

            IAsset fusd = IAsset(
                assetsStorage.getAddressWithRequire(prices.FUSD(), "ExchangeSystem: failed to get FUSD address")
            );

            if (feeForPoolInUsd > 0) fusd.mint(rewardSys, feeForPoolInUsd);
            if (foundationSplit > 0) fusd.mint(foundationFeeHolder, foundationSplit);

            source.burn(address(this), exchangeEntry.fromAmount);
            dest.mint(exchangeEntry.destAddress, destReceived);

            _afterPenddingExchangeSettled(
                pendingExchangeEntryId,
                settler,
                destReceived,
                feeForPoolInUsd,
                foundationSplit
            );
        }
    }

    function _afterPenddingExchangeSettled(
        uint256 pendingExchangeEntryId,
        address settler,
        uint256 destReceived,
        uint256 feeForPoolInUsd,
        uint256 foundationSplit
    ) private {
        PendingExchangeEntry memory exchangeEntry = pendingExchangeEntries[pendingExchangeEntryId];
        uint256 exchangeAmountInUsd = prices.exchange(
            exchangeEntry.fromCurrency,
            exchangeEntry.fromAmount,
            prices.FUSD()
        );
        // send reward to user
        exchangeReward.sendExchangeReward(exchangeEntry.destAddress, exchangeAmountInUsd);
        uint256 destAmount = prices.exchange(
            exchangeEntry.fromCurrency,
            exchangeEntry.fromAmount,
            exchangeEntry.toCurrency
        );
        PendingMintOrBurnEntry memory entry = pendingMintOrBurnEntries[pendingExchangeEntryId];
        if (entry.id == pendingExchangeEntryId) {
            if (entry.entryType == TYPE_BURN) {
                collateralSystem.burnAndUnstakeFromExchange(
                    entry.user,
                    destReceived,
                    entry.stakeCurrency,
                    entry.stakeAmount
                );
                emit PendingMintOrBurnSettled(entry.id, entry.user, entry.stakeCurrency, entry.stakeAmount, TYPE_BURN);
            } else if (entry.entryType == TYPE_MINT) {
                emit PendingMintOrBurnSettled(entry.id, entry.user, entry.stakeCurrency, entry.stakeAmount, TYPE_MINT);
            }
            delete pendingMintOrBurnEntries[pendingExchangeEntryId];
        }

        emit PendingExchangeSettled(
            exchangeEntry.id,
            settler,
            destReceived,
            destAmount,
            feeForPoolInUsd,
            foundationSplit,
            exchangeAmountInUsd.divideDecimalRound(exchangeEntry.fromAmount),
            prices.exchange(exchangeEntry.toCurrency, destAmount, prices.FUSD()).divideDecimalRound(destAmount)
        );
        delete pendingExchangeEntries[pendingExchangeEntryId];
    }

    function _revert(uint256 pendingExchangeEntryId) private {
        PendingExchangeEntry memory exchangeEntry = pendingExchangeEntries[pendingExchangeEntryId];
        require(exchangeEntry.id > 0, "ExchangeSystem: pending entry not found");
        (bool deviation, ) = deviationSatisfied(pendingExchangeEntryId);
        if (deviation) {
            require(canOnlyBeReverted(pendingExchangeEntryId), "ExchangeSystem: revert delay not passed");
        }
        IAsset source = IAsset(
            assetsStorage.getAddressWithRequire(exchangeEntry.fromCurrency, "ExchangeSystem: source asset not found")
        );

        // Refund the amount locked
        source.approve(address(this), exchangeEntry.fromAmount);
        source.transferFrom(address(this), exchangeEntry.fromAddress, exchangeEntry.fromAmount);

        delete pendingExchangeEntries[pendingExchangeEntryId];

        emit PendingExchangeReverted(exchangeEntry.id);
    }

    // Reserved storage space to allow for layout changes in the future.
    uint256[42] private __gap;
}
