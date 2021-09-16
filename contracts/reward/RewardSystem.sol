// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts-upgradeable/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../interfaces/ICollateralSystem.sol";
import "../utilities/AdminUpgradeable.sol";

/**
 * @title RewardSystem
 *
 * @dev A contract for distributing exchange fees based on amounts calculated and signed off-chain.
 *
 * This contract only performs basic signature validation and re-entrance prevention
 * to minimize the cost of claming rewards.
 *
 * Period ID starts from 1, not zero.
 */
contract RewardSystem is AdminUpgradeable {
    using ECDSAUpgradeable for bytes32;
    using SafeMathUpgradeable for uint256;

    event RewardSignerChanged(address oldSigner, address newSigner);
    event RewardClaimed(address recipient, uint256 periodId, uint256 feeReward);

    uint256 public firstPeriodStartTime;
    address public rewardSigner;
    mapping(address => uint256) public userLastClaimPeriodIds;

    IERC20Upgradeable public fusd;
    ICollateralSystem public collateralSystem;

    bytes32 public DOMAIN_SEPARATOR; // For EIP-712

    /* EIP-712 type hashes */
    bytes32 public constant REWARD_TYPEHASH =
    keccak256("Reward(uint256 periodId,address recipient,uint256 feeReward)");

    uint256 public constant PERIOD_LENGTH = 1 weeks;

    function getCurrentPeriodId() public view returns (uint256) {
        require(block.timestamp >= firstPeriodStartTime, "RewardSystem: first period not started");
        return (block.timestamp - firstPeriodStartTime) / PERIOD_LENGTH + 1;
        // No SafeMath needed
    }

    function getPeriodStartTime(uint256 periodId) public view returns (uint256) {
        require(periodId > 0, "RewardSystem: period ID must be positive");
        return firstPeriodStartTime.add(periodId.sub(1).mul(PERIOD_LENGTH));
    }

    function getPeriodEndTime(uint256 periodId) public view returns (uint256) {
        require(periodId > 0, "RewardSystem: period ID must be positive");
        return firstPeriodStartTime.add(periodId.mul(PERIOD_LENGTH));
    }

    function initialize(
        uint256 _firstPeriodStartTime,
        address _rewardSigner,
        address _fusdAddress,
        address _collateralSystemAddress,
        address _admin
    ) public initializer {
        AdminUpgradeable.__AdminUpgradeable_init(_admin);

        /**
         * The next line is commented out to make migration from Ethereum to Binance Smart
         * chain possible.
         */
        // require(block.timestamp < _firstPeriodStartTime + PERIOD_LENGTH, "RewardSystem: first period already ended");

        firstPeriodStartTime = _firstPeriodStartTime;

        _setRewardSigner(_rewardSigner);

        require(
            _fusdAddress != address(0) && _collateralSystemAddress != address(0),
            "RewardSystem: zero address"
        );
        fusd = IERC20Upgradeable(_fusdAddress);
        collateralSystem = ICollateralSystem(_collateralSystemAddress);

        // While we could in-theory calculate the EIP-712 domain separator off-chain, doing
        // it on-chain simplifies deployment and the cost here is one-off and acceptable.
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("IronForge")),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    function setRewardSigner(address _rewardSigner) external onlyAdmin {
        _setRewardSigner(_rewardSigner);
    }

    function claimReward(
        uint256 periodId,
        uint256 feeReward,
        bytes calldata signature
    ) external {
        _claimReward(periodId, msg.sender, feeReward, signature);
    }

    function claimRewardFor(
        uint256 periodId,
        address recipient,
        uint256 feeReward,
        bytes calldata signature
    ) external {
        _claimReward(periodId, recipient, feeReward, signature);
    }

    function _setRewardSigner(address _rewardSigner) private {
        require(_rewardSigner != address(0), "RewardSystem: zero address");
        require(_rewardSigner != rewardSigner, "RewardSystem: signer not changed");

        address oldSigner = rewardSigner;
        rewardSigner = _rewardSigner;

        emit RewardSignerChanged(oldSigner, rewardSigner);
    }

    function _claimReward(
        uint256 periodId,
        address recipient,
        uint256 feeReward,
        bytes calldata signature
    ) private {
        require(periodId > 0, "RewardSystem: period ID must be positive");
        require(feeReward > 0, "RewardSystem: nothing to claim");

        // Check if the target period is in the claiming window
        uint256 currentPeriodId = getCurrentPeriodId();
        require(periodId < currentPeriodId, "RewardSystem: period not ended");

        // Re-entrance prevention
        require(userLastClaimPeriodIds[recipient] < periodId, "RewardSystem: reward already claimed");
        userLastClaimPeriodIds[recipient] = periodId;

        // Verify EIP-712 signature
        bytes32 digest =
        keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(REWARD_TYPEHASH, periodId, recipient, feeReward))
            )
        );
        address recoveredAddress = digest.recover(signature);
        require(recoveredAddress == rewardSigner, "RewardSystem: invalid signature");

        if (feeReward > 0) {
            fusd.transfer(recipient, feeReward);
        }

        emit RewardClaimed(recipient, periodId, feeReward);
    }

    // Reserved storage space to allow for layout changes in the future.
    uint256[43] private __gap;
}
