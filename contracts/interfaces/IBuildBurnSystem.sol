// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12 <0.8.0;

interface IBuildBurnSystem {
    function buildFromCollateralSys(
        address user,
        uint256 amount,
        bytes32 _currency,
        address receiver
    ) external;

    function burnFromCollateralSys(
        address user,
        uint256 amount,
        bytes32 _currency
    ) external;

    function burnForLiquidation(
        address user,
        uint256 amount,
        bytes32 _currency
    ) external;
}
