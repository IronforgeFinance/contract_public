// SPDX-License-Identifier: MIT
pragma solidity >=0.4.24;
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IPlatformToken is IERC20Upgradeable {
    function symbol() external view returns (string memory);

    function symbolBytes32() external view returns (bytes32);

    function manualMint(address account, uint256 amount) external;
}
