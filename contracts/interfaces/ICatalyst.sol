// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12 <=0.8.4;

interface ICatalyst {
    function calcCatalyst(uint256 x) external pure returns (uint256);
}
