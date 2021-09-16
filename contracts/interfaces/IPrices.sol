// SPDX-License-Identifier: MIT
pragma solidity >=0.4.24;

interface IPrices {
    function getPrice(bytes32 currencyKey) external view returns (uint256);

    function exchange(
        bytes32 sourceKey,
        uint256 sourceAmount,
        bytes32 destKey
    ) external view returns (uint256);

    function FUSD() external view returns (bytes32);

    function isFrozen(bytes32 currencyKey) external view returns (bool);

    function setFrozen(bytes32 currencyKey, bool frozen) external;
}
