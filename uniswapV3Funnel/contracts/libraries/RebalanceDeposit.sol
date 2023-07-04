pragma solidity >=0.6.0;
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
    /**
     
     * @param pool pool address
     * @param sqrtPriceX96Upper sqrtPriceX96Upper
     * @param sqrtPriceX96Lower sqrtPriceX96Lower
     * @param amountX amount of token X
     * @param amountY amount of token Y
     * @return baseAmount amount of token X or Y to swap
     * @return isSwapX true if swap token X, false if swap token Y
     */
    function rebalanceDeposit(
        IUniswapV3Pool pool,
        uint160 sqrtPriceX96Upper,
        uint160 sqrtPriceX96Lower,
        uint256 amountX,
        uint256 amountY
    ) internal view returns (uint baseAmount, bool isSwapX) {
        require(address(pool) != address(0), "pool does not exist");
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        uint128 liquidity = IUniswapV3Pool(pool).liquidity();

        require(
            sqrtPriceX96Upper > sqrtPriceX96,
            "Should be sqrtPriceX96Upper > sqrtPriceX"
        );
        require(
            sqrtPriceX96 > sqrtPriceX96Lower,
            "Should be sqrtPriceX96 > sqrtPriceX96Lower"
        );
        require(
            sqrtPriceX96Upper > sqrtPriceX96Lower,
            "Should be sqrtPriceX96Upper > sqrtPriceX96Lower"
        );
        uint sqrtPriceX96XfeeRate = FullMath.mulDiv(
            sqrtPriceX96,
            1e6 - IUniswapV3Pool(pool).fee(),
            1e6
        ); // sqrtPriceX96 * (1e6-fee) / 1e6
        uint depositRatioX192 = sqrtPriceX96 *
            FullMath.mulDiv(
                sqrtPriceX96 - sqrtPriceX96Lower,
                sqrtPriceX96Upper,
                sqrtPriceX96Upper - sqrtPriceX96
            );

        int pn2;
        int pn1;
        int pn0;
        uint sqrtPriceX96Next;
        if (depositRatioX192 > FullMath.mulDiv(amountY, 2 ** 192, amountX)) {
            // swap X
            isSwapX = true;
            pn2 =
                SafeCast.toInt256(sqrtPriceX96Upper) *
                FullMathInt.mulDiv(
                    sqrtPriceX96XfeeRate,
                    amountX,
                    liquidity * sqrtPriceX96 * 2 ** 96
                ) -
                SafeCast.toInt256(sqrtPriceX96Upper / sqrtPriceX96);
            pn1 =
                sqrtPriceX96Upper -
                FullMathInt.mulDiv(
                    sqrtPriceX96Upper,
                    sqrtPriceX96Lower,
                    sqrtPriceX96
                ) *
                (1 +
                    FullMathInt.mulDiv(
                        sqrtPriceX96XfeeRate,
                        amountX,
                        liquidity << 96
                    )) +
                FullMathInt.mulDiv(
                    (amountY << 96) -
                        (liquidity * (sqrtPriceX96 + sqrtPriceX96Upper)),
                    sqrtPriceX96XfeeRate,
                    liquidity * sqrtPriceX96
                );
            pn0 = SafeCast.toInt256(
                sqrtPriceX96XfeeRate *
                    sqrtPriceX96Upper -
                    sqrtPriceX96Upper *
                    sqrtPriceX96Lower
            );
            uint temp = uint(pn1 ** 2 - 4 * pn2 * pn0);
            require(temp >= 0, "SqrtEquation: negative discriminant");
            sqrtPriceX96Next = SafeCast.toUint256(
                (int(Math.sqrt(temp)) - pn1) / (2 * pn2)
            );
        } else {
            // swap Y
            isSwapX = false;
            pn2 =
                SafeCast.toInt256(
                    FullMath.mulDiv(sqrtPriceX96Upper, amountX, 2 ** 192)
                ) -
                SafeCast.toInt256(
                    FullMath.mulDiv(
                        sqrtPriceX96Upper,
                        liquidity,
                        (sqrtPriceX96 << 96)
                    )
                ) +
                SafeCast.toInt256(liquidity);
            pn1 =
                sqrtPriceX96Upper *
                (SafeCast.toInt256(
                    FullMath.mulDiv(liquidity, sqrtPriceX96Upper, 2 ** 96)
                ) -
                    SafeCast.toInt256(
                        FullMath.mulDiv(amountX, sqrtPriceX96Lower, 2 ** 192)
                    ) +
                    SafeCast.toInt256(
                        FullMath.mulDiv(liquidity, sqrtPriceX96Lower, 2 ** 96)
                    )) +
                SafeCast.toInt256(
                    FullMath.mulDiv(
                        (sqrtPriceX96XfeeRate << 96),
                        amountY,
                        sqrtPriceX96
                    )
                ) -
                SafeCast.toInt256(
                    liquidity * (sqrtPriceX96 + sqrtPriceX96Upper)
                );
            pn0 =
                -SafeCast.toInt256(
                    sqrtPriceX96Upper *
                        FullMath.mulDiv(liquidity, sqrtPriceX96Lower, 2 ** 96)
                ) -
                sqrtPriceX96Upper *
                (SafeCast.toInt256(
                    FullMath.mulDiv(
                        (sqrtPriceX96XfeeRate << 96),
                        amountY,
                        sqrtPriceX96
                    )
                ) - SafeCast.toInt256(liquidity * sqrtPriceX96));
            uint temp = uint(pn1 ** 2 - 4 * pn2 * pn0);
            require(temp >= 0, "SqrtEquation: negative discriminant");
            sqrtPriceX96Next = SafeCast.toUint256(
                (int(Math.sqrt(temp)) - pn1) / (2 * pn2)
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
        uint amountX,
        uint amountY
    )
        internal
        view
        returns (
            uint baseAmount,
            bool isSwapX,
            uint160 sqrtPriceX96Upper,
            uint160 sqrtPriceX96Lower,
            uint24 fee,
            address tokenX,
            address tokenY
        )
    {
        address tokenA;
        address tokenB;
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
        require(tokenX < tokenY, "Should be tokenX < tokenY");

        address pool = factory.getPool(tokenX, tokenY, fee);
        require(pool != address(0), "pool does not exist");
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        uint128 liquidity = IUniswapV3Pool(pool).liquidity();
        uint sqrtPriceX96XfeeRate = FullMath.mulDiv(
            sqrtPriceX96,
            1e6 - fee,
            1e6
        ); // sqrtPriceX96 * (1e6-fee) / 1e6
        uint depositRatioX192 = sqrtPriceX96 *
            FullMath.mulDiv(
                sqrtPriceX96 - sqrtPriceX96Lower,
                sqrtPriceX96Upper,
                sqrtPriceX96Upper - sqrtPriceX96
            );
        uint currentAmountRatioX192 = FullMath.mulDiv(
            amountY,
            2 ** 192,
            amountX
        );
        int pn2;
        int pn1;
        int pn0;

        uint sqrtPriceX96Next;
        if (depositRatioX192 > currentAmountRatioX192) {
            // swap X
            isSwapX = true;
            pn2 =
                SafeCast.toInt256(
                    sqrtPriceX96Upper *
                        FullMath.mulDiv(
                            sqrtPriceX96XfeeRate,
                            amountX,
                            liquidity * sqrtPriceX96 * 2 ** 96
                        )
                ) -
                SafeCast.toInt256(sqrtPriceX96Upper / sqrtPriceX96);
            pn1 =
                SafeCast.toInt256(sqrtPriceX96Upper) -
                SafeCast.toInt256(
                    FullMath.mulDiv(
                        sqrtPriceX96Upper,
                        sqrtPriceX96Lower,
                        sqrtPriceX96
                    ) *
                        (1 +
                            FullMath.mulDiv(
                                sqrtPriceX96XfeeRate,
                                amountX,
                                liquidity << 96
                            ))
                ) +
                SafeCast.toInt256(
                    FullMath.mulDiv(
                        (amountY << 96) -
                            (liquidity * (sqrtPriceX96 + sqrtPriceX96Upper)),
                        sqrtPriceX96XfeeRate,
                        liquidity * sqrtPriceX96
                    )
                );
            pn0 = SafeCast.toInt256(
                sqrtPriceX96XfeeRate *
                    sqrtPriceX96Upper -
                    sqrtPriceX96Upper *
                    sqrtPriceX96Lower
            );
            uint temp = uint(pn1 ** 2 - 4 * pn2 * pn0);
            require(temp >= 0, "SqrtEquation: negative discriminant");
            sqrtPriceX96Next = SafeCast.toUint256(
                (int(Math.sqrt(temp)) - pn1) / (2 * pn2)
            );
        } else {
            // swap Y
            isSwapX = false;
            pn2 =
                SafeCast.toInt256(
                    FullMath.mulDiv(sqrtPriceX96Upper, amountX, 2 ** 192)
                ) -
                SafeCast.toInt256(
                    FullMath.mulDiv(
                        sqrtPriceX96Upper,
                        liquidity,
                        (sqrtPriceX96 << 96)
                    )
                ) +
                SafeCast.toInt256(liquidity);
            pn1 =
                sqrtPriceX96Upper *
                (SafeCast.toInt256(
                    FullMath.mulDiv(liquidity, sqrtPriceX96Upper, 2 ** 96)
                ) -
                    SafeCast.toInt256(
                        FullMath.mulDiv(amountX, sqrtPriceX96Lower, 2 ** 192)
                    ) +
                    SafeCast.toInt256(
                        FullMath.mulDiv(liquidity, sqrtPriceX96Lower, 2 ** 96)
                    )) +
                SafeCast.toInt256(
                    FullMath.mulDiv(
                        (sqrtPriceX96XfeeRate << 96),
                        amountY,
                        sqrtPriceX96
                    )
                ) -
                SafeCast.toInt256(
                    liquidity * (sqrtPriceX96 + sqrtPriceX96Upper)
                );
            pn0 =
                -SafeCast.toInt256(
                    sqrtPriceX96Upper *
                        FullMath.mulDiv(liquidity, sqrtPriceX96Lower, 2 ** 96)
                ) -
                sqrtPriceX96Upper *
                (SafeCast.toInt256(
                    FullMath.mulDiv(
                        (sqrtPriceX96XfeeRate << 96),
                        amountY,
                        sqrtPriceX96
                    )
                ) - SafeCast.toInt256(liquidity * sqrtPriceX96));
            uint temp = uint(pn1 ** 2 - 4 * pn2 * pn0);
            require(temp >= 0, "SqrtEquation: negative discriminant");
            sqrtPriceX96Next = SafeCast.toUint256(
                (int(Math.sqrt(temp)) - pn1) / (2 * pn2)
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
}
