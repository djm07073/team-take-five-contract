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
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint128 liquidity = IUniswapV3Pool(pool).liquidity();

        require(sqrtPriceX96Upper > sqrtPriceX96, "U");
        require(sqrtPriceX96 > sqrtPriceX96Lower, "L");
        require(sqrtPriceX96Upper > sqrtPriceX96Lower, "UL");

        // P(1-fee)
        uint sqrtPriceX96XfeeRate = FullMath.mulDiv(
            sqrtPriceX96,
            1e6 - pool.fee(),
            1e6
        ); // sqrtPriceX96 * (1e6-fee) / 1e6
        uint depositRatioX192 = sqrtPriceX96 *
            FullMath.mulDiv(
                sqrtPriceX96 - sqrtPriceX96Lower,
                sqrtPriceX96Upper,
                sqrtPriceX96Upper - sqrtPriceX96
            );
    }
}
