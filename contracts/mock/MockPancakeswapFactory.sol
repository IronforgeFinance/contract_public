// SPDX-License-Identifier: MIT

pragma solidity 0.5.16;

import "../pancake/PancakeFactory.sol";

contract MockPancakeFactory is PancakeFactory {
  constructor(address _feeToSetter) public PancakeFactory(_feeToSetter) {}
}
