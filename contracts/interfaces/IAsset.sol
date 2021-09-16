// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IAsset is IERC20Upgradeable {
    function symbol() external view returns (string memory);

    function symbolBytes32() external view returns (bytes32);

    function mint(address account, uint256 amount) external;

    function burn(address account, uint256 amount) external;
}
