// SPDX-License-Identifier: MIT

pragma solidity >=0.8.4;

import "../libs/CatalystMath.sol";
import "../interfaces/ICatalyst.sol";

contract PublicCatalystMath is ICatalyst {
    using CatalystMath for uint256;

    function calcCatalyst(uint256 x) external pure override returns (uint256 result) {
        result = x.calcCatalyst();
    }
}
