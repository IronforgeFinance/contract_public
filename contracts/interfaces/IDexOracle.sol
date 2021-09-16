// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12 <0.8.0;

//just support token - usdc
interface IDexOracle {
    function update() external;
    function consult(address token, uint256 amountIn) external view returns (uint256 amountOut, uint256 updatedTime);
    function getPrice() external view returns (uint256 price, uint256 updatedTime);
}
