// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

// example:
//AccessControl accessCtrl = AccessControl(addressStorage.getAddress("AccessControl"));
//require(accessCtrl.hasRole(accessCtrl.DEBT_SYSTEM(), _address), "Need debt system access role");

// contract access control
contract AccessControl is AccessControlUpgradeable {
    // -------------------------------------------------------
    // role type
    bytes32 public constant ROLE_ORACLE_SERVER = "ORACLE_SERVER";
    bytes32 public constant ISSUE_ASSET_ROLE = "ISSUE_ASSET"; //keccak256
    bytes32 public constant BURN_ASSET_ROLE = "BURN_ASSET";
    bytes32 public constant DEBT_SYSTEM = "DebtSystem";

    modifier onlyAdmin {
        require(IsAdmin(msg.sender), "Only admin");
        _;
    }
    // -------------------------------------------------------
    function initialize(address admin) public initializer {
        AccessControlUpgradeable.__AccessControl_init();
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function IsAdmin(address _address) public view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _address);
    }

    function SetAdmin(address _address) public {
        require(IsAdmin(msg.sender), "Only admin");
        _setupRole(DEFAULT_ADMIN_ROLE, _address);
    }

    // -------------------------------------------------------
    // this func need admin role. grantRole and revokeRole need admin role
    function SetRoles(
        bytes32 roleType,
        address[] calldata addresses,
        bool[] calldata setTo
    ) external onlyAdmin{
        _setRoles(roleType, addresses, setTo);
    }

    function _setRoles(
        bytes32 roleType,
        address[] calldata addresses,
        bool[] calldata setTo
    ) private onlyAdmin{
        require(addresses.length == setTo.length, "parameter address length not eq");

        for (uint256 i = 0; i < addresses.length; i++) {
            if (setTo[i]) {
                grantRole(roleType, addresses[i]);
            } else {
                revokeRole(roleType, addresses[i]);
            }
        }
    }

    function SetOracleServerRole(address[] calldata server, bool[] calldata setTo) public onlyAdmin{
        _setRoles(ROLE_ORACLE_SERVER, server, setTo);
    }

    // Issue burn
    function SetIssueAssetRole(address[] calldata issuer, bool[] calldata setTo) public onlyAdmin{
        _setRoles(ISSUE_ASSET_ROLE, issuer, setTo);
    }

    function SetBurnAssetRole(address[] calldata burner, bool[] calldata setTo) public onlyAdmin{
        _setRoles(BURN_ASSET_ROLE, burner, setTo);
    }

    //
    function SetDebtSystemRole(address[] calldata _address, bool[] calldata _setTo) public onlyAdmin{
        _setRoles(DEBT_SYSTEM, _address, _setTo);
    }

    // Reserved storage space to allow for layout changes in the future.
    uint256[50] private __gap;
}
