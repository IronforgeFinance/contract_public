// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../interfaces/IAsset.sol";
import "../interfaces/IPrices.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../libs/SafeDecimalMath.sol";
import "../utilities/AddressStorage.sol";
import "../interfaces/IAssetSystem.sol";

contract AssetSystem is AddressStorage, IAssetSystem {
    using SafeMath for uint256;
    using SafeDecimalMath for uint256;

    IAsset[] public mAssetList; // 合约地址数组
    mapping(address => bytes32) public mAddress2Names; // 地址到名称的映射
    mapping(bytes32 => bool) public forbidAssets; // 禁止交易的合约地址

    event AssetAdded(bytes32 name, address asset);
    event AssetRemoved(bytes32 name, address asset);
    event AssetForbid(bytes32 name, address asset, bool fidbid);

    function initialize(address _admin) public override initializer {
        AddressStorage.initialize(_admin);
    }

    function isAsset(address asset) external view override returns (bool) {
        return mAddress2Names[asset] != bytes32(0);
    }

    function setForbidAsset(bytes32 name, bool forbid) public override onlyAdmin {
        require(addressMap[name] != address(0), "Asset do not exists");
        address asset = addressMap[name];
        require(mAddress2Names[asset] != bytes32(0), "Asset address do not exists");
        forbidAssets[name] = forbid;
        emit AssetForbid(name, asset, forbid);
    }

    function isForbidden(bytes32 name) external view override returns (bool) {
        return forbidAssets[name];
    }

    function addAsset(IAsset asset) external onlyAdmin {
        bytes32 name = asset.symbolBytes32();

        require(addressMap[name] == address(0), "Asset already exists");
        require(mAddress2Names[address(asset)] == bytes32(0), "Asset address already exists");

        mAssetList.push(asset);
        addressMap[name] = address(asset);
        mAddress2Names[address(asset)] = name;
        setForbidAsset(name, false);

        emit AssetAdded(name, address(asset));
    }

    function removeAsset(bytes32 name) external onlyAdmin {
        address assetToRemove = address(addressMap[name]);

        require(assetToRemove != address(0), "asset does not exist");

        // Remove from list
        for (uint256 i = 0; i < mAssetList.length; i++) {
            if (address(mAssetList[i]) == assetToRemove) {
                delete mAssetList[i];
                mAssetList[i] = mAssetList[mAssetList.length - 1];
                mAssetList.pop();
                break;
            }
        }

        // And remove it from the assets mapping
        delete mAddress2Names[assetToRemove];
        delete addressMap[name];
        delete forbidAssets[name];

        emit AssetRemoved(name, assetToRemove);
    }

    function assetNumber() external view returns (uint256) {
        return mAssetList.length;
    }

    // check exchange rate invalid condition ? invalid just fail.
    function totalAssetsInUsd() public view override returns (uint256 total) {
        require(addressMap["Prices"] != address(0), "Prices address cannot access");
        total = 0;
        IPrices priceGetter = IPrices(addressMap["Prices"]); //getAddress
        for (uint256 i = 0; i < mAssetList.length; i++) {
            uint256 exchangeRate = priceGetter.getPrice(mAssetList[i].symbolBytes32());
            total = total.add(mAssetList[i].totalSupply().multiplyDecimal(exchangeRate));
        }
    }

    function getAssetAddresses() external view returns (address[] memory) {
        address[] memory addr = new address[](mAssetList.length);
        for (uint256 i = 0; i < mAssetList.length; i++) {
            addr[i] = address(mAssetList[i]);
        }
        return addr;
    }

    // Reserved storage space to allow for layout changes in the future.
    uint256[48] private __gap;
}
