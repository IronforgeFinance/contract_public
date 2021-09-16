// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IExchangeSystem {
    function setFoundationFeeHolder(address _foundationFeeHolder) external;

    function setExitPositionOnly(bool newValue) external;

    function exchange(
        bytes32 sourceKey,
        uint256 sourceAmount,
        address destAddress,
        bytes32 destKey
    ) external returns (uint256);

    function exchangeFromCollateral(
        bytes32 sourceKey,
        uint256 sourceAmount,
        address destAddress,
        bytes32 destKey,
        bytes32 unStakeCurrency,
        uint256 unStakeAmount
    ) external returns (uint256);

    function settlementDelayPassed(uint256 pendingExchangeEntryId) external view returns (bool);

    function canOnlyBeReverted(uint256 pendingExchangeEntryId) external view returns (bool);

    function deviationSatisfied(uint256 pendingExchangeEntryId)
        external
        view
        returns (bool satisfied, uint256 destAmount);

    function settle(uint256 pendingExchangeEntryId) external;

    function rollback(uint256 pendingExchangeEntryId) external;
}
