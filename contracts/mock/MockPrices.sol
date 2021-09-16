// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "hardhat/console.sol";
import "../interfaces/IPrices.sol";
import "../libs/SafeDecimalMath.sol";

contract MockPrices is IPrices {
    using SafeDecimalMath for uint256;

    struct PriceData {
        uint256 price;
        uint256 updateTime;
        bool frozen;
    }

    uint256 stalePeriod;
    mapping(bytes32 => PriceData) prices;

    bytes32 public constant override FUSD = "FUSD";
    event PriceUpdated(bytes32 symbol, uint256 price, uint256 time);

    constructor(uint256 _stalePeriod) public {
        stalePeriod = _stalePeriod;
    }

    function exchange(
        bytes32 sourceKey,
        uint256 sourceAmount,
        bytes32 destKey
    ) external view override returns (uint256) {
        PriceData memory sourceData = _getPriceData(sourceKey);
        PriceData memory destData = _getPriceData(destKey);

        require(
            !_isUpdateTimeStaled(sourceData.updateTime) && !_isUpdateTimeStaled(destData.updateTime),
            "MockPrices: staled price data"
        );
        console.log('MockPrices: ', sourceData.price);
        console.log('MockPrices: ', destData.price);

        return sourceAmount.multiplyDecimalRound(sourceData.price).divideDecimalRound(destData.price);
    }

    function getPrice(bytes32 currencyKey) public view override returns (uint256) {
        console.log("----xxxxx getPrice: %s",  string(abi.encodePacked(currencyKey)));
        return _getPriceData(currencyKey).price;
    }

    function setPrice(bytes32 currencyKey, uint256 price) external {
        require(!isFrozen(currencyKey), "OracleRouter: price frozen");
        prices[currencyKey] = PriceData({price: price, updateTime: block.timestamp, frozen: false});
        emit PriceUpdated(currencyKey, price, block.timestamp);
    }

    function setPriceAndTime(
        bytes32 currencyKey,
        uint256 price,
        uint256 updateTime
    ) external {
        require(!isFrozen(currencyKey), "OracleRouter: price frozen");
        prices[currencyKey] = PriceData({price: price, updateTime: updateTime, frozen: false});
        emit PriceUpdated(currencyKey, price, block.timestamp);
    }

    function setStalePeriod(uint256 _stalePeriod) external {
        stalePeriod = _stalePeriod;
    }

    function _getPriceData(bytes32 currencyKey) private view returns (PriceData memory) {
        return
            currencyKey == FUSD
                ? PriceData({price: SafeDecimalMath.unit(), updateTime: block.timestamp, frozen: false})
                : prices[currencyKey];
    }

    function _isUpdateTimeStaled(uint256 updateTime) private view returns (bool) {
        return updateTime + stalePeriod < block.timestamp;
    }

    // set Frozen to forbid set price
    function setFrozen(bytes32 currencyKey, bool isFrozen) public override {
        PriceData memory data = prices[currencyKey];
        prices[currencyKey] = PriceData({price: data.price, updateTime: data.updateTime, frozen: isFrozen});
    }

    function isFrozen(bytes32 currencyKey) public view override returns (bool) {
        return prices[currencyKey].frozen;
    }
}
