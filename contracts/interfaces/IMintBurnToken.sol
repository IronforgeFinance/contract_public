// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IMintBurnToken {
    function mint(address account, uint256 amount) external;

    function burn(address account, uint256 amount) external;
}
