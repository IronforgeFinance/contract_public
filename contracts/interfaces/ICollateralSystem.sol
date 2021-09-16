// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12 <0.8.0;

interface ICollateralSystem {
    function getUserPlatformTokenCollateral(address _user) external view returns (uint256 staked);

    function getUserCollateral(address _user, bytes32 _currency) external view returns (uint256);

    function IsSatisfyTargetRatio(address _user, bytes32 _currency) external view returns (bool);

    function getUserTotalCollateralInUsd(address _user) external view returns (uint256 total);

    function getFreeCollateralInUsd(address user, bytes32 _currency) external view returns (uint256);

    /**
     * @return [0] current ratio. [1] default ratio of currency.
     */
    function getRatio(address _user, bytes32 _currency) external view returns (uint256, uint256);

    function withdrawLockedTokens(address _user, bytes32 _currency) external;

    function moveCollateral(
        address fromUser,
        address toUser,
        bytes32 currency,
        uint256 amount
    ) external;

    function calcBuildRatio(
        address user,
        bytes32 stakeCurrency,
        uint256 stakeAmount,
        uint256 lockedAmount
    ) external view returns (uint256);

    function burnAndUnstakeFromExchange(
        address user,
        uint256 burnAmount,
        bytes32 unStakeCurrency,
        uint256 unStakeAmount
    ) external;
}
