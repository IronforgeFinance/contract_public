// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12 <0.8.0;

interface IDexPriceHelper {
    function getPairPrice(address token0, address token1) external view returns (uint256, uint256);
}
