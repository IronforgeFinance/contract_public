// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../interfaces/IAddressStorage.sol";
import "./AdminUpgradeable.sol";

contract AddressStorage is AdminUpgradeable, IAddressStorage {
    mapping(bytes32 => address) public addressMap;

    function initialize(address _admin) public virtual initializer {
        AdminUpgradeable.__AdminUpgradeable_init(_admin);
    }

    function updateAll(bytes32[] calldata names, address[] calldata destinations) external override onlyAdmin {
        require(names.length == destinations.length, "Input lengths must match");

        for (uint i = 0; i < names.length; i++) {
            addressMap[names[i]] = destinations[i];
            emit StorageAddressUpdated(names[i], destinations[i]);
        }
    }

    function update(bytes32 name, address dest) external override onlyAdmin {
        require(name != "", "name can not be empty");
        require(dest != address(0), "address cannot be 0");
        addressMap[name] = dest;
        emit StorageAddressUpdated(name, dest);
    }

    function getAddress(bytes32 name) external view override returns (address) {
        return addressMap[name];
    }

    function getAddressWithRequire(bytes32 name, string calldata reason) external view override returns (address) {
        address _foundAddress = addressMap[name];
        require(_foundAddress != address(0), reason);
        return _foundAddress;
    }

    event StorageAddressUpdated(bytes32 name, address addr);

    // Reserved storage space to allow for layout changes in the future.
    uint256[49] private __gap;
}
