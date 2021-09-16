// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../interfaces/IConfig.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract Config is OwnableUpgradeable, IConfig {
    mapping(bytes32 => uint) internal mUintConfig;
    // Build Ratio 升级到每个可以抵押的币都支持不同的比例，所以单独抽出来，不然会和交易费在mUintConfig里面冲突
    mapping(bytes32 => uint) internal mBuildConfig;

    function initialize() public initializer {
        OwnableUpgradeable.__Ownable_init();
    }

    function getBuildRatio(bytes32 key) external override view returns (uint){
        uint buildRatio = mBuildConfig[key];
        require(buildRatio > 0, "buildRatio <= 0");
        return buildRatio;
    }

    function getUint(bytes32 key) external override view returns (uint) {
        return mUintConfig[key];
    }

    function setBuildRatio(bytes32 key, uint value) external onlyOwner {
        mBuildConfig[key] = value;
        emit SetBuildRatioConfig(key, value);
    }

    function setUint(bytes32 key, uint value) external onlyOwner {
        mUintConfig[key] = value;
        emit SetUintConfig(key, value);
    }

    function deleteUint(bytes32 key) external onlyOwner {
        delete mUintConfig[key];
        emit SetUintConfig(key, 0);
    }

    function batchSet(bytes32[] calldata names, uint[] calldata values) external onlyOwner {
        require(names.length == values.length, "Input lengths must match");

        for (uint i = 0; i < names.length; i++) {
            mUintConfig[names[i]] = values[i];
            emit SetUintConfig(names[i], values[i]);
        }
    }

    event SetUintConfig(bytes32 key, uint value);
    event SetBuildRatioConfig(bytes32 key, uint value);

    // Reserved storage space to allow for layout changes in the future.
    uint256[49] private __gap;
}
