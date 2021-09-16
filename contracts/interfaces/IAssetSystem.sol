// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IAssetSystem {
    function totalAssetsInUsd() external view returns (uint256 total);

    function isAsset(address asset) external view returns (bool);

    function setForbidAsset(bytes32 name, bool forbid) external;

    function isForbidden(bytes32 name) external view returns (bool);
}
