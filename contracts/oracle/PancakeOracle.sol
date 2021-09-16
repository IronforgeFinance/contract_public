// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "../pancake/IPancakeRouter02.sol";
import "../pancake/IPancakeFactory.sol";
import "../pancake/IPancakePair.sol";
import "../interfaces/IDexOracle.sol";
import "../utilities/AdminUpgradeable.sol";
import "@uniswap/lib/contracts/libraries/FixedPoint.sol";

// fixed window oracle that recomputes the average price for the entire period once every period
// note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
contract PancakeOracle is AdminUpgradeable, IDexOracle {
    using FixedPoint for *;

    uint256 public constant PERIOD = 60 seconds;

    IPancakeRouter02 public router;
    IPancakePair public pair;
    address public token0;
    address public token1;
    address public tokenU;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32 public blockTimestampLast;
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;

    // _tokenU is usdc
    function initialize(
        address _router,
        address _tokenA,
        address _tokenU
    ) public initializer {
        require(_router != address(0), "PancakeOracle: Pancake router not exist");
        router = IPancakeRouter02(_router);
        IPancakeFactory factory = IPancakeFactory(router.factory());
        pair = IPancakePair(factory.getPair(_tokenA, _tokenU));
        require(address(pair) != address(0), "PancakeOracle: Pair address not exist");
        token0 = pair.token0();
        token1 = pair.token1();
        tokenU = _tokenU;
        price0CumulativeLast = pair.price0CumulativeLast(); // fetch the current accumulated price value (1 / 0)
        price1CumulativeLast = pair.price1CumulativeLast(); // fetch the current accumulated price value (0 / 1)
        uint112 reserve0;
        uint112 reserve1;
        (reserve0, reserve1, blockTimestampLast) = pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0, "PancakeOracle: NO_RESERVES"); // ensure that there's liquidity in the pair
    }

    // helper function that returns the current block timestamp within the range of uint32, i.e. [0, 2**32 - 1]
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2**32);
    }

    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices()
        internal
        view
        returns (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 blockTimestamp
        )
    {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = pair.price0CumulativeLast();
        price1Cumulative = pair.price1CumulativeLast();

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        (uint112 reserve0, uint112 reserve1, uint32 timestamp) = pair.getReserves();
        if (timestamp != blockTimestamp) {
            // subtraction overflow is desired
            uint32 timeElapsed = blockTimestamp - timestamp;
            // addition overflow is desired
            // counterfactual
            price0Cumulative += uint256(FixedPoint.fraction(reserve1, reserve0)._x) * timeElapsed;
            // counterfactual
            price1Cumulative += uint256(FixedPoint.fraction(reserve0, reserve1)._x) * timeElapsed;
        }
    }

    function update() external override {
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = currentCumulativePrices();
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        // ensure that at least one full period has passed since the last update
        require(timeElapsed >= PERIOD, "PancakeOracle: PERIOD_NOT_ELAPSED");

        // overflow is desired, casting never truncates
        // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
        price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
        price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));

        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;
    }

    // note this will always return 0 before update has been called successfully for the first time.
    function consult(address token, uint256 amountIn) external view override returns (uint256 amountOut, uint256 updatedTime) {
        if (token == token0) {
            amountOut = price0Average.mul(amountIn).decode144();
        } else {
            require(token == token1, "PancakeOracle: INVALID_TOKEN");
            amountOut = price1Average.mul(amountIn).decode144();
        }
        updatedTime = blockTimestampLast;
    }

    // note this will always return 0 before update has been called successfully for the first time.
    function getPrice() external view override returns (uint256 price, uint256 updatedTime) {
        if (tokenU == token0) {
            price = price1Average.mul(1e18).decode144();
        } else {
            price = price0Average.mul(1e18).decode144();
        }
        updatedTime = blockTimestampLast;
    }
}
