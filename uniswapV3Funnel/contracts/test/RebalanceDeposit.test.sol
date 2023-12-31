// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;
import "../libraries/RebalanceDeposit.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

contract RebalanceDepositTest {
    function rebalanceDepositTest(
        IUniswapV3Pool pool,
        int24 tickUpper,
        int24 tickLower,
        uint112 amountY,
        uint112 amountX
    ) public view returns (uint baseAmount, bool isSwapX) {
        (baseAmount, isSwapX) = RebalanceDeposit.rebalanceDeposit(
            pool,
            tickUpper,
            tickLower,
            amountX,
            amountY
        );
    }

    function rebalanceIncreaseTest(
        INonfungiblePositionManager positionManager,
        IUniswapV3Factory factory,
        uint tokenId,
        uint112 amountX,
        uint112 amountY
    )
        public
        view
        returns (
            uint256 baseAmount,
            bool isSwapX,
            uint24 fee,
            address tokenA,
            address tokenB
        )
    {
        return
            RebalanceDeposit.rebalanceIncrease(
                positionManager,
                factory,
                tokenId,
                amountX,
                amountY
            );
    }
}
