// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../interfaces/IBuildBurnSystem.sol";
import "../interfaces/IConfig.sol";
import "../interfaces/IDebtSystem.sol";
import "../interfaces/IPrices.sol";
import "../utilities/AddressCache.sol";
import "../utilities/AdminUpgradeable.sol";
import "../libs/SafeDecimalMath.sol";
import "../libs/TransferHelper.sol";
import "../interfaces/ICatalyst.sol";
import "../pancake/IPancakeRouter02.sol";
import "../pancake/IPancakeFactory.sol";
import "../utilities/SafeToken.sol";
import "../pancake/IPancakePair.sol";
import "../interfaces/IPlatformToken.sol";
import "../interfaces/IMinerReward.sol";
import "../interfaces/IExchangeSystem.sol";
import "../interfaces/IAddressStorage.sol";
import "../interfaces/IAsset.sol";

// 单纯抵押进来
// 赎回时需要 债务率良好才能赎回， 赎回部分能保持债务率高于目标债务率
contract CollateralSystem is AdminUpgradeable, PausableUpgradeable, AddressCache {
    using SafeMath for uint256;
    using SafeDecimalMath for uint256;
    using AddressUpgradeable for address;
    using SafeToken for address;

    IERC20 private FUSDToken; // this contract need

    uint256 public constant MAX_UINT256 = 10000000000e18;

    // -------------------------------------------------------
    // need set before system running value.
    IPrices public priceGetter;
    IDebtSystem public debtSystem;
    IConfig public mConfig;
    ICatalyst public mCatalyst;
    IPlatformToken public platformToken;
    IPancakeRouter02 public router;
    IMinerReward public minerReward;
    IExchangeSystem public exchangeSystem;
    IAddressStorage public assetsStorage;

    // -------------------------------------------------------
    uint256 public uniqueId; // use log

    struct TokenInfo {
        address tokenAddress;
        uint256 minCollateral; // min collateral amount.
        uint256 totalCollateral;
        bool bClose; // TODO : 为了防止价格波动，另外再加个折扣价?
    }

    mapping(bytes32 => TokenInfo) public tokenInfos;
    bytes32[] public tokenSymbol; // keys of tokenInfos, use to iteration

    struct CollateralData {
        uint256 collateral;
    }
    struct LockedData {
        uint256 lockedValue;
    }
    // [user] => ([token=> collateraldata])
    mapping(address => mapping(bytes32 => CollateralData)) public userCollateralData;
    mapping(address => mapping(bytes32 => LockedData)) public userLockedData;

    // State variables added by upgrades
    IBuildBurnSystem public buildBurnSystem;
    address public liquidation;

    modifier onlyLiquidation() {
        require(msg.sender == liquidation, "CollateralSystem: not liquidation");
        _;
    }

    modifier onlyExchange() {
        require(msg.sender == address(exchangeSystem), "CollateralSystem: only admin or exchange");
        _;
    }

    function getFreeCollateralInUsd(address user, bytes32 currency) public view returns (uint256) {
        uint256 totalCollateralInUsd = getUserCollateralInUsd(user, currency);
        console.log("getFreeCollateralInUsd - totalCollateralInUsd: %s", totalCollateralInUsd);

        (uint256 debtBalance, ) = debtSystem.GetUserDebtBalanceInUsd(user, currency);
        if (debtBalance == 0) {
            return totalCollateralInUsd;
        }

        // 这里需要考虑催化效果
        (uint256 buildRatio, uint256 defaultRatio) = getRatio(user, currency);
        uint256 _ratio = buildRatio > defaultRatio ? buildRatio : defaultRatio;
        uint256 minCollateral = debtBalance.divideDecimal(_ratio);
        console.log("getFreeCollateralInUsd - buildRatio: %s, minCollateral: %s", _ratio, minCollateral);
        if (totalCollateralInUsd < minCollateral) {
            return 0;
        }

        return totalCollateralInUsd.sub(minCollateral);
    }

    function maxRedeemableToken(address user, bytes32 _currency) public view returns (uint256) {
        (uint256 debtBalance, ) = debtSystem.GetUserDebtBalanceInUsd(user, _currency);
        uint256 stakedTokenAmount = userCollateralData[user][_currency].collateral;

        if (debtBalance == 0) {
            // User doesn't have debt. All staked collateral is withdrawable
            return stakedTokenAmount;
        } else {
            // User has debt. Must keep a certain amount
            uint256 buildRatio = mConfig.getBuildRatio(_currency);
            uint256 minCollateralUsd = debtBalance.divideDecimal(buildRatio);
            uint256 minCollateralPlatformToken = minCollateralUsd.divideDecimal(priceGetter.getPrice(_currency));
            if (stakedTokenAmount >= minCollateralPlatformToken) {
                return MathUpgradeable.min(stakedTokenAmount, stakedTokenAmount.sub(minCollateralPlatformToken));
            } else {
                return 0;
            }
        }
    }

    // -------------------------------------------------------
    function initialize(address _admin, address _FUSDTokenAddr) public initializer {
        AdminUpgradeable.__AdminUpgradeable_init(_admin);
        FUSDToken = IERC20(_FUSDTokenAddr);
    }

    function setPaused(bool _paused) external onlyAdmin {
        if (_paused) {
            _pause();
        } else {
            _unpause();
        }
    }

    // ------------------ system config ----------------------
    function updateAddressCache(IAddressStorage _addressStorage) public override onlyAdmin {
        priceGetter = IPrices(_addressStorage.getAddressWithRequire("Prices", "Prices address not valid"));
        debtSystem = IDebtSystem(_addressStorage.getAddressWithRequire("DebtSystem", "DebtSystem address not valid"));
        mConfig = IConfig(_addressStorage.getAddressWithRequire("Config", "Config address not valid"));
        buildBurnSystem = IBuildBurnSystem(
            _addressStorage.getAddressWithRequire("BuildBurnSystem", "BuildBurnSystem address not valid")
        );
        liquidation = _addressStorage.getAddressWithRequire("Liquidation", "Liquidation address not valid");
        mCatalyst = ICatalyst(
            _addressStorage.getAddressWithRequire("PublicCatalystMath", "Catalyst address not valid")
        );
        platformToken = IPlatformToken(
            _addressStorage.getAddressWithRequire("PlatformToken", "PlatformToken address not valid")
        );
        minerReward = IMinerReward(
            _addressStorage.getAddressWithRequire("MinerReward", "MinerReward address not valid")
        );
        exchangeSystem = IExchangeSystem(
            _addressStorage.getAddressWithRequire("ExchangeSystem", "ExchangeSystem address not valid")
        );

        assetsStorage = IAddressStorage(
            _addressStorage.getAddressWithRequire("AssetSystem", "AssetSystem address not valid")
        );

        emit CachedAddressUpdated("Prices", address(priceGetter));
        emit CachedAddressUpdated("DebtSystem", address(debtSystem));
        emit CachedAddressUpdated("Config", address(mConfig));
        emit CachedAddressUpdated("BuildBurnSystem", address(buildBurnSystem));
        emit CachedAddressUpdated("Liquidation", liquidation);
        emit CachedAddressUpdated("PublicCatalystMath", address(mCatalyst));
        emit CachedAddressUpdated("PlatformToken", address(platformToken));
        emit CachedAddressUpdated("MinerReward", address(minerReward));
        emit CachedAddressUpdated("AssetSystem", address(assetsStorage));
    }

    function _updateTokenInfo(
        bytes32 _currency,
        address _tokenAddress,
        uint256 _minCollateral,
        bool _close
    ) private returns (bool) {
        require(_currency[0] != 0, "symbol cannot empty");
        require(_tokenAddress != address(0), "token address cannot zero");
        require(_tokenAddress.isContract(), "token address is not a contract");

        if (tokenInfos[_currency].tokenAddress == address(0)) {
            // new token
            tokenSymbol.push(_currency);
        }

        uint256 totalCollateral = tokenInfos[_currency].totalCollateral;
        tokenInfos[_currency] = TokenInfo({
            tokenAddress: _tokenAddress,
            minCollateral: _minCollateral,
            totalCollateral: totalCollateral,
            bClose: _close
        });
        emit UpdateTokenSetting(_currency, _tokenAddress, _minCollateral, _close);
        return true;
    }

    // delete token info? need to handle it's staking data.

    function updateTokenInfo(
        bytes32 _currency,
        address _tokenAddress,
        uint256 _minCollateral,
        bool _close
    ) external onlyAdmin returns (bool) {
        return _updateTokenInfo(_currency, _tokenAddress, _minCollateral, _close);
    }

    function updateTokenInfos(
        bytes32[] calldata _symbols,
        address[] calldata _tokenAddresses,
        uint256[] calldata _minCollateral,
        bool[] calldata _closes
    ) external onlyAdmin returns (bool) {
        require(_symbols.length == _tokenAddresses.length, "length of array not eq");
        require(_symbols.length == _minCollateral.length, "length of array not eq");
        require(_symbols.length == _closes.length, "length of array not eq");

        for (uint256 i = 0; i < _symbols.length; i++) {
            _updateTokenInfo(_symbols[i], _tokenAddresses[i], _minCollateral[i], _closes[i]);
        }

        return true;
    }

    // ------------------------------------------------------------------------
    function getSystemTotalCollateralInUsd() public view returns (uint256 total) {
        for (uint256 i = 0; i < tokenSymbol.length; i++) {
            bytes32 currency = tokenSymbol[i];
            uint256 collateralAmount = tokenInfos[currency].totalCollateral;

            if (collateralAmount > 0) {
                total = total.add(collateralAmount.multiplyDecimal(priceGetter.getPrice(currency)));
            }
        }
    }

    // node: 当前版本分开处理抵押物的buildratio，此函数不应该被调用
    function getUserTotalCollateralInUsd(address _user) public view returns (uint256 total) {
        for (uint256 i = 0; i < tokenSymbol.length; i++) {
            bytes32 currency = tokenSymbol[i];
            uint256 collateralAmount = userCollateralData[_user][currency].collateral;

            if (collateralAmount > 0) {
                total = total.add(collateralAmount.multiplyDecimal(priceGetter.getPrice(currency)));
            }
        }
    }

    function getUserCollateralInUsd(address _user, bytes32 _currency) public view returns (uint256 total) {
        uint256 collateralAmount = userCollateralData[_user][_currency].collateral;
        if (collateralAmount > 0) {
            total = collateralAmount.multiplyDecimal(priceGetter.getPrice(_currency));
        }
    }

    function getUserCollateral(address _user, bytes32 _currency) external view returns (uint256) {
        return userCollateralData[_user][_currency].collateral;
    }

    function getUserCollaterals(address _user) external view returns (bytes32[] memory, uint256[] memory) {
        bytes32[] memory rCurrency = new bytes32[](tokenSymbol.length + 1);
        uint256[] memory rAmount = new uint256[](tokenSymbol.length + 1);
        uint256 retSize = 0;
        for (uint256 i = 0; i < tokenSymbol.length; i++) {
            bytes32 currency = tokenSymbol[i];
            if (userCollateralData[_user][currency].collateral > 0) {
                rCurrency[retSize] = currency;
                rAmount[retSize] = userCollateralData[_user][currency].collateral;
                retSize++;
            }
        }

        return (rCurrency, rAmount);
    }

    function getCatalystResult(
        bytes32 stakeCurrency,
        uint256 stakeAmount,
        uint256 lockedAmount
    )
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(stakeAmount > 0, "CollateralSystem:getCatalystResult zero amount");
        require(lockedAmount > 0, "CollateralSystem:getCatalystResult zero lockedAmount");

        uint256 price = priceGetter.getPrice(platformToken.symbolBytes32());
        uint256 valueOfPlatformToken = price.multiplyDecimal(lockedAmount);

        // 计算比台币和抵押物的价值比例
        uint256 stakePrice = priceGetter.getPrice(stakeCurrency);
        uint256 valueOfStake = stakePrice.multiplyDecimal(stakeAmount); // 加上以前的抵押物
        uint256 proportion = valueOfPlatformToken.divideDecimal(valueOfStake); // *e18

        // 计算出催化作用
        uint256 catalystEffect = mCatalyst.calcCatalyst(proportion); // *e18
        console.log("CollateralSystem::getCatalystResult - catalystEffect: %s", catalystEffect);
        return (catalystEffect, proportion, price);
    }

    function checkStakePoolForLockedToken() internal {
        require(minerReward.poolLength() > 0, "CollateralSystem: no pool for locked token");
        // 默认第一个池子是催化剂锁仓池
        IERC20 stakeToken = minerReward.getStakeToken(0);
        require(address(stakeToken) == address(platformToken), "CollateralSystem: invalid pool for locked token");
    }

    /**
     * @dev A unified function for staking collateral and building FUSD atomically. Only up to one of
     * `stakeAmount` and `buildAmount` can be zero.
     *
     * @param stakeCurrency ID of the collateral currency
     * @param stakeAmount Amount of collateral currency to stake, can be zero
     * @param buildAmount Amount of FUSD to build, can be zero
     */
    function stakeAndBuild(
        bytes32 stakeCurrency,
        uint256 stakeAmount,
        uint256 buildAmount,
        uint256 lockedAmount
    ) external whenNotPaused {
        stakeAndBuildBasic(stakeCurrency, stakeAmount, buildAmount, lockedAmount, false);
    }

    /**
     * @dev A unified function for staking collateral and building FUSD atomically. Only up to one of
     * `stakeAmount` and `buildAmount` can be zero.
     *
     * @param stakeCurrency ID of the collateral currency
     * @param stakeAmount Amount of collateral currency to stake, can be zero
     * @param buildAmount Amount of FUSD to build, can be zero
     */
    function stakeAndBuildBasic(
        bytes32 stakeCurrency,
        uint256 stakeAmount,
        uint256 buildAmount,
        uint256 lockedAmount,
        bool isAdvanced
    ) internal whenNotPaused {
        require(stakeAmount > 0 || buildAmount > 0, "CollateralSystem: zero amount");
        // 把用户的平台币转到合约里面
        // TODO: 锁住平台币，并且线性奖励平台币，糖水池子
        if (lockedAmount > 0) {
            platformToken.transferFrom(msg.sender, address(this), lockedAmount);
            userLockedData[msg.sender][stakeCurrency].lockedValue = userLockedData[msg.sender][stakeCurrency]
                .lockedValue
                .add(lockedAmount);
            checkStakePoolForLockedToken();
            // 默认第一个池子是催化剂锁仓池
            platformToken.approve(address(minerReward), lockedAmount);
            minerReward.deposit(msg.sender, 0, lockedAmount);
        }
        uint256 maxCanBuild = getMaxBuildAmount(stakeCurrency, stakeAmount, "FUSD", lockedAmount);

        if (stakeAmount > 0) {
            _collateral(msg.sender, stakeCurrency, stakeAmount);
        }
        if (buildAmount > 0) {
            console.log("CollateralSystem: maxCanBuild: %s, buildAmount: %s ", maxCanBuild, buildAmount);
            require(buildAmount <= maxCanBuild, "Build amount too big, you need more collateral");
            if (isAdvanced) {
                buildBurnSystem.buildFromCollateralSys(msg.sender, buildAmount, stakeCurrency, address(this));
            } else {
                buildBurnSystem.buildFromCollateralSys(msg.sender, buildAmount, stakeCurrency, msg.sender);
            }
        }
        (uint256 ratio, ) = getRatio(msg.sender, stakeCurrency);
        emit Mint(msg.sender, stakeCurrency, stakeAmount, lockedAmount, buildAmount, ratio);
    }

    /**
     * @dev A unified function for staking collateral and building non-FUSD synthetics atomically. Only up to one of
     * `stakeAmount` and `buildAmount` can be zero.
     *
     * @param stakeCurrency ID of the collateral currency
     * @param stakeAmount Amount of collateral currency to stake, can be zero
     * @param buildCurrency ID of the currency to build
     * @param buildAmount Amount to build, can be zero.
     * @param lockedAmount Amount of locked token
     */
    function stakeAndBuildNonFUSD(
        bytes32 stakeCurrency,
        uint256 stakeAmount,
        bytes32 buildCurrency,
        uint256 buildAmount,
        uint256 lockedAmount
    ) external whenNotPaused {
        uint256 buildCurrencyPrice = priceGetter.getPrice(buildCurrency);
        uint256 buildFUSDAmount = buildAmount.multiplyDecimal(buildCurrencyPrice);
        stakeAndBuildBasic(stakeCurrency, stakeAmount, buildFUSDAmount, lockedAmount, true);
        FUSDToken.approve(address(exchangeSystem), buildFUSDAmount);
        exchangeSystem.exchangeFromCollateral(
            "FUSD",
            buildFUSDAmount,
            msg.sender,
            buildCurrency,
            stakeCurrency,
            stakeAmount
        );
    }

    function getMaxBuildAmount(
        bytes32 stakeCurrency,
        uint256 stakeAmount,
        bytes32 buildCurrency,
        uint256 lockedAmount
    ) public view returns (uint256) {
        uint256 buildRatio = calcBuildRatio(msg.sender, stakeCurrency, stakeAmount, lockedAmount);
        uint256 freeCollateral = getFreeCollateralInUsd(msg.sender, stakeCurrency);
        console.log("CollateralSystem::stakeAndBuild buildRatio: %s", buildRatio);

        uint256 stakePrice = priceGetter.getPrice(stakeCurrency);
        console.log("CollateralSystem::stakeAndBuild stakePrice: %s, stakeAmount: %s", stakePrice, stakeAmount);
        uint256 valueOfStake = freeCollateral.add(stakePrice.multiplyDecimal(stakeAmount)); // 加上以前的抵押物
        console.log("CollateralSystem::stakeAndBuild valueOfStake: %s", valueOfStake);

        uint256 maxCanBuildFUSD = valueOfStake.multiplyDecimal(buildRatio);
        console.log("CollateralSystem:::stakeAndBuild maxCanBuild: %s", maxCanBuildFUSD);

        if (buildCurrency != "FUSD") {
            uint256 buildPrice = priceGetter.getPrice(buildCurrency);
            uint256 maxCanBuild = maxCanBuildFUSD.divideDecimal(buildPrice);
            return maxCanBuild;
        }
        return maxCanBuildFUSD;
    }

    /**
     * @dev A unified function for burning FUSD and unstaking collateral atomically. Only up to one of
     * `burnAmount` and `unStakeAmount` can be zero.
     *
     * @param burnAmount Amount of FUSD to burn, can be zero
     * @param unStakeCurrency ID of the collateral currency
     * @param unStakeAmount Amount of collateral currency to unstake, can be zero
     */
    function burnAndUnstake(
        uint256 burnAmount,
        bytes32 unStakeCurrency,
        uint256 unStakeAmount
    ) external whenNotPaused {
        _burnAndUnstakeBasic(msg.sender, burnAmount, unStakeCurrency, unStakeAmount);
    }

    /**
     * @dev A unified function for burning FUSD and unstaking collateral atomically. Only up to one of
     * `burnAmount` and `unStakeAmount` can be zero.
     *
     * @param burnAmount Amount of FUSD to burn, can be zero
     * @param unStakeCurrency ID of the collateral currency
     * @param unStakeAmount Amount of collateral currency to unstake, can be zero
     */
    function burnAndUnstakeFromExchange(
        address user,
        uint256 burnAmount,
        bytes32 unStakeCurrency,
        uint256 unStakeAmount
    ) external whenNotPaused onlyExchange {
        _burnAndUnstakeBasic(user, burnAmount, unStakeCurrency, unStakeAmount);
    }

    /**
     * @dev A unified function for burning FUSD and unstaking collateral atomically. Only up to one of
     * `burnAmount` and `unStakeAmount` can be zero.
     *
     * @param burnAmount Amount of FUSD to burn, can be zero
     * @param unStakeCurrency ID of the collateral currency
     * @param unStakeAmount Amount of collateral currency to unstake, can be zero
     */
    function _burnAndUnstakeBasic(
        address user,
        uint256 burnAmount,
        bytes32 unStakeCurrency,
        uint256 unStakeAmount
    ) internal whenNotPaused {
        require(burnAmount > 0 || unStakeAmount > 0, "CollateralSystem: zero amount");

        if (burnAmount > 0) {
            buildBurnSystem.burnFromCollateralSys(user, burnAmount, unStakeCurrency);
        }

        if (unStakeAmount > 0) {
            _redeem(user, unStakeCurrency, unStakeAmount);
        }
        uint256 unlocked = withdrawLockedTokens(user, unStakeCurrency);
        (uint256 ratio, ) = getRatio(user, unStakeCurrency);
        emit Burn(user, unStakeCurrency, unStakeAmount, unlocked, burnAmount, ratio);
    }

    /**
     * @dev A unified function for burning non-FUSD and unstaking collateral atomically. Only up to one of
     * `burnAmount` and `unStakeAmount` can be zero.
     * @param burnCurrency Token to burn
     * @param burnAmount Amount of token to burn, can be zero
     * @param unStakeCurrency ID of the collateral currency
     * @param unStakeAmount Amount of collateral currency to unstake, can be zero
     */
    function burnNonFUSDAndUnstake(
        bytes32 burnCurrency,
        uint256 burnAmount,
        bytes32 unStakeCurrency,
        uint256 unStakeAmount
    ) external whenNotPaused {
        require(burnAmount > 0 || unStakeAmount > 0, "CollateralSystem: zero amount");

        IAsset source = IAsset(
            assetsStorage.getAddressWithRequire(burnCurrency, "ExchangeSystem: source asset not found")
        );
        // The `move` method is a special variant of `transferForm` that doesn't require approval.
        source.transferFrom(msg.sender, address(this), burnAmount);
        source.approve(address(exchangeSystem), burnAmount);
        exchangeSystem.exchangeFromCollateral(
            burnCurrency,
            burnAmount,
            msg.sender,
            "FUSD",
            unStakeCurrency,
            unStakeAmount
        );
    }

    /**
     * @dev A unified function for burning FUSD and unstaking the maximum amount of collateral atomically.
     *
     * @param burnAmount Amount of FUSD to burn
     * @param unStakeCurrency ID of the collateral currency
     */
    function burnAndUnstakeMax(uint256 burnAmount, bytes32 unStakeCurrency) external whenNotPaused {
        require(burnAmount > 0, "CollateralSystem: zero amount");
        buildBurnSystem.burnFromCollateralSys(msg.sender, burnAmount, unStakeCurrency);
        _redeemMax(msg.sender, unStakeCurrency);
        uint256 unlockedAmount = withdrawLockedTokens(msg.sender, unStakeCurrency);
        uint256 unStakeAmount = maxRedeemableToken(msg.sender, unStakeCurrency);
        emit Burn(msg.sender, unStakeCurrency, unStakeAmount, unlockedAmount, burnAmount, 0);
    }

    /**
     * @dev withdraw Locked Tokens if debt is 0
     */
    function withdrawLockedTokens(address user, bytes32 currency) public whenNotPaused returns (uint256) {
        (uint256 debtBalance, ) = debtSystem.GetUserDebtBalanceInUsd(user, currency);
        uint256 unlocked = 0;
        uint256 lockedValue = userLockedData[user][currency].lockedValue;
        if (debtBalance == 0 && lockedValue > 0) {
            platformToken.approve(address(this), lockedValue);
            unlocked = lockedValue;
            userLockedData[user][currency].lockedValue = 0;
            // 触发催化剂锁仓池withdraw
            checkStakePoolForLockedToken();
            minerReward.withdraw(user, 0, unlocked);
            platformToken.transferFrom(address(this), user, lockedValue);
        }
        return unlocked;
    }

    function _collateral(
        address user,
        bytes32 _currency,
        uint256 _amount
    ) private whenNotPaused returns (bool) {
        require(tokenInfos[_currency].tokenAddress.isContract(), "invalid token symbol");
        TokenInfo storage tokenInfo = tokenInfos[_currency];
        require(_amount > tokenInfo.minCollateral, "collateral amount too small");
        require(tokenInfo.bClose == false, "token is closed");

        IERC20 erc20 = IERC20(tokenInfos[_currency].tokenAddress);
        require(erc20.balanceOf(user) >= _amount, "insufficient balance");
        require(erc20.allowance(user, address(this)) >= _amount, "insufficient allowance, need approve more amount");

        erc20.transferFrom(user, address(this), _amount);

        userCollateralData[user][_currency].collateral = userCollateralData[user][_currency].collateral.add(_amount);
        tokenInfo.totalCollateral = tokenInfo.totalCollateral.add(_amount);

        emit CollateralLog(user, _currency, _amount, userCollateralData[user][_currency].collateral);
        return true;
    }

    /**
     * @return [0] current ratio. [1] default ratio of currency.
     */
    function getRatio(address _user, bytes32 _currency) public view returns (uint256, uint256) {
        uint256 buildRatio = mConfig.getBuildRatio(_currency);
        (uint256 debtBalance, ) = debtSystem.GetUserDebtBalanceInUsd(_user, _currency);
        if (debtBalance == 0) {
            console.log("getRatio - debtBalance == 0");
            return (buildRatio, buildRatio);
        }

        uint256 totalCollateralInUsd = getUserCollateralInUsd(_user, _currency);
        if (totalCollateralInUsd == 0) {
            console.log("totalCollateralInUsd == 0");
            return (buildRatio, buildRatio);
        }
        console.log("getRatio - debtBalance: %s, totalCollateralInUsd: %s", debtBalance, totalCollateralInUsd);
        uint256 ratio = debtBalance.divideDecimal(totalCollateralInUsd);
        return (ratio, buildRatio);
    }

    function isSatisfyTargetRatio(address _user, bytes32 _currency) public view returns (bool) {
        (uint256 debtBalance, ) = debtSystem.GetUserDebtBalanceInUsd(_user, _currency);
        if (debtBalance == 0) {
            return true;
        }

        uint256 buildRatio = mConfig.getBuildRatio(_currency);
        uint256 totalCollateralInUsd = getUserCollateralInUsd(_user, _currency);
        if (totalCollateralInUsd == 0) {
            return false;
        }
        uint256 ratio = debtBalance.divideDecimal(totalCollateralInUsd);
        return ratio <= buildRatio;
    }

    function redeemMax(bytes32 _currency) external whenNotPaused {
        _redeemMax(msg.sender, _currency);
    }

    function calcBuildRatio(
        address user,
        bytes32 stakeCurrency,
        uint256 stakeAmount,
        uint256 lockedAmount
    ) public view returns (uint256) {
        uint256 oldLockedValue = userLockedData[user][stakeCurrency].lockedValue;
        uint256 buildRatio;
        if (lockedAmount > 0 || oldLockedValue > 0) {
            uint256 newLockedValue = oldLockedValue.add(lockedAmount);
            uint256 newStakeValue = stakeAmount.add(userCollateralData[user][stakeCurrency].collateral);

            (uint256 catalystEffect, , ) = getCatalystResult(stakeCurrency, newStakeValue, newLockedValue);
            (uint256 _buildRatio, uint256 defaultRatio) = getRatio(user, stakeCurrency);
            console.log("_lockTokenAndCalcBuildRatio - buildRatio before: %s", buildRatio);
            _buildRatio = _buildRatio.multiplyDecimal(catalystEffect.add(SafeDecimalMath.unit()));
            buildRatio = _buildRatio > defaultRatio ? _buildRatio : defaultRatio;
        } else {
            buildRatio = mConfig.getBuildRatio(stakeCurrency);
        }
        console.log("_lockTokenAndCalcBuildRatio: buildRatio: %s", buildRatio);
        return buildRatio;
    }

    function _redeemMax(address user, bytes32 _currency) private {
        _redeem(user, _currency, maxRedeemableToken(user, _currency));
    }

    function _redeem(
        address user,
        bytes32 _currency,
        uint256 _amount
    ) internal {
        require(_amount > 0, "CollateralSystem: zero amount");

        uint256 maxRedeemableAmount = maxRedeemableToken(user, _currency);
        console.log("CollateralSystem: maxRedeemableAmount", maxRedeemableAmount);
        console.log("CollateralSystem: _amount", _amount);

        if (_amount > maxRedeemableAmount) {
            _amount = maxRedeemableAmount;
        }

        userCollateralData[user][_currency].collateral = userCollateralData[user][_currency].collateral.sub(_amount);

        TokenInfo storage tokenInfo = tokenInfos[_currency];
        tokenInfo.totalCollateral = tokenInfo.totalCollateral.sub(_amount);

        IERC20(tokenInfo.tokenAddress).transfer(user, _amount);

        emit RedeemCollateral(user, _currency, _amount, userCollateralData[user][_currency].collateral);
    }

    // 1. After redeem, collateral ratio need bigger than target ratio.
    // 2. Cannot redeem more than collateral.
    function redeem(bytes32 _currency, uint256 _amount) external whenNotPaused returns (bool) {
        address user = msg.sender;
        _redeem(user, _currency, _amount);
        return true;
    }

    function moveCollateral(
        address fromUser,
        address toUser,
        bytes32 currency,
        uint256 amount
    ) external whenNotPaused onlyLiquidation {
        userCollateralData[fromUser][currency].collateral = userCollateralData[fromUser][currency].collateral.sub(
            amount
        );
        userCollateralData[toUser][currency].collateral = userCollateralData[toUser][currency].collateral.add(amount);
        emit CollateralMoved(fromUser, toUser, currency, amount);
    }

    event UpdateTokenSetting(bytes32 symbol, address tokenAddress, uint256 minCollateral, bool close);
    event CollateralLog(address user, bytes32 _currency, uint256 _amount, uint256 _userTotal);
    event RedeemCollateral(address user, bytes32 _currency, uint256 _amount, uint256 _userTotal);
    event CollateralMoved(address fromUser, address toUser, bytes32 currency, uint256 amount);
    event Mint(
        address user,
        bytes32 collateralCurrency,
        uint256 collateralAmount,
        uint256 lockedAmount,
        uint256 mintedAmount,
        uint256 ratio
    );
    event Burn(
        address user,
        bytes32 unstakingCurrency,
        uint256 unstakingAmount,
        uint256 unlockedAmount,
        uint256 cleanedDebt,
        uint256 ratio
    );
    // Reserved storage space to allow for layout changes in the future.
    uint256[41] private __gap;
}
