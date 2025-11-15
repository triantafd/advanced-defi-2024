// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "../../../src/interfaces/IERC20.sol";
import {IWETH} from "../../../src/interfaces/IWETH.sol";
import {IUniswapV2Router02} from "../../../src/interfaces/uniswap-v2/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../../../src/interfaces/uniswap-v2/IUniswapV2Pair.sol";
import {UniswapV2Arb1} from "./UniswapV2Arb1.sol";
import {
    DAI,
    WETH,
    UNISWAP_V2_ROUTER_02,
    UNISWAP_V2_PAIR_DAI_WETH,
    SUSHISWAP_V2_PAIR_DAI_WETH,
    SUSHISWAP_V2_ROUTER_02
} from "../../../src/Constants.sol";

// Closed-form optimal arbitrage input using the quadratic shown in the diagram.
// Notation mapping to the diagram (choosing direction A->B as DAI->WETH on A, WETH->DAI on B):
//   f  = swap fee (e.g., 0.003) and g = 1 - f = 0.997
//   xA = AMM A reserve out (WETH)
//   yA = AMM A reserve in  (DAI)
//   xB = AMM B reserve in  (WETH)
//   yB = AMM B reserve out (DAI)
//   k  = g * xB + g^2 * xA
//   a  = k^2
//   b  = 2 * k * yA * xB
//   c  = (yA * xB)^2 - g^2 * xA * yA * xB * yB
// Optimal input (in yA units, i.e., DAI): dyA* = (-b + sqrt(b^2 - 4ac)) / (2a)
// This file uses integer scaling to avoid overflows and then rescales the result.
contract UniswapV2ArbOptimalAmountClosedFormTest is Test {
    IUniswapV2Router02 private constant uni = IUniswapV2Router02(UNISWAP_V2_ROUTER_02);
    IERC20 private constant dai = IERC20(DAI);
    IWETH private constant weth = IWETH(WETH);
    UniswapV2Arb1 private arb;
    // g = 1 - f for 0.3% fee => 997/1000
    uint256 private constant G_NUM = 997;
    uint256 private constant G_DEN = 1000;

    function setUp() public {
        // Toggle arbitrage setup: comment out the next line if you don't want to skew prices
        _createSkewOnUniswap(10 ether);

        // Deploy helper arbitrage contract and give it approval to pull DAI
        arb = new UniswapV2Arb1();
        dai.approve(address(arb), type(uint256).max);
    }

    // Helper to skew Uniswap price by selling WETH -> DAI
    function _createSkewOnUniswap(uint256 wethToSell) internal {
        if (wethToSell == 0) return;
        deal(address(this), wethToSell);
        weth.deposit{value: wethToSell}();
        weth.approve(address(uni), type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = DAI;
        uni.swapExactTokensForTokens({
            amountIn: wethToSell,
            amountOutMin: 1,
            path: path,
            to: address(this),
            deadline: block.timestamp
        });
    }

    function test_closedForm_optimalAmount_DAI_WETH_between_Uni_and_Sushi() public {
        (bool ok, bool buyOnUni, uint256 dyA, uint256 profit) = _computeOptimalDyAAndProfit();
        if (!ok) {
            console2.log("no arb (unable to compute positive dyA)");
            return;
        }
        console2.log("buyOnUni (true=Uni->Sushi, false=Sushi->Uni):", buyOnUni);
        console2.log("optimal dyA (DAI in, wei):", dyA, 'with no 18 decimals:', dyA / 1e18);
        console2.log("expected profit (DAI, wei):", profit, 'with no 18 decimals:', profit / 1e18);
    }

    // Compare expected vs realized profit for a chosen DAI input by actually executing the swaps
    // Execute the fixed-input (10 DAI) arbitrage and compare expected vs realized
    function test_executeFixedInputArb_andCompare() public {
        uint256 amountIn = 14963 * 1e18; // 10 DAI

        // Use helper to determine direction and current optimal context
        (bool okCtx, bool buyOnUni,,) = _computeOptimalDyAAndProfit();
        require(okCtx, "no arb context");

        // Re-read reserves to compute expected profit for the chosen amount (no state change)
        (uint256 daiU, uint256 wethU) = _reservesDAI_WETH(UNISWAP_V2_PAIR_DAI_WETH);
        (uint256 daiS, uint256 wethS) = _reservesDAI_WETH(SUSHISWAP_V2_PAIR_DAI_WETH);
        uint256 xA = buyOnUni ? wethU : wethS; // out (WETH)
        uint256 yA = buyOnUni ? daiU : daiS;   // in  (DAI)
        uint256 xB = buyOnUni ? wethS : wethU; // in  (WETH)
        uint256 yB = buyOnUni ? daiS : daiU;   // out (DAI)
        uint256 expProfit;
        {
            uint256 wethOut = _getAmountOut(amountIn, yA, xA);
            uint256 daiBack = _getAmountOut(wethOut, xB, yB);
            expProfit = daiBack > amountIn ? daiBack - amountIn : 0;
        }

        // Ensure DAI balance and approvals
        if (dai.balanceOf(address(this)) < amountIn) {
            deal(DAI, address(this), amountIn);
        }
        dai.approve(address(uni), type(uint256).max);
        dai.approve(address(this), type(uint256).max);
        weth.approve(address(uni), type(uint256).max);
        weth.approve(address(this), type(uint256).max);

        uint256 startDai = dai.balanceOf(address(this));

        // Execute via the simple arbitrage helper
        arb.swap(
            UniswapV2Arb1.SwapParams({
                router0: buyOnUni ? UNISWAP_V2_ROUTER_02 : SUSHISWAP_V2_ROUTER_02,
                router1: buyOnUni ? SUSHISWAP_V2_ROUTER_02 : UNISWAP_V2_ROUTER_02,
                tokenIn: DAI,
                tokenOut: WETH,
                amountIn: amountIn,
                minProfit: 1
            })
        );

        uint256 endDai = dai.balanceOf(address(this));
        uint256 realized = endDai > startDai ? endDai - startDai : 0;
        console2.log("expected profit (DAI, wei):", expProfit, 'with no 18 decimals:', expProfit / 1e18);
        console2.log("realized profit (DAI, wei):", realized, 'with no 18 decimals:', realized / 1e18);

        // Allow some rounding wiggle room
        assertGe(realized + 10, expProfit, "realized < expected - tolerance");
    }

    // Execute the optimal-input arbitrage as instructed by _computeOptimalDyAAndProfit()
    // and compare expected vs realized profit
    function test_executeOptimalArb_andCompare() public {
        (bool ok, bool buyOnUni, uint256 dyA, uint256 expProfit) = _computeOptimalDyAAndProfit();
        require(ok && dyA > 0, "no arb or zero optimal amount");

        // Ensure balances/approvals
        if (dai.balanceOf(address(this)) < dyA) {
            deal(DAI, address(this), dyA);
        }
        dai.approve(address(uni), type(uint256).max);
        weth.approve(address(uni), type(uint256).max);

        uint256 startDai = dai.balanceOf(address(this));

        // Execute via the simple arbitrage helper
        arb.swap(
            UniswapV2Arb1.SwapParams({
                router0: buyOnUni ? UNISWAP_V2_ROUTER_02 : SUSHISWAP_V2_ROUTER_02,
                router1: buyOnUni ? SUSHISWAP_V2_ROUTER_02 : UNISWAP_V2_ROUTER_02,
                tokenIn: DAI,
                tokenOut: WETH,
                amountIn: dyA,
                minProfit: 1
            })
        );

        uint256 endDai = dai.balanceOf(address(this));
        uint256 realized = endDai > startDai ? endDai - startDai : 0;

        console2.log("buyOnUni (true=Uni->Sushi, false=Sushi->Uni):", buyOnUni);
        console2.log("optimal dyA (DAI in, wei):", dyA, 'with no 18 decimals:', dyA / 1e18);
        console2.log("expected optimal profit (DAI, wei):", expProfit, 'with no 18 decimals:', expProfit / 1e18);
        console2.log("realized optimal profit (DAI, wei):", realized, 'with no 18 decimals:', realized / 1e18);

        assertGe(realized + 10, expProfit, "realized < expected - tolerance");
    }

    // ---------- Helpers ----------

    // Full pipeline: fetch reserves, decide direction, compute dyA and expected profit.
    function _computeOptimalDyAAndProfit()
        private
        view
        returns (bool ok, bool buyOnUni, uint256 dyA, uint256 profit)
    {
        (uint256 daiU, uint256 wethU) = _reservesDAI_WETH(UNISWAP_V2_PAIR_DAI_WETH);
        (uint256 daiS, uint256 wethS) = _reservesDAI_WETH(SUSHISWAP_V2_PAIR_DAI_WETH);

        buyOnUni = (daiU * 1e18 / wethU) < (daiS * 1e18 / wethS);
        (ok, dyA) = _optimalDyAFromReserves(daiU, wethU, daiS, wethS, buyOnUni);
        if (!ok) {
            return (false, buyOnUni, 0, 0);
        }

        uint256 xA = buyOnUni ? wethU : wethS; // out (WETH)
        uint256 yA = buyOnUni ? daiU : daiS;   // in  (DAI)
        uint256 xB = buyOnUni ? wethS : wethU; // in  (WETH)
        uint256 yB = buyOnUni ? daiS : daiU;   // out (DAI)
        uint256 wethOut = _getAmountOut(dyA, yA, xA);
        uint256 daiBack = _getAmountOut(wethOut, xB, yB);
        profit = daiBack > dyA ? daiBack - dyA : 0;
    }

    // Computes dyA* using the simplified closed-form; returns (ok, dyA)
    function _optimalDyAFromReserves(
        uint256 daiU,
        uint256 wethU,
        uint256 daiS,
        uint256 wethS,
        bool buyOnUni
    ) private pure returns (bool, uint256) {
        // Map reserves to (xA, yA, xB, yB)
        uint256 xA = buyOnUni ? wethU : wethS; // out (WETH)
        uint256 yA = buyOnUni ? daiU : daiS;   // in  (DAI)
        uint256 xB = buyOnUni ? wethS : wethU; // in  (WETH)
        uint256 yB = buyOnUni ? daiS : daiU;   // out (DAI)

        uint256 scale = _chooseScale(xA, yA, xB, yB);
        uint256 xA_ = xA / scale;
        uint256 yA_ = yA / scale;
        uint256 xB_ = xB / scale;
        uint256 yB_ = yB / scale;
        if (xA_ == 0 || yA_ == 0 || xB_ == 0 || yB_ == 0) {
            return (false, 0);
        }

        uint256 yAxB = yA_ * xB_;
        uint256 prod = xA_ * yA_;
        prod = prod * xB_;
        prod = prod * yB_;
        uint256 sqrtP = _sqrt(prod);

        uint256 numeratorNeg = yAxB * (G_DEN * G_DEN);
        uint256 numeratorPos = G_NUM * G_DEN * sqrtP;
        if (numeratorPos <= numeratorNeg) {
            return (false, 0);
        }
        uint256 numerator = numeratorPos - numeratorNeg;
        uint256 denom = G_NUM * xB_ * G_DEN + G_NUM * G_NUM * xA_;
        if (denom == 0) {
            return (false, 0);
        }
        uint256 dyA_scaled = numerator / denom;
        return (true, dyA_scaled * scale);
    }

    function _reservesDAI_WETH(address pair)
        private
        view
        returns (uint256 xDAI, uint256 yWETH)
    {
        address t0 = IUniswapV2Pair(pair).token0();
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        if (t0 == DAI) {
            xDAI = uint256(r0);
            yWETH = uint256(r1);
        } else {
            xDAI = uint256(r1);
            yWETH = uint256(r0);
        }
    }

    // Choose an integer scale to keep numbers within uint256 in subsequent squares/products.
    function _chooseScale(
        uint256 xA,
        uint256 yA,
        uint256 xB,
        uint256 yB
    ) private pure returns (uint256 s) {
        uint256 m = xA;
        if (yA > m) m = yA;
        if (xB > m) m = xB;
        if (yB > m) m = yB;
        // Target around 1e6 after scaling
        if (m <= 1e6) return 1;
        s = m / 1e6;
        if (s == 0) s = 1;
    }

    function _getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) private pure returns (uint256 amountOut) {
        uint256 amountInWithFee = amountIn * G_NUM;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * G_DEN + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // Reduce A,B,C by a common scale to avoid overflow in discriminant.
    function _normalizeABC(
        uint256 A_,
        uint256 B_,
        uint256 C_
    ) private pure returns (uint256, uint256, uint256) {
        uint256 m = A_;
        if (B_ > m) m = B_;
        if (C_ > m) m = C_;
        // Target max around 1e18
        if (m <= 1e18) return (A_, B_, C_);
        uint256 d = m / 1e18 + 1;
        return (A_ / d, B_ / d, C_ / d);
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}


