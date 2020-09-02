// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.10;
import "../pool/YieldMath.sol"; // 64 bits
import "../pool/Math64x64.sol";
import "@nomiclabs/buidler/console.sol";


contract YieldMathEchidna {
    uint128 constant internal precision = 1e12;
    int128 constant internal k = int128(uint256((1 << 64)) / 126144000); // 1 / Seconds in 4 years, in 64.64
    int128 constant internal g = int128(uint256((95 << 64)) / 100); // All constants are `ufixed`, to divide them they must be converted to uint256

    uint128 minDaiReserves = 10**21; // $1000
    uint128 minYDaiReserves = minDaiReserves + 1;
    uint128 minTrade = minDaiReserves / 1000; // $1
    uint128 minTimeTillMaturity = 0;
    uint128 maxDaiReserves = 10**27; // $1B
    uint128 maxYDaiReserves = maxDaiReserves + 1; // $1B
    uint128 maxTrade = maxDaiReserves / 10;
    uint128 maxTimeTillMaturity = 126144000;

    constructor() public {}
    
    /// @dev Bali Overflow-protected addition, from OpenZeppelin
    function add(uint128 a, uint128 b)
        internal pure returns (uint128)
    {
        uint128 c = a + b;
        require(c >= a, "Pool: Dai reserves too high");
        return c;
    }
    /// @dev Bali Overflow-protected substraction, from OpenZeppelin
    function sub(uint128 a, uint128 b) internal pure returns (uint128) {
        require(b <= a, "Pool: yDai reserves too low");
        uint128 c = a - b;
        return c;
    }

    /// @dev Ensures that if we sell yDAI for DAI and back we get less yDAI than we had
    function testSellYDaiAndReverse(uint128 daiReserves, uint128 yDAIReserves, uint128 yDaiIn, uint128 timeTillMaturity)
        public view returns (bool)
    {
        require(daiReserves > yDAIReserves);
        daiReserves = minDaiReserves + daiReserves % maxDaiReserves;
        yDAIReserves = minYDaiReserves + yDAIReserves % maxYDaiReserves;
        timeTillMaturity = minTimeTillMaturity + timeTillMaturity % maxTimeTillMaturity;

        uint128 yDaiOut = _sellYDaiAndReverse(daiReserves, yDAIReserves, yDaiIn, timeTillMaturity);
        assert(yDaiOut <= yDaiIn);
    }

    /// @dev Ensures that if we buy yDAI for DAI and back we get less DAI than we had
    function testBuyYDaiAndReverse(uint128 daiReserves, uint128 yDAIReserves, uint128 yDaiOut, uint128 timeTillMaturity)
        public view returns (bool)
    {
        require(daiReserves > yDAIReserves);
        daiReserves = minDaiReserves + daiReserves % maxDaiReserves;
        yDAIReserves = minYDaiReserves + yDAIReserves % maxYDaiReserves;
        timeTillMaturity = minTimeTillMaturity + timeTillMaturity % maxTimeTillMaturity;

        uint128 yDaiIn = _buyYDaiAndReverse(daiReserves, yDAIReserves, yDaiOut, timeTillMaturity);
        assert(yDaiOut <= yDaiIn);
    }

    /// @dev Ensures that if we sell DAI for yDAI and back we get less DAI than we had
    function testSellDaiAndReverse(uint128 daiReserves, uint128 yDAIReserves, uint128 daiIn, uint128 timeTillMaturity)
        public view returns (bool)
    {
        require(daiReserves > yDAIReserves);
        daiReserves = minDaiReserves + daiReserves % maxDaiReserves;
        yDAIReserves = minYDaiReserves + yDAIReserves % maxYDaiReserves;
        timeTillMaturity = minTimeTillMaturity + timeTillMaturity % maxTimeTillMaturity;

        console.log(daiIn);
        uint128 daiOut = _sellDaiAndReverse(daiReserves, yDAIReserves, daiIn, timeTillMaturity);
        assert(daiOut <= daiIn);
    }

    /// @dev Ensures that if we buy DAI for yDAI and back we get less yDAI than we had
    function testBuyDaiAndReverse(uint128 daiReserves, uint128 yDAIReserves, uint128 daiOut, uint128 timeTillMaturity)
        public view returns (bool)
    {
        require(daiReserves > yDAIReserves);
        daiReserves = minDaiReserves + daiReserves % maxDaiReserves;
        yDAIReserves = minYDaiReserves + yDAIReserves % maxYDaiReserves;
        timeTillMaturity = minTimeTillMaturity + timeTillMaturity % maxTimeTillMaturity;

        uint128 daiIn = _buyYDaiAndReverse(daiReserves, yDAIReserves, daiOut, timeTillMaturity);
        assert(daiOut <= daiIn);
    }

    /// @dev Ensures that reserves grow with any daiOutForYDaiIn trade.
    function testLiquidityDaiOutForYDaiIn(uint128 daiReserves, uint128 yDAIReserves, uint128 yDaiIn, uint128 timeTillMaturity)
        internal view returns (bool)
    {
        require (daiReserves <= yDAIReserves);
        daiReserves = minDaiReserves + daiReserves % maxDaiReserves;
        yDAIReserves = minYDaiReserves + yDAIReserves % maxYDaiReserves;
        timeTillMaturity = minTimeTillMaturity + timeTillMaturity % maxTimeTillMaturity;

        uint128 reserves_0 = _initialReservesValue(daiReserves, yDAIReserves, timeTillMaturity);
        uint128 daiOut= YieldMath.daiOutForYDaiIn(daiReserves, yDAIReserves, yDaiIn, timeTillMaturity, k, g);
        uint128 reserves_1 = _initialReservesValue(sub(daiReserves, daiOut), add(yDAIReserves, yDaiIn), sub(timeTillMaturity, 1));
        assert(reserves_0 < reserves_1);
        return reserves_0 < reserves_1;
    }

    /// @dev Ensures that reserves grow with any yDaiInForDaiOut trade.
    function testLiquidityDaiInForYDaiOut(uint128 daiReserves, uint128 yDAIReserves, uint128 yDaiOut, uint128 timeTillMaturity)
        internal view returns (bool)
    {
        require (daiReserves <= yDAIReserves - yDaiOut);
        daiReserves = minDaiReserves + daiReserves % maxDaiReserves;
        yDAIReserves = minYDaiReserves + yDAIReserves % maxYDaiReserves;
        timeTillMaturity = minTimeTillMaturity + timeTillMaturity % maxTimeTillMaturity;

        uint128 reserves_0 = _initialReservesValue(daiReserves, yDAIReserves, timeTillMaturity);
        uint128 daiIn= YieldMath.daiInForYDaiOut(daiReserves, yDAIReserves, yDaiOut, timeTillMaturity, k, g);
        uint128 reserves_1 = _initialReservesValue(add(daiReserves, daiIn), sub(yDAIReserves, yDaiOut), sub(timeTillMaturity, 1));
        assert(reserves_0 < reserves_1);
        return reserves_0 < reserves_1;
    }

    /// @dev Ensures that reserves grow with any yDaiOutForDaiIn trade.
    function testLiquidityYDaiOutForDaiIn(uint128 daiReserves, uint128 yDAIReserves, uint128 daiIn, uint128 timeTillMaturity)
        internal view returns (bool)
    {
        require (daiReserves + daiIn <= yDAIReserves);
        daiReserves = minDaiReserves + daiReserves % maxDaiReserves;
        yDAIReserves = minYDaiReserves + yDAIReserves % maxYDaiReserves;
        timeTillMaturity = minTimeTillMaturity + timeTillMaturity % maxTimeTillMaturity;

        uint128 reserves_0 = _initialReservesValue(daiReserves, yDAIReserves, timeTillMaturity);
        uint128 yDaiOut= YieldMath.yDaiOutForDaiIn(daiReserves, yDAIReserves, daiIn, timeTillMaturity, k, g);
        uint128 reserves_1 = _initialReservesValue(add(daiReserves, daiIn), sub(yDAIReserves, yDaiOut), sub(timeTillMaturity, 1));
        assert(reserves_0 < reserves_1);
        return reserves_0 < reserves_1;
    }

    /// @dev Ensures that reserves grow with any yDaiInForDaiOut trade.
    function testLiquidityYDaiInForDaiOut(uint128 daiReserves, uint128 yDAIReserves, uint128 daiOut, uint128 timeTillMaturity)
        internal view returns (bool)
    {
        require (daiReserves <= yDAIReserves);
        daiReserves = minDaiReserves + daiReserves % maxDaiReserves;
        yDAIReserves = minYDaiReserves + yDAIReserves % maxYDaiReserves;
        timeTillMaturity = minTimeTillMaturity + timeTillMaturity % maxTimeTillMaturity;

        uint128 reserves_0 = _initialReservesValue(daiReserves, yDAIReserves, timeTillMaturity);
        uint128 yDaiIn= YieldMath.yDaiInForDaiOut(daiReserves, yDAIReserves, daiOut, timeTillMaturity, k, g);
        uint128 reserves_1 = _initialReservesValue(sub(daiReserves, daiOut), add(yDAIReserves, yDaiIn), sub(timeTillMaturity, 1));
        assert(reserves_0 < reserves_1);
        return reserves_0 < reserves_1;
    }

    /// @dev Ensures log_2 grows as x grows
    function testLog2MonotonicallyGrows(uint128 x) internal pure {
        uint128 z1= YieldMath.log_2(x);
        uint128 z2= YieldMath.log_2(x + 1);
        assert(z2 >= z1);
    }

    /**
     * Estimate in DAI the value of reserves at protocol initialization time.
     *
     * @param daiReserves DAI reserves amount
     * @param yDAIReserves yDAI reserves amount
     * @param timeTillMaturity time till maturity in seconds
     * @return estimated value of reserves
     */
    function _initialReservesValue (
        uint128 daiReserves, uint128 yDAIReserves, uint128 timeTillMaturity)
        internal pure returns (uint128)
    {
        // a = (1 - k * timeTillMaturity)
        int128 a = Math64x64.sub (0x10000000000000000, Math64x64.mul (k, Math64x64.fromUInt (timeTillMaturity)));
        require (a > 0);

        uint256 sum =
        uint256 (YieldMath.pow (daiReserves, uint128 (a), 0x10000000000000000)) +
        uint256 (YieldMath.pow (yDAIReserves, uint128 (a), 0x10000000000000000)) >> 1;
        require (sum < 0x100000000000000000000000000000000);

        uint256 result = uint256 (YieldMath.pow (uint128 (sum), 0x10000000000000000, uint128 (a))) << 1;
        require (result < 0x100000000000000000000000000000000);

        return uint128 (result);
    }

    /// @dev Sell yDai and sell the obtained Dai back for yDai
    function _sellYDaiAndReverse(uint128 daiReserves, uint128 yDAIReserves, uint128 yDaiIn, uint128 timeTillMaturity)
        internal pure returns (uint128)
    {
        uint128 daiAmount = YieldMath.daiOutForYDaiIn(daiReserves, yDAIReserves, yDaiIn, timeTillMaturity, k, g);
        return YieldMath.yDaiOutForDaiIn(sub(daiReserves, daiAmount), add(yDAIReserves, yDaiIn), daiAmount, timeTillMaturity, k, g);
    }

    /// @dev Buy yDai and sell it back
    function _buyYDaiAndReverse(uint128 daiReserves, uint128 yDAIReserves, uint128 yDaiOut, uint128 timeTillMaturity)
        internal pure returns (uint128)
    {
        uint128 daiAmount = YieldMath.daiInForYDaiOut(daiReserves, yDAIReserves, yDaiOut, timeTillMaturity, k, g);
        return YieldMath.yDaiInForDaiOut(add(daiReserves, daiAmount), sub(yDAIReserves, yDaiOut), daiAmount, timeTillMaturity, k, g);
    }

    /// @dev Sell yDai and sell the obtained Dai back for yDai
    function _sellDaiAndReverse(uint128 daiReserves, uint128 yDAIReserves, uint128 daiIn, uint128 timeTillMaturity)
        internal pure returns (uint128)
    {
        uint128 yDaiAmount = YieldMath.yDaiOutForDaiIn(daiReserves, yDAIReserves, daiIn, timeTillMaturity, k, g);
        return YieldMath.daiOutForYDaiIn(add(daiReserves, daiIn), sub(yDAIReserves, yDaiAmount), yDaiAmount, timeTillMaturity, k, g);
    }

    /// @dev Buy yDai and sell it back
    function _buyDaiAndReverse(uint128 daiReserves, uint128 yDAIReserves, uint128 daiOut, uint128 timeTillMaturity)
        internal pure returns (uint128)
    {
        uint128 yDaiAmount = YieldMath.yDaiInForDaiOut(daiReserves, yDAIReserves, daiOut, timeTillMaturity, k, g);
        return YieldMath.daiInForYDaiOut(sub(daiReserves, daiOut), add(yDAIReserves, yDaiAmount), yDaiAmount, timeTillMaturity, k, g);
    }
}