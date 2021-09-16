// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../interfaces/ILocker.sol";
import "../interfaces/IMinerReward.sol";

contract LinearRelease is ReentrancyGuardUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IMinerReward public minerReward;
    IERC20 public rewardToken;
    uint256 public lockupBps;

    uint256 public periodBlocks;

    struct LockInfo {
        uint256 lastUnlockBlock;
        uint256 locks;
        uint256 startReleaseBlock;
        uint256 endReleaseBlock;
    }

    // [user] => ([poolId => LockInfo])
    mapping(address => mapping(uint256 => LockInfo)) public locks;

    modifier onlyMinerReward() {
        require(msg.sender == address(minerReward), "linear release: only minerReward");
        _;
    }

    event Lock(address indexed to, uint256 value);
    event Claim(address indexed to, uint256 value);

    function initialize(
        IERC20 _token,
        uint256 _lockupBps,
        uint256 _periodBlocks,
        IMinerReward _minerRewardAddress
    ) public initializer {
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        rewardToken = _token;
        lockupBps = _lockupBps;
        periodBlocks = _periodBlocks;
        minerReward = IMinerReward(_minerRewardAddress);
    }

    function calLockAmount(uint256 _amount) external view onlyMinerReward returns (uint256) {
        return _amount.mul(lockupBps).div(10000);
    }

    function lockOf(address _user, uint256 _poolId) external view returns (LockInfo memory) {
        return locks[_user][_poolId];
    }

    function lock(
        address _user,
        uint256 _poolId,
        uint256 _amount
    ) external nonReentrant onlyMinerReward {
        require(_user != address(0), "lock: no address(0)");
        console.log("token.safeTransferFrom", _amount);
        rewardToken.safeTransferFrom(msg.sender, address(this), _amount);

        LockInfo storage lockInfo = locks[_user][_poolId];

        // initial case
        if (lockInfo.lastUnlockBlock == 0 && lockInfo.startReleaseBlock == 0 && lockInfo.endReleaseBlock == 0) {
            lockInfo.locks = lockInfo.locks.add(_amount);
            lockInfo.lastUnlockBlock = block.number;
            lockInfo.startReleaseBlock = block.number;
            lockInfo.endReleaseBlock = block.number.add(periodBlocks);
        } else {

            uint256 rewardRedRedeemable = pendingTokens(_user, _poolId);
            // send redeemable reward to user
            rewardToken.safeTransfer(_user, rewardRedRedeemable);
            lockInfo.locks = lockInfo.locks.sub(rewardRedRedeemable).add(_amount);

            if (_amount > 0) {
                // refresh lock period
                lockInfo.startReleaseBlock = block.number;
                lockInfo.endReleaseBlock = block.number.add(periodBlocks);
            }
            lockInfo.lastUnlockBlock = block.number;
        }

        emit Lock(_user, _amount);
    }

    function pendingTokens(address _user, uint256 _poolId) public view returns (uint256) {
        LockInfo memory lockInfo = locks[_user][_poolId];

        // When block number less than startReleaseBlock, no token can be unlocked
        uint256 amount = 0;
        if (block.number < lockInfo.startReleaseBlock) {
            amount = 0;
        }
        // When block number more than endReleaseBlock, all locked token can be unlocked
        else if (block.number >= lockInfo.endReleaseBlock) {
            amount = lockInfo.locks;
        }
        // When block number is more than startReleaseBlock but less than endReleaseBlock,
        else {
            uint256 releasedBlock = block.number.sub(lockInfo.lastUnlockBlock);
            uint256 blockLeft = lockInfo.endReleaseBlock.sub(lockInfo.lastUnlockBlock);
            amount = lockInfo.locks.mul(releasedBlock).div(blockLeft);
        }
        return amount;
    }

    function getLocks(address _user, uint256 _poolId) public view returns (uint256) {
        return locks[_user][_poolId].locks;
    }
}
