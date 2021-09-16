// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12 <0.8.0;
pragma experimental ABIEncoderV2;

//{ "symbol": "BTCUSD_210924", "ps": "BTCUSD", "price": "45027.3", "time": 1629365623724 },
//{ "symbol": "BTCUSD_211231", "ps": "BTCUSD", "price": "46217.0", "time": 1629365624282 },
interface IQuarterlyContractOracle {
    struct PriceData {
        uint256 price; // base/quote exchange rate, multiplied by 1e18.
        uint256 updateTime; // UNIX epoch of the last time when price gets updated.
        bool frozen;
    }

    function getQuarterlyContractPrice(bytes32 symbol) external view returns (PriceData memory);

    function setQuarterlyContractPrice(
        bytes32 symbol,
        uint256 price,
        uint256 time
    ) external;

    function isFrozen(bytes32 currencyKey) external view returns (bool);

    function setFrozen(bytes32 currencyKey, bool frozen) external;
}
