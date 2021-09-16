// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../IronForgeToken.sol";
import "../libs/SafeDecimalMath.sol";
import "../interfaces/ILocker.sol";
import "../utilities/AddressCache.sol";
import "../interfaces/IPrices.sol";

/**
* @title MinerReward
*

* @dev A contract for distributing exchange reward and farm pool reward.

 */

contract MinerReward is OwnableUpgradeable, ReentrancyGuardUpgradeable, AddressCache {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeDecimalMath for uint256;
    using SafeERC20Upgradeable for IPlatformToken;

    event ExchangeRewardSent(address indexed recipient, uint256 periodId, uint256 reward);
    event SetExchangeRewardInfo(uint256 periodId, uint256 rate, uint256 reward);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event LogPoolAddition(uint256 indexed pid, uint256 allocPoint, IERC20 indexed lpToken, ILocker indexed rewarder);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint, ILocker rewarder, bool overwrite);
    event LogUpdatePool(uint256 indexed pid, uint256 lastRewardBlock, uint256 lpSupply, uint256 accRewardPerShare);

    uint256 public firstPeriodStartTime; // start time for exchange reward

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many Staking tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        address fundedBy; // Funded by who?
    }

    // Info of each pool.
    struct PoolInfo {
        uint256 amount; // Amont of total staking tokens
        IERC20 stakeToken; // Address of the stake token
        uint256 allocPoint; // How many allocation points assigned to this pool. rewards to distribute per block.
        uint256 lastRewardBlock; // Last block number that rewards distribution occurs.
        uint256 accRewardPerShare; // Accumulated rewards per share, times 1e12. See below.
    }

    //Exchange reward info of each period
    struct ExchangeRewardInfo {
        uint256 rate;
        uint256 totalReward;
        uint256 rewardSent;
    }

    mapping(uint256 => ExchangeRewardInfo) public exchangeRewardInfo;

    /// @notice Info of each pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of each `ILockers` contract.
    ILocker[] public lockers;

    /// @notice reward per block
    uint256 public rewardPerBlock;

    /// @notice Info of each user that stakes tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    uint256 private constant ACC_REWARD_PRECISION = 1e12;

    IPrices priceGetter;
    IPlatformToken public platformToken;
    address private exchangeSystem;

    uint256 public constant PERIOD_LENGTH = 1 weeks;
    uint256 public constant DEFAULT_RATE = 1e16; // represnets for 0.01
    uint256 public constant DEFAULT_TOTAL_REWARD = 10000e18;

    modifier onlyExchangeSystem() {
        console.log("MinerReward onlyExchangeSystem - msg.sender: %s, exchangeSystem: %s", msg.sender, exchangeSystem);
        require((msg.sender == exchangeSystem), "MinerReward: not exchange system");
        _;
    }

    function getCurrentPeriodId() public view returns (uint256) {
        require(block.timestamp >= firstPeriodStartTime, "ExchangeReward: first period not started");
        return (block.timestamp - firstPeriodStartTime) / PERIOD_LENGTH;
        // No SafeMath needed
    }

    function initialize(
        uint256 _firstPeriodStartTime,
        uint256 _rewardPerBlock
    ) public initializer {
        OwnableUpgradeable.__Ownable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        firstPeriodStartTime = _firstPeriodStartTime;
        rewardPerBlock = _rewardPerBlock;
    }

    function updateAddressCache(IAddressStorage _addressStorage) public override onlyOwner {
        priceGetter = IPrices(_addressStorage.getAddressWithRequire("Prices", "Prices address not valid"));
        platformToken = IPlatformToken(
            _addressStorage.getAddressWithRequire("PlatformToken", "PlatformToken address not valid")
        );
        exchangeSystem = _addressStorage.getAddressWithRequire("ExchangeSystem", "ExchangeSystem address not valid");

        emit CachedAddressUpdated("Prices", address(priceGetter));
        emit CachedAddressUpdated("PlatformToken", address(platformToken));
        emit CachedAddressUpdated("ExchangeSystem", exchangeSystem);
    }

    function setExchangeRewardInfo(
        uint256 _periodId,
        uint256 _rate,
        uint256 _totalReward
    ) external onlyOwner {
        // require(_periodId > currentPeriodId, "ExchangeReward: period should be the future ");
        require(_rate > 0, "ExchangeReward: rate must > 0");
        require(_totalReward > 0, "ExchangeReward: totalReward must > 0");

        ExchangeRewardInfo storage configInfo = exchangeRewardInfo[_periodId];
        configInfo.rate = _rate;
        configInfo.totalReward = _totalReward;
        configInfo.rewardSent = 0;
        emit SetExchangeRewardInfo(_periodId, _rate, _totalReward);
    }

    /// @notice External function to sent exchange reward to user based on exchange amount in USD
    /// @param _recipient The recipient address.
    /// @param exchangeAmountInUSD exchange amount in USD
    function sendExchangeReward(address _recipient, uint256 exchangeAmountInUSD) external onlyExchangeSystem {
        uint256 currentPeriodId = getCurrentPeriodId();

        ExchangeRewardInfo memory configInfo = exchangeRewardInfo[currentPeriodId];
        if (configInfo.rate == 0) {
            // if the rewardInfo of this period is not set
            configInfo.rate = DEFAULT_RATE;
            configInfo.totalReward = DEFAULT_TOTAL_REWARD;
            configInfo.rewardSent = 0;
            emit SetExchangeRewardInfo(currentPeriodId, DEFAULT_RATE, DEFAULT_TOTAL_REWARD);
        }
        uint256 _rewardAmountInUSD = exchangeAmountInUSD.multiplyDecimal(configInfo.rate);
        uint256 price = priceGetter.getPrice(platformToken.symbolBytes32());
        require(price > 0, "ExchangeReward: platformToken price must > 0");
        uint256 destAmount = _rewardAmountInUSD.divideDecimal(price);
        uint256 rewardLeft = configInfo.totalReward.sub(configInfo.rewardSent);
        if (destAmount > rewardLeft) {
            destAmount = rewardLeft;
        }
        if (destAmount == 0) {
            return;
        }
        platformToken.manualMint(_recipient, destAmount);
        configInfo.rewardSent = configInfo.rewardSent.add(destAmount);
        emit ExchangeRewardSent(_recipient, currentPeriodId, destAmount);
    }

    /// @notice Returns the number of pools.
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /// @notice Returns the number of pools.
    function getStakeToken(uint256 _pid) external view returns (IERC20) {
        PoolInfo memory pool = poolInfo[_pid];
        return pool.stakeToken;
    }

    /// @notice Add a new lp to the pool. Can only be called by the owner.
    /// @param allocPoint AP of the new pool
    /// @param _stakeToken address of the LP token
    /// @param _locker address of the reward Contract
    function addPool(
        uint256 allocPoint,
        IERC20 _stakeToken,
        ILocker _locker,
        uint256 _startBlock
    ) external onlyOwner {
        uint256 lastRewardBlock = block.number > _startBlock ? block.number : _startBlock;
        totalAllocPoint = totalAllocPoint.add(allocPoint);

        lockers.push(_locker);

        poolInfo.push(
            PoolInfo({
                amount: 0,
                stakeToken: _stakeToken,
                allocPoint: allocPoint,
                lastRewardBlock: lastRewardBlock,
                accRewardPerShare: 0
            })
        );
        emit LogPoolAddition(poolInfo.length.sub(1), allocPoint, _stakeToken, _locker);
    }

    /// @notice Update the given pool's allocation point and `ILocker` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint new AP of the pool
    /// @param _locker Address of the rewarder delegate.
    /// @param overwrite True if _locker should be `set`. Otherwise `_locker` is ignored.
    function setPool(
        uint256 _pid,
        uint256 _allocPoint,
        ILocker _locker,
        bool overwrite
    ) external onlyOwner {
        updatePool(_pid);
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        if (overwrite) {
            lockers[_pid] = _locker;
        }
        emit LogSetPool(_pid, _allocPoint, overwrite ? _locker : lockers[_pid], overwrite);
    }

    /// @notice View function to see pending yield rewards
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user address of user
    function pendingReward(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 stakeTokenSupply = pool.amount;
        if (block.number > pool.lastRewardBlock && stakeTokenSupply != 0) {
            uint256 blocks = block.number.sub(pool.lastRewardBlock);
            uint256 reward = blocks.mul(rewardPerBlock).mul(pool.allocPoint).mul(ACC_REWARD_PRECISION).div(
                totalAllocPoint
            );
            accRewardPerShare = accRewardPerShare.add(reward.div(stakeTokenSupply));
        }
        uint256 _pendingReward = (user.amount.mul(accRewardPerShare) / ACC_REWARD_PRECISION).sub(user.rewardDebt);
        return _pendingReward;
    }

    /// @notice View function to see total pending rewards
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user address of user
    function totalPendingReward(uint256 _pid, address _user) external view returns (uint256) {
        uint256 _pendingReward = pendingReward(_pid, _user);
        ILocker _locker = lockers[_pid];
        uint256 lockedReward = _locker.getLocks(_user, _pid);
        _pendingReward = _pendingReward.add(lockedReward);
        return _pendingReward;
    }

    function redeemaleReward(uint256 _pid, address _user) external view returns (uint256) {
        uint256 _pendingReward = pendingReward(_pid, _user);
        ILocker _locker = lockers[_pid];
        uint256 lockAmount = _locker.calLockAmount(_pendingReward);
        _pendingReward = _pendingReward.sub(lockAmount);

        uint256 lockedRedeemableReward = _locker.pendingTokens(_user, _pid);
        _pendingReward = _pendingReward.add(lockedRedeemableReward);
        return _pendingReward;
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids pool IDs of all to be updated, make sure to update all active pools
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool returns the Pool that was updated
    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        if (block.number > pool.lastRewardBlock) {
            uint256 stakeTokenSupply = pool.amount;
            if (stakeTokenSupply > 0 && totalAllocPoint > 0) {
                uint256 blocks = block.number.sub(pool.lastRewardBlock);
                uint256 reward = blocks.mul(rewardPerBlock).mul(pool.allocPoint).mul(ACC_REWARD_PRECISION).div(
                    totalAllocPoint
                );
                pool.accRewardPerShare = pool.accRewardPerShare.add((reward.div(stakeTokenSupply)));
                // mint to MinerReward
                console.log("mint platformToken", reward.div(ACC_REWARD_PRECISION));
                platformToken.manualMint(address(this), reward.div(ACC_REWARD_PRECISION));
            }
            pool.lastRewardBlock = block.number;
            poolInfo[pid] = pool;
            emit LogUpdatePool(pid, pool.lastRewardBlock, stakeTokenSupply, pool.accRewardPerShare);
        }
    }

    /// @notice Deposit LP tokens to MinerReward for reward allocation.
    /// @param _for The address that will get yield
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount to deposit.
    function deposit(
        address _for,
        uint256 pid,
        uint256 amount
    ) external nonReentrant {
        updatePool(pid);
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][_for];

        _harvest(msg.sender, pid);
        // Validation
        if (user.fundedBy != address(0)) require(user.fundedBy == msg.sender, "MinerReward::deposit:: bad sof");

        // Effects
        user.amount = user.amount.add(amount);
        user.rewardDebt = user.rewardDebt.add(amount.mul(pool.accRewardPerShare) / ACC_REWARD_PRECISION);
        if (user.fundedBy == address(0)) user.fundedBy = msg.sender;
        console.log("MinerReward deposit fundedBy: ", user.fundedBy);
        // Interactions
        pool.stakeToken.safeTransferFrom(address(msg.sender), address(this), amount);
        pool.amount = pool.amount.add(amount);
        emit Deposit(msg.sender, pid, amount, _for);
    }

    /// @notice Withdraw LP tokens
    /// @param _for Receiver of yield
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount of lp tokens to withdraw.
    function withdraw(
        address _for,
        uint256 pid,
        uint256 amount
    ) external nonReentrant {
        updatePool(pid);
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][_for];
        console.log("MinerReward withdraw msg.sender: ", msg.sender);
        console.log("MinerReward withdraw fundedBy: ", user.fundedBy);
        require(user.fundedBy == msg.sender, "MinerReward::withdraw:: only funder");
        require(user.amount >= amount, "MinerReward::withdraw:: user amount not enough");
        require(pool.amount >= amount, "MinerReward::withdraw:: pool amount not enough");

        // Effects
        _harvest(_for, pid);

        user.rewardDebt = user.rewardDebt.sub(amount.mul(pool.accRewardPerShare) / ACC_REWARD_PRECISION);
        user.amount = user.amount.sub(amount);
        if (user.amount == 0) user.fundedBy = address(0);

        // Interactions
        pool.stakeToken.safeTransfer(msg.sender, amount);
        pool.amount = pool.amount.sub(amount);

        emit Withdraw(msg.sender, pid, amount, _for);
    }

    // Harvest rewards earn from the pool.
    function harvest(uint256 _pid) external {
        updatePool(_pid);
        _harvest(msg.sender, _pid);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of rewards.
    function _harvest(address to, uint256 pid) internal {
        PoolInfo memory pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][to];
        uint256 accumulatedReward = user.amount.mul(pool.accRewardPerShare).div(ACC_REWARD_PRECISION);
        uint256 pReward = accumulatedReward.sub(user.rewardDebt);

        ILocker locker = lockers[pid];
        uint256 lockerPendingReward = locker.pendingTokens(to, pid);

        if (pReward == 0 && lockerPendingReward == 0) {
            return;
        }
        if (pReward >= platformToken.balanceOf(address(this))) {
            pReward = platformToken.balanceOf(address(this));
        }

        // Effects
        user.rewardDebt = accumulatedReward;

        // Interactions
        if (address(locker) != address(0)) {
            uint256 lockAmount = locker.calLockAmount(pReward);
            // uint256 lockPendingAmount = _locker.pendingTokens(to, pid);
            platformToken.safeApprove(address(locker), lockAmount);
            locker.lock(to, pid, lockAmount);
            pReward = pReward.sub(lockAmount);
            platformToken.safeApprove(address(locker), 0);
        }

        platformToken.safeTransfer(to, pReward);
        console.log("safeTransfer platformToken: ", pReward);

        emit Harvest(msg.sender, pid, pReward, to);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of the staking tokens.
    function emergencyWithdraw(uint256 pid, address to) external nonReentrant {
        UserInfo storage user = userInfo[pid][msg.sender];
        PoolInfo memory pool = poolInfo[pid];
        require(user.fundedBy == msg.sender, "MinerReward::emergencyWithdraw:: only funder");
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.fundedBy = address(0);
        // Note: transfer can fail or succeed if `amount` is zero.
        pool.stakeToken.safeTransfer(to, amount);
        pool.amount = pool.amount.sub(amount);
        emit EmergencyWithdraw(msg.sender, pid, amount, to);
    }
}
