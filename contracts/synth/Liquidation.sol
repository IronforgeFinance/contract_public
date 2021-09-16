// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../interfaces/IBuildBurnSystem.sol";
import "../interfaces/ICollateralSystem.sol";
import "../interfaces/IConfig.sol";
import "../interfaces/IDebtSystem.sol";
import "../interfaces/IPrices.sol";
import "../utilities/AdminUpgradeable.sol";
import "../libs/SafeDecimalMath.sol";

contract Liquidation is AdminUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeDecimalMath for uint256;

    event PositionMarked(address user, address marker);
    event PositionUnmarked(address user);
    event PositionLiquidated(
        address user,
        address marker,
        address liquidator,
        uint256 debtBurnt,
        bytes32 collateralCurrency,
        uint256 collateralWithdrawnFromStaked,
        uint256 markerReward,
        uint256 liquidatorReward
    );

    struct UnderCollateralizedMark {
        address marker;
        uint64 timestamp;
    }

    struct EvalUserPositionResult {
        uint256 debtBalance;
        uint256 stakedCollateral;
        uint256 collateralPrice;
        uint256 collateralValue;
        uint256 collateralizedRatio;
    }

    struct FetchRatiosResult {
        uint256 issuanceRatio;
        uint256 markerRewardRatio;
        uint256 liquidatorRewardRatio;
    }

    struct LiquidationRewardCalculationResult {
        uint256 collateralWithdrawalAmount;
        uint256 markerReward;
        uint256 liquidatorReward;
        uint256 totalReward;
    }

    struct LiquidatePositionParams {
        address user;
        address liquidator;
        uint256 fusdToBurn;
        bytes32 currency;
    }

    struct WithdrawCollateralParams {
        address user;
        address liquidator;
        uint256 collateralWithdrawalAmount;
        uint256 stakedCollateral;
        bytes32 currency;
    }

    struct DistributeRewardsParams {
        address user;
        address marker;
        address liquidator;
        uint256 markerReward;
        uint256 liquidatorReward;
        uint256 stakedCollateral;
        bytes32 currency;
    }

    IBuildBurnSystem public BuildBurnSystem;
    ICollateralSystem public CollateralSystem;
    IConfig public Config;
    IDebtSystem public DebtSystem;
    IPrices public Prices;

    mapping(address => UnderCollateralizedMark) public underCollateralizedMarks;

    bytes32 public constant LIQUIDATION_MARKER_REWARD_KEY = "LiquidationMarkerReward";
    bytes32 public constant LIQUIDATION_LIQUIDATOR_REWARD_KEY = "LiquidationLiquidatorReward";
    bytes32 public constant LIQUIDATION_RATIO_KEY = "LiquidationRatio";
    bytes32 public constant LIQUIDATION_DELAY_KEY = "LiquidationDelay";

    function isPositionMarked(address user) public view returns (bool) {
        return underCollateralizedMarks[user].timestamp > 0;
    }

    function getMarker(address user) public view returns (address) {
        return underCollateralizedMarks[user].marker;
    }

    function getMarkTimestamp(address user) public view returns (uint256) {
        return uint256(underCollateralizedMarks[user].timestamp);
    }

    function initialize(
        IBuildBurnSystem _BuildBurnSystem,
        ICollateralSystem _CollateralSystem,
        IConfig _Config,
        IDebtSystem _DebtSystem,
        IPrices _Prices,
        address _admin
    ) public initializer {
        AdminUpgradeable.__AdminUpgradeable_init(_admin);

        require(address(_BuildBurnSystem) != address(0), "Liquidation: zero address");
        require(address(_CollateralSystem) != address(0), "Liquidation: zero address");
        require(address(_Config) != address(0), "Liquidation: zero address");
        require(address(_DebtSystem) != address(0), "Liquidation: zero address");
        require(address(_Prices) != address(0), "Liquidation: zero address");

        BuildBurnSystem = _BuildBurnSystem;
        CollateralSystem = _CollateralSystem;
        Config = _Config;
        DebtSystem = _DebtSystem;
        Prices = _Prices;
    }

    function setPrices(IPrices newPrices) external onlyAdmin {
        require(address(newPrices) != address(0), "Liquidation: zero address");
        Prices = newPrices;
    }

    function markPosition(address user, bytes32 _currency) external {
        console.log("Liquidation::markPosition start");
        require(!isPositionMarked(user), "Liquidation: already marked");
        EvalUserPositionResult memory evalResult = evalUserPosition(user, _currency);
        uint256 liquidationRatio = Config.getUint(LIQUIDATION_RATIO_KEY);
        require(evalResult.collateralizedRatio > liquidationRatio, "Liquidation: not underCollateralized");

        underCollateralizedMarks[user] = UnderCollateralizedMark({
            marker: msg.sender,
            timestamp: uint64(block.timestamp)
        });

        emit PositionMarked(user, msg.sender);
    }

    function removeMark(address user, bytes32 _currency) external {
        require(isPositionMarked(user), "Liquidation: not marked");

        // Can only remove mark if C ratio is restored to issuance ratio
        EvalUserPositionResult memory evalResult = evalUserPosition(user, _currency);
        uint256 issuanceRatio = Config.getBuildRatio(_currency);
        require(evalResult.collateralizedRatio <= issuanceRatio, "Liquidation: still underCollateralized");

        delete underCollateralizedMarks[user];

        emit PositionUnmarked(user);
    }

    function liquidatePosition(
        address user,
        uint256 fusdToBurn,
        bytes32 currency
    ) external {
        require(fusdToBurn > 0, "Liquidation: zero amount");

        _liquidatePosition(
            LiquidatePositionParams({user: user, liquidator: msg.sender, fusdToBurn: fusdToBurn, currency: currency})
        );
    }

    function liquidatePositionMax(address user, bytes32 currency) external {
        _liquidatePosition(
            LiquidatePositionParams({user: user, liquidator: msg.sender, fusdToBurn: 0, currency: currency})
        );
    }

    function _liquidatePosition(LiquidatePositionParams memory params) private {
        console.log("Liquidation::_liquidatePosition");
        // Check mark and delay
        UnderCollateralizedMark memory mark = underCollateralizedMarks[params.user];
        {
            uint256 liquidationDelay = Config.getUint(LIQUIDATION_DELAY_KEY);
            require(mark.timestamp > 0, "Liquidation: not marked for underCollateralized");
            require(block.timestamp > mark.timestamp + liquidationDelay, "Liquidation: liquidation delay not passed");
        }

        // Confirm that the position is still underCollateralized
        FetchRatiosResult memory ratios = fetchRatios(params.currency);
        EvalUserPositionResult memory evalResult = evalUserPosition(params.user, params.currency);
        require(evalResult.collateralizedRatio > ratios.issuanceRatio, "Liquidation: not underCollateralized");

        uint256 maxLusdToBurn = evalResult
        .debtBalance
        .sub(evalResult.collateralValue.multiplyDecimal(ratios.issuanceRatio))
        .divideDecimal(
            SafeDecimalMath.unit().sub(
                SafeDecimalMath.unit().add(ratios.markerRewardRatio.add(ratios.liquidatorRewardRatio)).multiplyDecimal(
                    ratios.issuanceRatio
                )
            )
        );

        if (params.fusdToBurn == 0) {
            // Liquidate max
            params.fusdToBurn = maxLusdToBurn;
        } else {
            // User specified amount to liquidate
            console.log("Liquidation::_liquidatePosition params.fusdToBurn: %s", params.fusdToBurn);
            require(params.fusdToBurn <= maxLusdToBurn, "Liquidation: burn amount too large");
        }

        // Burn FUSD and update debt
        BuildBurnSystem.burnForLiquidation(params.user, params.fusdToBurn, params.currency);

        LiquidationRewardCalculationResult memory rewards = calculateRewards(
            params.fusdToBurn,
            evalResult.collateralPrice,
            ratios.markerRewardRatio,
            ratios.liquidatorRewardRatio
        );

        {
            uint256 totalCollateralToMove = rewards.collateralWithdrawalAmount.add(rewards.totalReward);
            uint256 totalCollateralAmount = evalResult.stakedCollateral;
            require(totalCollateralToMove > 0, "Liquidation: no collateral withdrawal");
            require(totalCollateralToMove <= totalCollateralAmount, "Liquidation: insufficient collateral");
            // Insurance fund needed to resolve this
        }

        uint256 totalFromStaked;

        // collateral withdrawal
        {
            (totalFromStaked) = withdrawCollateral(
                WithdrawCollateralParams({
                    user: params.user,
                    liquidator: params.liquidator,
                    collateralWithdrawalAmount: rewards.collateralWithdrawalAmount,
                    stakedCollateral: evalResult.stakedCollateral,
                    currency: params.currency
                })
            );

            // Track staked and locked amounts locally
            evalResult.stakedCollateral = evalResult.stakedCollateral.sub(totalFromStaked);
        }

        // Rewards
        {
            uint256 fromStaked = distributeRewards(
                DistributeRewardsParams({
                    user: params.user,
                    marker: mark.marker,
                    liquidator: params.liquidator,
                    markerReward: rewards.markerReward,
                    liquidatorReward: rewards.liquidatorReward,
                    stakedCollateral: evalResult.stakedCollateral,
                    currency: params.currency
                })
            );

            totalFromStaked = totalFromStaked.add(fromStaked);
        }

        emit PositionLiquidated(
            params.user,
            mark.marker,
            params.liquidator,
            params.fusdToBurn,
            params.currency,
            totalFromStaked,
            rewards.markerReward,
            rewards.liquidatorReward
        );

        // If the position is completely liquidated, remove the marker
        if (params.fusdToBurn == maxLusdToBurn) {
            delete underCollateralizedMarks[params.user];
            emit PositionUnmarked(params.user);
        }
    }

    // 按照一个ratio去清算总的仓位，方案三才需要如此判断
    function evalUserPositionAll(address user, bytes32 _currency) public view returns (EvalUserPositionResult memory) {
        (uint256 debtBalance, ) = DebtSystem.GetUserDebtBalanceInUsd(user, _currency);
        uint256 collateralValue = CollateralSystem.getUserTotalCollateralInUsd(user);
        uint256 collateralizedRatio = collateralValue == 0 ? 0 : debtBalance.divideDecimal(collateralValue);
        return
            EvalUserPositionResult({
                debtBalance: debtBalance,
                stakedCollateral: 0,
                collateralPrice: 0,
                collateralValue: collateralValue,
                collateralizedRatio: collateralizedRatio
            });
    }

    function evalUserPosition(address user, bytes32 _currency) public view returns (EvalUserPositionResult memory) {
        (uint256 debtBalance, ) = DebtSystem.GetUserDebtBalanceInUsd(user, _currency);
        uint256 stakedCollateral = CollateralSystem.getUserCollateral(user, _currency);
        uint256 collateralPrice = Prices.getPrice(_currency);
        uint256 collateralValue = stakedCollateral.multiplyDecimal(collateralPrice);
        uint256 collateralizedRatio = collateralValue == 0 ? 0 : debtBalance.divideDecimal(collateralValue);
        return
            EvalUserPositionResult({
                debtBalance: debtBalance,
                stakedCollateral: stakedCollateral,
                collateralPrice: collateralPrice,
                collateralValue: collateralValue,
                collateralizedRatio: collateralizedRatio
            });
    }

    function fetchRatios(bytes32 _currency) private view returns (FetchRatiosResult memory) {
        uint256 issuanceRatio = Config.getBuildRatio(_currency);
        uint256 markerRewardRatio = Config.getUint(LIQUIDATION_MARKER_REWARD_KEY);
        uint256 liquidatorRewardRatio = Config.getUint(LIQUIDATION_LIQUIDATOR_REWARD_KEY);

        return
            FetchRatiosResult({
                issuanceRatio: issuanceRatio,
                markerRewardRatio: markerRewardRatio,
                liquidatorRewardRatio: liquidatorRewardRatio
            });
    }

    function calculateRewards(
        uint256 fusdToBurn,
        uint256 collateralPrice,
        uint256 markerRewardRatio,
        uint256 liquidatorRewardRatio
    ) private pure returns (LiquidationRewardCalculationResult memory) {
        // Amount of collateral with the same value as the debt burnt (without taking into account rewards)
        uint256 collateralWithdrawalAmount = fusdToBurn.divideDecimal(collateralPrice);

        // Reward amounts
        uint256 markerReward = collateralWithdrawalAmount.multiplyDecimal(markerRewardRatio);
        uint256 liquidatorReward = collateralWithdrawalAmount.multiplyDecimal(liquidatorRewardRatio);
        uint256 totalReward = markerReward.add(liquidatorReward);

        return
            LiquidationRewardCalculationResult({
                collateralWithdrawalAmount: collateralWithdrawalAmount,
                markerReward: markerReward,
                liquidatorReward: liquidatorReward,
                totalReward: totalReward
            });
    }

    function withdrawCollateral(WithdrawCollateralParams memory params) private returns (uint256 amountFromStaked) {
        amountFromStaked = Math.min(params.collateralWithdrawalAmount, params.stakedCollateral);
        if (amountFromStaked > 0) {
            CollateralSystem.moveCollateral(params.user, params.liquidator, params.currency, amountFromStaked);
        }
    }

    function distributeRewards(DistributeRewardsParams memory params) private returns (uint256 amountFromStaked) {
        uint256 totalReward = params.markerReward.add(params.liquidatorReward);

        amountFromStaked = Math.min(totalReward, params.stakedCollateral);

        uint256 liquidatorRewardFromLocked = params.liquidatorReward;

        if (amountFromStaked > 0) {
            uint256 markerRewardFromStaked = amountFromStaked.mul(params.markerReward).div(totalReward);
            uint256 liquidatorRewardFromStaked = amountFromStaked.sub(markerRewardFromStaked);

            liquidatorRewardFromLocked = liquidatorRewardFromLocked.sub(liquidatorRewardFromStaked);
            CollateralSystem.moveCollateral(params.user, params.marker, params.currency, markerRewardFromStaked);
            CollateralSystem.moveCollateral(
                params.user,
                params.liquidator,
                params.currency,
                liquidatorRewardFromStaked
            );
        }
    }
}
