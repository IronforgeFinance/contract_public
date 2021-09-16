// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMinerReward {
    function getCurrentPeriodId() external view returns (uint256);

    function setExchangeRewardInfo(
        uint256 _periodId,
        uint256 _rate,
        uint256 _totalReward
    ) external;

    function sendExchangeReward(address _recipient, uint256 exchangeAmountInUSD) external;

    function poolLength() external view returns (uint256);

    function deposit(
        address _for,
        uint256 pid,
        uint256 amount
    ) external;

    function withdraw(
        address _for,
        uint256 pid,
        uint256 amount
    ) external;

    function harvest(uint256 _pid) external;

    function getStakeToken(uint256 _pid) external returns (IERC20);
}
