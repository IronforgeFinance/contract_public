// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12 <0.8.0;

interface IConfig {
    function getUint(bytes32 key) external view returns (uint);
    function getBuildRatio(bytes32 key) external view returns (uint);
}
