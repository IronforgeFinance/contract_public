// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;

/**
 * @title TransferHelper
 *
 * @dev A helper library for calling functions on ERC20 tokens with compatibility for
 * non-ERC20 compliant contracts like Tether.
 */
library StringHelper {
    function string2Bytes32(string memory source) internal pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }

        assembly {
            result := mload(add(source, 32))
        }
    }

    function stringLteBytes32(string memory source) internal pure returns (bool) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length > 32) {
            return false;
        } else {
            return true;
        }
    }
}
