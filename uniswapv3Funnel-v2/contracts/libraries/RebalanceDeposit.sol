pragma solidity >=0.6.0;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";

library RebalanceDeposit {
    /**
     *
     * @param tokenX tokenX address
     * @param tokenY tokenY address, always tokenA < tokenB
     * @param sqrtPriceX96Upper sqrtPriceX96Upper
     * @param sqrtPriceX96Lower sqrtPriceX96Lower
     * @param sqrtPriceX96 sqrtPriceX96 = current amount of token B/current amount of token A
     * @param amountX amount of token X
     * @param amountY amount of token Y
     * @return baseAmount amount of token A or B to swap
     * @return isSwapA true if swap token A, false if swap token B
     */
    function rebalanceDeposit(
        address tokenX,
        address tokenY,
        uint160 sqrtPriceX96Upper,
        uint160 sqrtPriceX96Lower,
        uint160 sqrtPriceX96,
        uint256 amountX,
        uint256 amountY
    ) internal view returns (uint baseAmount, bool isSwapA) {
        require(tokenX < tokenY, "Should be tokenA < tokenB");
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
        // Calculate deposit Ratio from sqrtPriceX96Upper ,sqrtPriceX96Lower,sqrtPriceX96
        // deltaY = deltaL * (Math.sqrt(Pu) - Math.sqrt(Pl))
        // deltaX = deltaL * (1 / Math.sqrt(Pl) - 1 / Math.sqrt(Pu));
        // depositRatio = deltaY / deltaX;
        uint numerator = (sqrtPriceX96 - sqrtPriceX96Lower) *
            sqrtPriceX96 *
            sqrtPriceX96Upper;
        uint denominator = sqrtPriceX96Upper - sqrtPriceX96;
        uint depositRatioX192 = numerator / denominator;

        uint amtX;
        uint amtY;
        if (
            (amountX * 10 ** (ERC20(tokenY).decimals())) << 192 <=
            amountY * depositRatioX192 * 10 ** (ERC20(tokenX).decimals())
        ) {
            amtX = amountX;
            amtY = (amountX << 192) / depositRatioX192;
        } else {
            amtX = (amountY * depositRatioX192) >> 192;
            amtY = amountY;
        }

        int remainingX = int(amountX - amtX);
        int remainingY = int(amountY - amtY);
        int swapA;

        if (remainingX > 0) {
            uint _remainingX = SafeCast.toUint256(remainingX);
            swapA = SafeCast.toInt256(
                ((_remainingX * sqrtPriceX96) << 192) /
                    ((sqrtPriceX96 << 192) + depositRatioX192)
            );
        } else {
            uint _remainingX = SafeCast.toUint256(-remainingX);
            swapA = -SafeCast.toInt256(
                ((uint(_remainingX) * sqrtPriceX96) << 192) /
                    ((sqrtPriceX96 << 192) + depositRatioX192)
            );
        }
        int swapB;
        if (remainingY > 0) {
            uint _remainingY = SafeCast.toUint256(remainingY);
            swapB = SafeCast.toInt256(
                (depositRatioX192 * _remainingY) /
                    ((sqrtPriceX96 << 192) + depositRatioX192)
            );
        } else {
            uint _remainingY = SafeCast.toUint256(-remainingY);
            swapB = -SafeCast.toInt256(
                (depositRatioX192 * _remainingY) /
                    ((sqrtPriceX96 << 192) + depositRatioX192)
            );
        }

        isSwapA = swapA > 0;
        baseAmount = isSwapA
            ? SafeCast.toUint256(swapA)
            : SafeCast.toUint256(swapB);
    }
}
