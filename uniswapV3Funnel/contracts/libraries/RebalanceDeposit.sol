pragma solidity >=0.6.0;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "./FullMath.sol";
import "./Cubic.sol";

library RebalanceDeposit {
    /**
     *
     * @param tokenX tokenX address
     * @param tokenY tokenY address, always tokenX  < tokenY
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
        require(tokenX < tokenY, "Should be tokenX < tokenY");
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
    }
}
