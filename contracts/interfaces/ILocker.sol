// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILocker {
    function calLockAmount(uint256 alpacaAmount) external view returns (uint256);

    function lockOf(address user, uint256 poolId) external returns (uint256);

    function lock(
        address user,
        uint256 poolId,
        uint256 alpacaAmount
    ) external;

    function pendingTokens(address user, uint256 poolId) external view returns (uint256);

    function claim() external;

    function getLocks(address _user, uint256 _poolId) external view returns (uint256);

    event Lock(address indexed to, uint256 value);
}
