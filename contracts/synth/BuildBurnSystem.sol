// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "hardhat/console.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../libs/SafeDecimalMath.sol";
import "../interfaces/IPrices.sol";
import "../utilities/AddressCache.sol";
import "../interfaces/IAsset.sol";
import "../interfaces/IDebtSystem.sol";
import "../interfaces/ICollateralSystem.sol";
import "../interfaces/IConfig.sol";
import "../utilities/AdminUpgradeable.sol";
import "../utilities/AddressCache.sol";
import "../interfaces/IBuildBurnSystem.sol";

// 根据 CollateralSystem 的抵押资产计算相关抵押率，buildable fusd
contract BuildBurnSystem is AdminUpgradeable, PausableUpgradeable, AddressCache, IBuildBurnSystem {
    using SafeMath for uint256;
    using SafeDecimalMath for uint256;

    // -------------------------------------------------------
    // need set before system running value.
    IAsset private FUSDToken; // this contract need

    IDebtSystem private debtSystem;
    IPrices private priceGetter;
    ICollateralSystem private collateralSystem;
    IConfig private mConfig;
    address private liquidation;

    modifier onlyCollateralSystem() {
        require((msg.sender == address(collateralSystem)), "BuildBurnSystem: not collateral system");
        _;
    }

    modifier onlyLiquidation() {
        require((msg.sender == liquidation), "BuildBurnSystem: not liquidation");
        _;
    }

    // -------------------------------------------------------
    function initialize(address admin, address _FUSDTokenAddr) public initializer {
        AdminUpgradeable.__AdminUpgradeable_init(admin);
        FUSDToken = IAsset(_FUSDTokenAddr);
    }

    function setPaused(bool _paused) external onlyAdmin {
        if (_paused) {
            _pause();
        } else {
            _unpause();
        }
    }

    function updateAddressCache(IAddressStorage _addressStorage) public override onlyAdmin {
        priceGetter = IPrices(_addressStorage.getAddressWithRequire("Prices", "Prices address not valid"));
        debtSystem = IDebtSystem(_addressStorage.getAddressWithRequire("DebtSystem", "DebtSystem address not valid"));
        address payable collateralAddress = payable(
            _addressStorage.getAddressWithRequire("CollateralSystem", "CollateralSystem address not valid")
        );
        collateralSystem = ICollateralSystem(collateralAddress);
        mConfig = IConfig(_addressStorage.getAddressWithRequire("Config", "Config address not valid"));
        liquidation = _addressStorage.getAddressWithRequire("Liquidation", "Liquidation address not valid");

        emit CachedAddressUpdated("Prices", address(priceGetter));
        emit CachedAddressUpdated("DebtSystem", address(debtSystem));
        emit CachedAddressUpdated("CollateralSystem", address(collateralSystem));
        emit CachedAddressUpdated("Config", address(mConfig));
        emit CachedAddressUpdated("Liquidation", liquidation);
    }

    function SetLusdTokenAddress(address _address) public onlyAdmin {
        emit UpdateLusdToken(address(FUSDToken), _address);
        FUSDToken = IAsset(_address);
    }

    event UpdateLusdToken(address oldAddr, address newAddr);

    function MaxCanBuildAsset(
        address user,
        bytes32 _currency,
        uint256 buildRatio
    ) public view returns (uint256) {
        uint256 maxCanBuild = collateralSystem.getFreeCollateralInUsd(user, _currency).mul(buildRatio).div(
            SafeDecimalMath.unit()
        );
        console.log("BuildBurnSystem::MaxCanBuildAsset buildRatio: %s， maxCanBuild: %s", buildRatio, maxCanBuild);
        return maxCanBuild;
    }

    function _buildAsset(
        address user,
        uint256 amount,
        bytes32 currency,
        address receiver
    ) internal returns (bool) {
        console.log("BuildBurnSystem::_buildAsset start");
        // calc debt
        (uint256 oldUserDebtBalance, uint256 totalAssetSupplyInUsd) = debtSystem.GetUserDebtBalanceInUsd(
            user,
            currency
        );

        uint256 newTotalAssetSupply = totalAssetSupplyInUsd.add(amount);
        // update debt data
        uint256 buildDebtProportion = amount.divideDecimalRoundPrecise(newTotalAssetSupply);
        // debtPercentage
        uint256 oldTotalProportion = SafeDecimalMath.preciseUnit().sub(buildDebtProportion);
        uint256 newUserDebtProportion = buildDebtProportion;
        if (oldUserDebtBalance > 0) {
            newUserDebtProportion = oldUserDebtBalance.add(amount).divideDecimalRoundPrecise(newTotalAssetSupply);
        }

        // update debt
        debtSystem.UpdateDebt(user, newUserDebtProportion, oldTotalProportion, currency);

        // mint asset
        FUSDToken.mint(receiver, amount);

        return true;
    }

    function _burnAsset(
        address debtUser,
        uint256 amount,
        bytes32 _currency
    ) internal {
        console.log("BuildBurnSystem::_burnAsset debtUser: %s,", debtUser);
        require(amount > 0, "amount need > 0");
        // calc debt
        (uint256 oldUserDebtBalance, uint256 totalAssetSupplyInUsd) = debtSystem.GetUserDebtBalanceInUsd(
            debtUser,
            _currency
        );
        require(oldUserDebtBalance > 0, "no debt, no burn");
        uint256 burnAmount = oldUserDebtBalance < amount ? oldUserDebtBalance : amount;
        // burn asset
        FUSDToken.burn(debtUser, burnAmount);

        uint256 newTotalDebtIssued = totalAssetSupplyInUsd.sub(burnAmount);

        uint256 oldTotalProportion = 0;
        if (newTotalDebtIssued > 0) {
            uint256 debtPercentage = burnAmount.divideDecimalRoundPrecise(newTotalDebtIssued);
            oldTotalProportion = SafeDecimalMath.preciseUnit().add(debtPercentage);
        }

        uint256 newUserDebtProportion = 0;
        if (oldUserDebtBalance > burnAmount) {
            uint256 newDebt = oldUserDebtBalance.sub(burnAmount);
            newUserDebtProportion = newDebt.divideDecimalRoundPrecise(newTotalDebtIssued);
        }

        // update debt
        debtSystem.UpdateDebt(debtUser, newUserDebtProportion, oldTotalProportion, _currency);
    }

    function buildFromCollateralSys(
        address user,
        uint256 amount,
        bytes32 currency,
        address receiver
    ) external override whenNotPaused onlyCollateralSystem {
        console.log("BuildBurnSystem::buildFromCollateralSys user: %s, amount: %s", user, amount);
        _buildAsset(user, amount, currency, receiver);
    }

    function burnFromCollateralSys(
        address user,
        uint256 amount,
        bytes32 currency
    ) external override whenNotPaused onlyCollateralSystem {
        _burnAsset(user, amount, currency);
    }

    function burnForLiquidation(
        address user,
        uint256 amount,
        bytes32 _currency
    ) external override whenNotPaused onlyLiquidation {
        console.log("BuildBurnSystem::burnForLiquidation user: %s", user);
        _burnAsset(user, amount, _currency);
    }

    // Reserved storage space to allow for layout changes in the future.
    uint256[44] private __gap;
}
