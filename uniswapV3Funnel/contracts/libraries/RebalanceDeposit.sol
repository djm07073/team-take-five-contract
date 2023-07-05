pragma solidity >=0.6.0;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "./FullMath.sol";
import "./Math.sol";
import "./TickMath.sol";
import "./FullMathInt.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "../interfaces/IUniswapV3Factory.sol";

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
            uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(tickLower);
            uint depositRatioX192 = sqrtPriceX96 *
                FullMath.mulDiv(
                    sqrtPriceX96 - sqrtPriceX96Lower,
                    sqrtPriceX96Upper,
                    sqrtPriceX96Upper - sqrtPriceX96
                );

            isSwapX =
                depositRatioX192 > FullMath.mulDiv(amountY, 2 ** 192, amountX);

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
        (int pn0, int pn1, int pn2) = isSwapX
            ? _calcSwapAmountX(range)
            : _calcSwapAmountY(range);

        uint sqrtPriceX96Next;
        {
            uint temp = uint(pn1 ** 2 - pn2 * pn0);
            require(temp >= 0, "SqrtEquation: negative discriminant");
            sqrtPriceX96Next = SafeCast.toUint256(
                (int(Math.sqrt(temp)) - pn1) / pn2
            );
        }
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
            uint160 sqrtPriceX96Upper,
            uint160 sqrtPriceX96Lower,
            uint24 fee,
            address tokenA,
            address tokenB
        )
    {
        address pool;
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
            sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(tickUpper);
            sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(tickLower);
            pool = factory.getPool(tokenA, tokenB, fee);
            require(pool != address(0), "pool does not exist");
        }

        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        uint128 liquidity = IUniswapV3Pool(pool).liquidity();

        require(address(pool) != address(0), "pool does not exist");
        require(sqrtPriceX96Upper > sqrtPriceX96, "U");
        require(sqrtPriceX96 > sqrtPriceX96Lower, "L");
        require(sqrtPriceX96Upper > sqrtPriceX96Lower, "UL");

        {
            uint depositRatioX192 = sqrtPriceX96 *
                FullMath.mulDiv(
                    sqrtPriceX96 - sqrtPriceX96Lower,
                    sqrtPriceX96Upper,
                    sqrtPriceX96Upper - sqrtPriceX96
                );

            isSwapX =
                depositRatioX192 > FullMath.mulDiv(amountY, 2 ** 192, amountX);
        }

        SqrtPriceX96Range memory range = SqrtPriceX96Range(
            amountX,
            amountY,
            IUniswapV3Pool(pool).fee(),
            liquidity,
            sqrtPriceX96Upper,
            sqrtPriceX96Lower,
            sqrtPriceX96
        );
        (int pn0, int pn1, int pn2) = isSwapX
            ? _calcSwapAmountX(range)
            : _calcSwapAmountY(range);

        uint sqrtPriceX96Next;
        {
            uint temp = uint(pn1 ** 2 - pn2 * pn0);
            require(temp >= 0, "SqrtEquation: negative discriminant");
            sqrtPriceX96Next = SafeCast.toUint256(
                (int(Math.sqrt(temp)) - pn1) / pn2
            );
        }
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

    function _calcSwapAmountX(
        SqrtPriceX96Range memory range
    ) private pure returns (int pn0, int pn1, int pn2) {
        pn2 =
            SafeCast.toInt256(range.upper) *
            FullMathInt.mulDiv(
                FullMath.mulDiv(range.price, 1e6 - range.fee, 1e6),
                range.amountX,
                uint256(range.liquidity) * range.price * 2 ** 96
            ) -
            SafeCast.toInt256(range.upper / range.price);
        pn1 =
            range.upper -
            FullMathInt.mulDiv(range.upper, range.lower, range.price) *
            (1 +
                FullMathInt.mulDiv(
                    FullMath.mulDiv(range.price, 1e6 - range.fee, 1e6),
                    range.amountX,
                    uint256(range.liquidity) << 96
                )) +
            FullMathInt.mulDiv(
                (uint256(range.amountY) << 96) -
                    (range.liquidity * (range.price + range.upper)),
                FullMath.mulDiv(range.price, 1e6 - range.fee, 1e6),
                range.liquidity * range.price
            );

        pn1 /= 2;
        pn0 = SafeCast.toInt256(
            FullMath.mulDiv(range.price, 1e6 - range.fee, 1e6) *
                range.upper -
                range.upper *
                range.lower
        );
    }

    function _calcSwapAmountY(
        SqrtPriceX96Range memory range
    ) private pure returns (int pn0, int pn1, int pn2) {
        pn2 =
            SafeCast.toInt256(
                FullMath.mulDiv(range.upper, range.amountX, 2 ** 192)
            ) -
            SafeCast.toInt256(
                FullMath.mulDiv(
                    range.upper,
                    range.liquidity,
                    uint(range.price) << 96
                )
            ) +
            SafeCast.toInt256(range.liquidity);
        pn1 =
            range.upper *
            (SafeCast.toInt256(
                FullMath.mulDiv(range.liquidity, range.upper, 2 ** 96)
            ) -
                SafeCast.toInt256(
                    FullMath.mulDiv(range.amountX, range.lower, 2 ** 192)
                ) +
                SafeCast.toInt256(
                    FullMath.mulDiv(range.liquidity, range.lower, 2 ** 96)
                )) +
            SafeCast.toInt256(
                FullMath.mulDiv(
                    (FullMath.mulDiv(range.price, 1e6 - range.fee, 1e6) << 96),
                    range.amountY,
                    range.price
                )
            ) -
            SafeCast.toInt256(range.liquidity * (range.price + range.upper));
        pn1 /= 2;

        pn0 =
            -SafeCast.toInt256(
                range.upper *
                    FullMath.mulDiv(range.liquidity, range.lower, 2 ** 96)
            ) -
            range.upper *
            (SafeCast.toInt256(
                FullMath.mulDiv(
                    (FullMath.mulDiv(range.price, 1e6 - range.fee, 1e6) << 96),
                    range.amountY,
                    range.price
                )
            ) - SafeCast.toInt256(range.liquidity * range.price));
    }
}
