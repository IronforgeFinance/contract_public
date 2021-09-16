// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "hardhat/console.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../interfaces/IAccessControl.sol";
import "../interfaces/IAssetSystem.sol";
import "../utilities/AdminUpgradeable.sol";
import "../utilities/AddressCache.sol";
import "../libs/SafeDecimalMath.sol";
import "../interfaces/IDebtSystem.sol";

contract DebtSystem is AdminUpgradeable, AddressCache, IDebtSystem {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    // -------------------------------------------------------
    // need set before system running value.
    IAccessControl private accessCtrl;
    IAssetSystem private assetSys;
    // -------------------------------------------------------
    struct DebtData {
        uint256 debtProportion;
        uint256 debtFactor; // PRECISE_UNIT
    }

    // <currency => <account => DebtData>>
    mapping(bytes32 => mapping(address => DebtData)) private curUserDebtState;

    //use mapping to store array data <currency => lastDebtFactors>
    //    mapping(bytes32 => uint256) public lastDebtFactors;
    uint256 public lastDebtFactor;

    // -------------------------------------------------------
    function initialize(address _admin) public initializer {
        AdminUpgradeable.__AdminUpgradeable_init(_admin);
    }

    event UpdateAddressStorage(address oldAddr, address newAddr);
    event UpdateUserDebtLog(address addr, uint256 debtProportion, uint256 debtFactor, uint256 timestamp);
    event PushDebtLog(uint256 newFactor, uint256 timestamp);

    // ------------------ system config ----------------------
    function updateAddressCache(IAddressStorage _addressStorage) public override onlyAdmin {
        accessCtrl = IAccessControl(
            _addressStorage.getAddressWithRequire("AccessControl", "AccessControl address not valid")
        );
        assetSys = IAssetSystem(_addressStorage.getAddressWithRequire("AssetSystem", "AssetSystem address not valid"));

        emit CachedAddressUpdated("AccessControl", address(accessCtrl));
        emit CachedAddressUpdated("AssetSystem", address(assetSys));
    }

    // -----------------------------------------------
    modifier OnlyDebtSystemRole(address _address) {
        require(accessCtrl.hasRole(accessCtrl.DEBT_SYSTEM(), _address), "Need debt system access role");
        _;
    }

    function _pushDebtFactor(uint256 _factor) private {
        if (lastDebtFactor == 0 || _factor == 0) {
            // init or all debt has be cleared, new set value will be one unit
            console.log("DebtSystem::_pushDebtFactor nit or all debt has be cleared, new set value will be one unit");
            lastDebtFactor = SafeDecimalMath.preciseUnit();
        } else {
            lastDebtFactor = lastDebtFactor.multiplyDecimalRoundPrecise(_factor);
            console.log("DebtSystem::_pushDebtFactor lastDebtFactor: %s", lastDebtFactor);
        }
        emit PushDebtLog(lastDebtFactor, block.timestamp);
    }

    function PushDebtFactor(uint256 _factor) external OnlyDebtSystemRole(msg.sender) {
        _pushDebtFactor(_factor);
    }

    function _updateUserDebt(address _user, uint256 _debtProportion, bytes32 _currency) private {
        console.log("DebtSystem::_updateUserDebt _user: %s, _debtProportion: %s", _user, _debtProportion);
        curUserDebtState[_currency][_user].debtProportion = _debtProportion;
        curUserDebtState[_currency][_user].debtFactor = _lastSystemDebtFactor();
        emit UpdateUserDebtLog(_user, _debtProportion, curUserDebtState[_currency][_user].debtFactor, block.timestamp);
    }

    // need update lastDebtFactors first
    function UpdateUserDebt(address _user, uint256 _debtProportion, bytes32 _currency) external OnlyDebtSystemRole(msg.sender) {
        _updateUserDebt(_user, _debtProportion, _currency);
    }

    function UpdateDebt(
        address _user,
        uint256 _debtProportion,
        uint256 _factor,
        bytes32 _currency
    ) external override OnlyDebtSystemRole(msg.sender) {
        console.log("DebtSystem::UpdateDebt _user: %s, _debtProportion: %s", _user, _debtProportion);
        console.log("DebtSystem::UpdateDebt _factor: %s, _currency: %s", _factor, string(abi.encodePacked(_currency)));
        _pushDebtFactor(_factor);
        _updateUserDebt(_user, _debtProportion, _currency);
    }

    function GetUserDebtData(address _user, bytes32 _currency) external view returns (uint256 debtProportion, uint256 debtFactor) {
        debtProportion = curUserDebtState[_currency][_user].debtProportion;
        debtFactor = curUserDebtState[_currency][_user].debtFactor;
    }

    function _lastSystemDebtFactor() private view returns (uint256) {
        if (lastDebtFactor == 0) {
            console.log("DebtSystem::_lastSystemDebtFactor lastDebtFactor == 0, return preciseUnit");
            return SafeDecimalMath.preciseUnit();
        }
        console.log("DebtSystem::_lastSystemDebtFactor lastDebtFactor: %s", lastDebtFactor);
        return lastDebtFactor;
    }

    function LastSystemDebtFactor() external view returns (uint256) {
        return _lastSystemDebtFactor();
    }

    function GetUserCurrentDebtProportion(address _user, bytes32 _currency) public view returns (uint256) {
        console.log("DebtSystem::GetUserCurrentDebtProportion _user: %s, _debtProportion: %s", _user, string(abi.encodePacked(_currency)));
        uint256 debtProportion = curUserDebtState[_currency][_user].debtProportion;
        uint256 debtFactor = curUserDebtState[_currency][_user].debtFactor;

        console.log("DebtSystem::GetUserCurrentDebtProportion debtFactor: %s, debtProportion: %s", debtFactor, debtProportion);

        if (debtProportion == 0) {
            console.log("DebtSystem::GetUserCurrentDebtProportion debtProportion==0");
            return 0;
        }

        uint256 currentUserDebtProportion =
        _lastSystemDebtFactor().divideDecimalRoundPrecise(debtFactor).multiplyDecimalRoundPrecise(debtProportion);
        console.log("DebtSystem::GetUserCurrentDebtProportion currentUserDebtProportion: %s", currentUserDebtProportion);

        return currentUserDebtProportion;
    }

    /**
     *@return [0] the debt balance of user. [1] system total asset in usd.
     */
    function GetUserDebtBalanceInUsd(address _user, bytes32 _currency) external override view returns (uint256, uint256) {
        console.log("DebtSystem::GetUserDebtBalanceInUsd start. _user: %s, _currency: %s", _user, string(abi.encodePacked(_currency)));

        uint256 totalAssetSupplyInUsd = assetSys.totalAssetsInUsd();

        uint256 debtProportion = curUserDebtState[_currency][_user].debtProportion;
        uint256 debtFactor = curUserDebtState[_currency][_user].debtFactor;
        console.log("DebtSystem::GetUserDebtBalanceInUsd 1 debtProportion: %s, debtFactor: %s", debtProportion, debtFactor);

        if (debtProportion == 0) {
            console.log("DebtSystem::GetUserDebtBalanceInUsd 2 userDebtBalance: %s, totalAssetSupplyInUsd: %s", 0, totalAssetSupplyInUsd);
            return (0, totalAssetSupplyInUsd);
        }

        uint256 currentUserDebtProportion =
        _lastSystemDebtFactor().divideDecimalRoundPrecise(debtFactor).multiplyDecimalRoundPrecise(debtProportion);
        uint256 userDebtBalance =
        totalAssetSupplyInUsd
        .decimalToPreciseDecimal()
        .multiplyDecimalRoundPrecise(currentUserDebtProportion)
        .preciseDecimalToDecimal();
        console.log("DebtSystem::GetUserDebtBalanceInUsd 3 userDebtBalance: %s, totalAssetSupplyInUsd: %s, currentUserDebtProportion: %s", userDebtBalance, totalAssetSupplyInUsd, currentUserDebtProportion);

        return (userDebtBalance, totalAssetSupplyInUsd);
    }

    // Reserved storage space to allow for layout changes in the future.
    uint256[42] private __gap;
}
