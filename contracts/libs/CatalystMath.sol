// SPDX-License-Identifier: MIT

pragma solidity >=0.8.4;

import "prb-math/contracts/PRBMathUD60x18.sol";

library CatalystMath {
    using PRBMathUD60x18 for uint256;

    uint256 constant unit = 1e18;
    uint256 constant a = 5e16; // 5%,0.05

    // x 是平台币占抵押物的比例,y=0.05\log_{10}\left(99x+1\right)
    function calcCatalyst(uint256 x) external pure returns (uint256) {
        if (x >= unit) {
            return a * 2;
        } else {
            uint256 x1 = x * 99 + unit;
            return x1.log10() * a / unit;
        }
    }
}
