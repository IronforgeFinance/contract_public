// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../interfaces/IAddressStorage.sol";

abstract contract AddressCache {
    function updateAddressCache(IAddressStorage _addressStorage) external virtual;
    event CachedAddressUpdated(bytes32 name, address addr);
}
