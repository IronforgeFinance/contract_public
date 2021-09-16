// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "../interfaces/IAccessControl.sol";
import "../utilities/AdminUpgradeable.sol";
import "../utilities/AddressCache.sol";
import "../libs/StringHelper.sol";
import "../interfaces/IAsset.sol";

/**
 * @title AssetUpgradeable
 *
 * @dev This is an upgradeable version of `Asset`.
 */
contract AssetUpgradeable is ERC20Upgradeable, AdminUpgradeable, AddressCache, IAsset {
    using StringHelper for string;

    IAccessControl accessCtrl;

    bytes32 private constant ROLE_ISSUE_ASSET = "ISSUE_ASSET";
    bytes32 private constant ROLE_BURN_ASSET = "BURN_ASSET";
    bytes32 private constant ROLE_MOVE_ASSET = "MOVE_ASSET";

    modifier onlyIssueAssetRole() {
        require(accessCtrl.hasRole(ROLE_ISSUE_ASSET, msg.sender), "AssetUpgradeable: not ISSUE_ASSET role");
        _;
    }

    modifier onlyBurnAssetRole() {
        require(accessCtrl.hasRole(ROLE_BURN_ASSET, msg.sender), "AssetUpgradeable: not BURN_ASSET role");
        _;
    }

    modifier onlyMoveAssetRole() {
        require(accessCtrl.hasRole(ROLE_MOVE_ASSET, msg.sender), "AssetUpgradeable: not MOVE_ASSET role");
        _;
    }

    function initialize(
        string memory _name,
        string memory _symbol,
        address _admin
    ) public virtual initializer {
        require(_symbol.stringLteBytes32(), "symbol > bytes32");
        ERC20Upgradeable.__ERC20_init(_name, _symbol);
        AdminUpgradeable.__AdminUpgradeable_init(_admin);
    }

    function symbol() public view override(ERC20Upgradeable, IAsset) returns (string memory) {
        return ERC20Upgradeable.symbol();
    }

    function symbolBytes32() public view override returns (bytes32 result) {
        return ERC20Upgradeable.symbol().string2Bytes32();
    }

    function updateAddressCache(IAddressStorage _addressStorage) public virtual override onlyAdmin {
        accessCtrl = IAccessControl(
            _addressStorage.getAddressWithRequire("AccessControl", "AccessControl address not valid")
        );

        emit CachedAddressUpdated("AccessControl", address(accessCtrl));
    }

    function mint(address account, uint256 amount) external override onlyIssueAssetRole {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external override onlyBurnAssetRole {
        _burn(account, amount);
    }

    function balanceOf(address account)
        public
        view
        virtual
        override(ERC20Upgradeable, IERC20Upgradeable)
        returns (uint256)
    {
        return ERC20Upgradeable.balanceOf(account);
    }

    // Reserved storage space to allow for layout changes in the future.
    uint256[48] private __gap;
}
