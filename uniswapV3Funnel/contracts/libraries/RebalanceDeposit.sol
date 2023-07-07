pragma solidity >=0.6.0;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v2-core/contracts/libraries/Math.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "./FullMathInt.sol";
import "hardhat/console.sol";

library RebalanceDeposit {
    struct SqrtPriceX96Range {
        uint112 amountX;
        uint112 amountY;
        uint24 fee;
        uint128 liquidity;
        uint160 upper;
        uint160 lower;
        uint160 price; // sqrtPriceX96
    }

    /**
     * @param pool pool address
     * @param tickUpper tickUpper
     * @param tickLower tickLower
     * @param amountX amount of token X
     * @param amountY amount of token Y
     * @return baseAmount amount of token X or Y to swap
     * @return isSwapX true if swap token X, false if swap token Y
     */
    function rebalanceDeposit(
        IUniswapV3Pool pool,
        int24 tickUpper,
        int24 tickLower,
        uint112 amountX,
        uint112 amountY
    ) internal view returns (uint256 baseAmount, bool isSwapX) {
        require(address(pool) != address(0), "pool does not exist");
        require(tickUpper > tickLower, "UL");

        SqrtPriceX96Range memory range;
        uint128 liquidity;
        int24 tickCurrent;
        uint160 sqrtPriceX96;

        {
            (sqrtPriceX96, tickCurrent, , , , , ) = IUniswapV3Pool(pool)
                .slot0();

            require(tickUpper > tickCurrent, "U");
            require(tickCurrent > tickLower, "L");
            uint160 sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(tickUpper);
            console.log(sqrtPriceX96Upper);
            uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(tickLower);
            console.log(sqrtPriceX96Lower);

            isSwapX =
                ((amountY * (sqrtPriceX96 - sqrtPriceX96)) << 192) <
                ((sqrtPriceX96 - sqrtPriceX96Lower) *
                    sqrtPriceX96Upper *
                    sqrtPriceX96);

            liquidity = IUniswapV3Pool(pool).liquidity();
            range = SqrtPriceX96Range(
                amountX,
                amountY,
                pool.fee(),
                liquidity,
                sqrtPriceX96Upper,
                sqrtPriceX96Lower,
                sqrtPriceX96
            );
        }
        uint sqrtPriceX96Next = isSwapX
            ? _calcSqrtPriceNextCase1(range)
            : _calcSqrtPriceNextCase2(range);

        baseAmount = isSwapX
            ? FullMath.mulDiv(
                FullMath.mulDiv(liquidity, 2 ** 96, sqrtPriceX96),
                sqrtPriceX96Next - sqrtPriceX96,
                sqrtPriceX96Next
            )
            : FullMath.mulDiv(
                liquidity,
                sqrtPriceX96 - sqrtPriceX96Next,
                2 ** 96
            );
    }

    function rebalanceIncrease(
        INonfungiblePositionManager positionManager,
        IUniswapV3Factory factory,
        uint tokenId,
        uint112 amountX,
        uint112 amountY
    )
        internal
        view
        returns (
            uint256 baseAmount,
            bool isSwapX,
            uint24 fee,
            address tokenA,
            address tokenB
        )
    {
        address pool;
        SqrtPriceX96Range memory range;
        {
            int24 tickLower;
            int24 tickUpper;
            (
                ,
                ,
                tokenA,
                tokenB,
                fee,
                tickLower,
                tickUpper,
                ,
                ,
                ,
                ,

            ) = positionManager.positions(tokenId);
            pool = factory.getPool(tokenA, tokenB, fee);
            require(pool != address(0), "pool does not exist");
            (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
            uint128 liquidity = IUniswapV3Pool(pool).liquidity();
            range = SqrtPriceX96Range(
                amountX,
                amountY,
                IUniswapV3Pool(pool).fee(),
                liquidity,
                TickMath.getSqrtRatioAtTick(tickUpper),
                TickMath.getSqrtRatioAtTick(tickLower),
                sqrtPriceX96
            );
            require(range.upper > range.lower, "UL");
            require(range.upper > sqrtPriceX96, "U");
            require(sqrtPriceX96 > range.lower, "L");
        }

        require(address(pool) != address(0), "pool does not exist");

        {
            uint depositRatioX192 = range.price *
                FullMath.mulDiv(
                    range.price - range.lower,
                    range.upper,
                    range.upper - range.price
                );

            isSwapX =
                depositRatioX192 >
                FullMath.mulDiv(range.amountY, 2 ** 192, range.amountX);
        }

        uint sqrtPriceX96Next = isSwapX
            ? _calcSqrtPriceNextCase1(range)
            : _calcSqrtPriceNextCase2(range);

        baseAmount = isSwapX
            ? FullMath.mulDiv(
                FullMath.mulDiv(range.liquidity, 2 ** 96, range.price),
                sqrtPriceX96Next - range.price,
                sqrtPriceX96Next
            )
            : FullMath.mulDiv(
                range.liquidity,
                range.price - sqrtPriceX96Next,
                2 ** 96
            );
    }

    function _calcSqrtPriceNextCase1(
        SqrtPriceX96Range memory range
    ) private pure returns (uint sqrtPriceX96Next) {
        uint mulDivYL = FullMath.mulDiv(
            range.amountY,
            2 ** 96,
            range.liquidity
        ); // Y * L / 2^(96)
        //f(Pn)
        int pn3 = 1;
        int pn2 = -SafeCast.toInt256(
            (range.upper +
                2 *
                range.price +
                mulDivYL +
                FullMath.mulDiv(range.upper, 1e6, 1e6 - range.fee) +
                FullMath.mulDiv(
                    range.upper,
                    range.amountX,
                    range.liquidity << 96
                ))
        );
        int pn1 = SafeCast.toInt256(
            (range.price +
                mulDivYL +
                FullMath.mulDiv(range.price, range.amountX, range.liquidity)) *
                (range.upper + range.price) +
                FullMath.mulDiv(range.upper, range.price, 1 << 96) *
                (1 << (96 - uint(range.amountX) / range.liquidity))
        );
        int pn0 = SafeCast.toInt256(
            range.price +
                (range.amountY * range.upper * range.price * (1 << 96)) /
                range.liquidity
        );

        // find root using Newton Method
        // x1 = x0 - f(x0)/f'(x0)
        // x1 = sqrtPriceX96NextSecond
        int sqrtPriceX96NextFirst = range.upper;
        int sqrtPriceX96NextSecond = sqrtPriceX96NextFirst -
            _cubicEquation(pn3, pn2, pn1, pn0, sqrtPriceX96NextFirst) /
            _cubicEquationDerivative(pn3, pn2, pn1, sqrtPriceX96NextFirst);

        while (sqrtPriceX96NextFirst != sqrtPriceX96NextSecond) {
            sqrtPriceX96NextFirst = sqrtPriceX96NextSecond;
            sqrtPriceX96NextSecond =
                sqrtPriceX96NextFirst -
                _cubicEquation(pn3, pn2, pn1, pn0, sqrtPriceX96NextFirst) /
                _cubicEquationDerivative(pn3, pn2, pn1, sqrtPriceX96NextFirst);
        }
        sqrtPriceX96Next = uint(sqrtPriceX96NextSecond);
    }

    function _calcSqrtPriceNextCase2(
        SqrtPriceX96Range memory range
    ) private pure returns (uint sqrtPriceX96Next) {
        uint intermediate = FullMath.mulDiv(
            FullMath.mulDiv(range.amountY, 1 << 96, 1e6),
            1e6 - range.fee,
            range.liquidity
        );
        int pn3 = SafeCast.toInt256(
            1 +
                FullMath.mulDiv(
                    FullMath.mulDiv(range.amountX, range.upper, 1e6),
                    1e6 - range.fee,
                    uint(range.liquidity) << 96
                ) -
                FullMath.mulDiv(range.price, 1e6 - range.fee, 1e6)
        );
        int pn2 = SafeCast.toInt256(
            intermediate -
                (range.price + range.upper) -
                (range.price + range.lower) *
                FullMath.mulDiv(
                    FullMath.mulDiv(range.amountX, range.upper, 1e6),
                    1e6 - range.fee,
                    uint(range.liquidity) << 96
                ) +
                FullMath.mulDiv(
                    FullMath.mulDiv(range.price, range.lower, 1e6),
                    1e6 - range.fee,
                    1
                )
        );
        int pn1 = -SafeCast.toInt256(
            (range.upper + range.price) *
                intermediate +
                (range.price ** 2 + 2 * range.price * range.upper) +
                FullMath.mulDiv(
                    FullMath.mulDiv(range.amountX, range.upper, 1e6),
                    range.price,
                    uint(range.liquidity) << 96
                ) *
                range.lower
        );
        int pn0 = SafeCast.toInt256(
            FullMath.mulDiv(
                intermediate,
                range.price * range.upper,
                range.liquidity
            ) -
                FullMath.mulDiv(
                    uint(range.price) ** 2,
                    range.upper,
                    range.liquidity
                )
        );
        int sqrtPriceX96NextFirst = range.upper;
        int sqrtPriceX96NextSecond = sqrtPriceX96NextFirst -
            _cubicEquation(pn3, pn2, pn1, pn0, sqrtPriceX96NextFirst) /
            _cubicEquationDerivative(pn3, pn2, pn1, sqrtPriceX96NextFirst);

        while (sqrtPriceX96NextFirst != sqrtPriceX96NextSecond) {
            sqrtPriceX96NextFirst = sqrtPriceX96NextSecond;
            sqrtPriceX96NextSecond =
                sqrtPriceX96NextFirst -
                _cubicEquation(pn3, pn2, pn1, pn0, sqrtPriceX96NextFirst) /
                _cubicEquationDerivative(pn3, pn2, pn1, sqrtPriceX96NextFirst);
        }
        sqrtPriceX96Next = uint(sqrtPriceX96NextSecond);
    }

    function _cubicEquation(
        int pn3,
        int pn2,
        int pn1,
        int pn0,
        int input
    ) private pure returns (int output) {
        output = pn3 * (input ** 3) + pn2 * (input ** 2) + pn1 * (input) + pn0;
    }

    function _cubicEquationDerivative(
        int pn3,
        int pn2,
        int pn1,
        int input
    ) private pure returns (int output) {
        output = 3 * pn3 * (input ** 2) + 2 * pn2 * (input) + pn1;
    }
}
