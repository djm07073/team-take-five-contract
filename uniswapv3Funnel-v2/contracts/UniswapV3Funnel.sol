// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.7.0;
pragma abicoder v2;
import "./libraries/TickMath.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/RebalanceDeposit.sol";

contract UniswapV3Funnel {
    using TransferHelper for address;
    ISwapRouter public immutable swapRouter;
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable factory;

    constructor(
        ISwapRouter _swapRouter,
        INonfungiblePositionManager _positionManager,
        IUniswapV3Factory _factory
    ) {
        swapRouter = _swapRouter;
        positionManager = _positionManager;
        factory = _factory;
    }

    /*******************************************************************************
     * How to add Liquidity? if I have 100 USD of value in Token
     * if depositAmountRatio, A/B == 40/60 is the current ratio decided by upper tick and lower tick
     * Rebalance: A(63) + B(37) -> A(40) + B(60)
     * Partition: A(100) + B(0) -> A(40) + B(60)
     * Decompose: A(100) + B(0) -> A(40) + B(60)
     ******************************************************************************/

    //liquidity = sqrt(amountX * amountY)
    //sqrtPriceX = sqrt(amountY/amountX) * 2^96
    function rebalanceAndAddLiquidity(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96Upper,
        uint160 sqrtPriceX96Lower,
        uint256 amount0,
        uint256 amount1,
        address to
    )
        external
        returns (uint tokenId, uint liquidity, uint successA, uint successB)
    {
        // 1. sort token0 and token1
        require(token0 != token1, "token0 and token1 must be different");
        (address tokenA, address tokenB, uint amountA, uint amountB) = token0 <
            token1
            ? (token0, token1, amount0, amount1)
            : (token1, token0, amount1, amount0);
        // 2. rebalance and add liquidity
        (tokenId, liquidity, successA, successB) = _rebalanceAndAddLiquidity(
            tokenA,
            tokenB,
            fee,
            sqrtPriceX96Upper,
            sqrtPriceX96Lower,
            amountA,
            amountB,
            msg.sender,
            to
        );
        // 3. Transfer back to user if there is any left
        _transferRestToken(tokenA, tokenB, msg.sender);
    }

    // partition function is not needed, because we can use rebalance to do the same thing

    function decomposeAndAddLiquidity(
        address tokenC,
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96Upper,
        uint160 sqrtPriceX96Lower,
        uint256 amountC,
        address to,
        address[] memory path // tokenC -> token0 or token1 path
    )
        external
        returns (uint tokenId, uint liquidity, uint successA, uint successB)
    {
        require(token0 != token1, "token0 and token1 must be different");
        require(
            token0 == path[path.length - 1] || token1 == path[path.length - 1],
            "path error"
        );

        //1. Transfer tokenC to this contract
        tokenC.safeTransferFrom(msg.sender, address(this), amountC);
        //2. Swap amountC of tokenC to token0 or token1
        uint amountOut = swapRouter.exactInput(
            ISwapRouter.ExactInputParams(
                abi.encodePacked(path),
                address(this),
                type(uint256).max,
                amountC,
                0
            )
        );

        //3. Rebalance token0 and add liquidity and mint to "to"
        (tokenId, liquidity, successA, successB) = _rebalanceAndAddLiquidity(
            token0,
            token1,
            fee,
            sqrtPriceX96Upper,
            sqrtPriceX96Lower,
            (token0 == token0 ? amountOut : 0),
            (token1 == token0 ? amountOut : 0),
            msg.sender,
            to
        );
        //4. Transfer back to user if there is any left
        _transferRestToken(token0, address(0), to);
    }

    /*** add liquidity to existing pool ***/
    function rebalanceAndIncreaseLiquidity(
        uint tokenId,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) external returns (uint successLiquidity, uint successA, uint successB) {
        require(token0 != token1, "token0 and token1 must be different");

        {
            (
                successLiquidity,
                successA,
                successB
            ) = _rebalanceAndIncreaseLiquidity(
                tokenId,
                amount0,
                amount1,
                msg.sender
            );
        }
        // 5. Transfer back to user if there is any left
        _transferRestToken(token0, token1, msg.sender);
    }

    // function partitionAndIncreaseLiquidity is not needed, because we can use rebalance to do the same thing
    function decomposeAndIncreaseLiquidity(
        uint tokenId,
        address tokenC,
        uint256 amountC,
        address[] memory path // tokenC -> tokenA or tokenB path
    ) external returns (uint successLiquidity, uint successA, uint successB) {
        // 1. Transfer tokenC to this contract
        tokenC.safeTransferFrom(msg.sender, address(this), amountC);

        // 2. Swap amountC of tokenC to token0
        bytes memory _path = abi.encodePacked(path);
        uint amountOut = swapRouter.exactInput(
            ISwapRouter.ExactInputParams(
                _path,
                address(this),
                type(uint256).max,
                amountC,
                0
            )
        );

        (successLiquidity, successA, successB) = _rebalanceAndIncreaseLiquidity(
            tokenId,
            amountOut,
            0,
            msg.sender
        );
        // 3. Transfer back to user if there is any left
        _transferRestToken(
            address(path[path.length - 1]),
            address(0),
            msg.sender
        );
    }

    /*** collect fee ***/
    function collectFee(
        uint tokenId,
        address to,
        address[] memory path1,
        address[] memory path2
    ) external {
        //1. Confirm Path
        require(
            path1[path1.length - 1] == path2[path2.length - 1],
            "destination token is different"
        );
        (, , address token0, address token1, , , , , , , , ) = positionManager
            .positions(tokenId);
        require(path1[0] == token0 && path2[0] == token1, "src token is wrong");
        address dstToken = path1[path1.length - 1];
        require(dstToken == path2[path2.length - 1], "dst token is wrong");
        //2. Transfer NFT to this contract & Collect fee
        positionManager.safeTransferFrom(msg.sender, address(this), tokenId);
        (uint amount0, uint amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: to,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        //3. Swap token0 to dstToken, token1 to dstToken
        uint amount0Out = swapRouter.exactInput(
            ISwapRouter.ExactInputParams(
                abi.encodePacked(path1),
                address(this),
                type(uint256).max,
                amount0,
                0
            )
        );
        uint amount1Out = swapRouter.exactInput(
            ISwapRouter.ExactInputParams(
                abi.encodePacked(path2),
                address(this),
                type(uint256).max,
                amount1,
                0
            )
        );
        //4. Transfer dstToken to user & Transfer NFT to user
        address(path1[path1.length - 1]).safeTransfer(
            to,
            amount0Out + amount1Out
        );
        positionManager.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    /*** remove liquidity ***/
    function removeLiquidity(
        uint tokenId,
        uint128 liquidityToRemove,
        address to,
        address[] memory path1, //token0 -> dstToken
        address[] memory path2 // token1 -> dstToken
    ) external {
        //1. Confirm Path
        require(
            path1[path1.length - 1] == path2[path2.length - 1],
            "destination token is different"
        );
        (
            ,
            ,
            address token0,
            address token1,
            ,
            ,
            ,
            uint128 liquidity,
            ,
            ,
            ,

        ) = positionManager.positions(tokenId);
        require(
            path1[0] == token0 && path2[0] == token1,
            "src token is different"
        );
        //2. Transfer NFT to this contract
        positionManager.safeTransferFrom(msg.sender, address(this), tokenId);
        //3. Decrease liquidity
        (uint amount0, uint amount1) = positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToRemove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        uint restLiquidity = liquidity - liquidityToRemove;
        //4. swap to dstToken and transfer to user

        //4.1 swap token0 to dstToken
        uint amount0Out = swapRouter.exactInput(
            ISwapRouter.ExactInputParams(
                abi.encodePacked(path1),
                address(this),
                type(uint256).max,
                amount0,
                0
            )
        );
        //4.2 swap token1 to dstToken
        uint amount1Out = swapRouter.exactInput(
            ISwapRouter.ExactInputParams(
                abi.encodePacked(path2),
                address(this),
                type(uint256).max,
                amount1,
                0
            )
        );
        //4.3 transfer dstToken to "to"
        address dstToken = address(path1[path1.length - 1]);
        dstToken.safeTransfer(to, amount0Out + amount1Out);

        //5. if rest of liquidity is 0, burn NFT, otherwise return to user
        if (restLiquidity == 0) {
            positionManager.burn(tokenId);
        } else {
            positionManager.safeTransferFrom(address(this), to, tokenId);
        }
    }

    function _transferRestToken(
        address tokenA,
        address tokenB,
        address to
    ) internal {
        if (tokenA != address(0)) {
            uint amountA = IERC20(tokenA).balanceOf(address(this));
            if (amountA > 0) {
                tokenA.safeTransfer(to, amountA);
            }
        }

        if (tokenB != address(0)) {
            uint amountB = IERC20(tokenB).balanceOf(address(this));
            if (amountB > 0) {
                tokenB.safeTransfer(to, amountB);
            }
        }
    }

    function _rebalanceAndAddLiquidity(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96Upper,
        uint160 sqrtPriceX96Lower,
        uint256 amount0,
        uint256 amount1,
        address from, //user
        address to
    )
        internal
        returns (uint tokenId, uint liquidity, uint successA, uint successB)
    {
        // sort token0 and token1
        (address tokenA, address tokenB, uint amountA, uint amountB) = token0 <
            token1
            ? (token0, token1, amount0, amount1)
            : (token1, token0, amount1, amount0);

        // Get Pool Address and current price
        address pool = factory.getPool(tokenA, tokenB, fee);
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        //1. Transfer tokenA and tokenB to this contract
        tokenA.safeTransferFrom(from, address(this), amountA);
        tokenB.safeTransferFrom(from, address(this), amountB);
        //2. Calculate how much token A to swap or how much token B to swap
        (uint baseAmount, bool isSwapA) = RebalanceDeposit.rebalanceDeposit(
            tokenA,
            tokenB,
            sqrtPriceX96Upper,
            sqrtPriceX96Lower,
            sqrtPriceX96,
            amountA,
            amountB
        );
        //3. Swap token A or token B using UniswapV3 SwapRouter
        uint farmAmount = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: isSwapA ? tokenA : tokenB,
                tokenOut: isSwapA ? tokenB : tokenA,
                fee: fee,
                recipient: address(this),
                deadline: type(uint256).max,
                amountIn: baseAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        amountA = isSwapA ? amountA - baseAmount : amountA + farmAmount;
        amountB = isSwapA ? amountB + farmAmount : amountB - baseAmount;

        // Get Tick From Price
        int24 tickLower = TickMath.getTickAtSqrtRatio(sqrtPriceX96Lower);
        int24 tickUpper = TickMath.getTickAtSqrtRatio(sqrtPriceX96Upper);
        //4. Add liquidity To UniswapV3 and Mint to user
        (tokenId, liquidity, successA, successB) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: tokenA,
                token1: tokenB,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amountA,
                amount1Desired: amountB,
                amount0Min: 0,
                amount1Min: 0,
                recipient: to,
                deadline: type(uint256).max
            })
        );
    }

    function _rebalanceAndIncreaseLiquidity(
        uint tokenId,
        uint256 amount0, //-> amount of token0
        uint256 amount1, // -> amount of token1
        address from //user
    ) internal returns (uint successLiquidity, uint successA, uint successB) {
        int24 tickLower;
        int24 tickUpper;
        uint24 fee;
        address tokenA;
        address tokenB;
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
        uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(tickUpper);
        address pool = factory.getPool(tokenA, tokenB, fee);
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        tokenA = IUniswapV3Pool(pool).token0();
        tokenB = IUniswapV3Pool(pool).token1();
        //1. Transfer NFT,tokenA and tokenB to this contract
        positionManager.safeTransferFrom(from, address(this), tokenId);
        tokenA.safeTransferFrom(from, address(this), amount0);
        tokenB.safeTransferFrom(from, address(this), amount1);
        //2. Calculate how much token A to swap or how much token B to swap
        (uint baseAmount, bool isSwapA) = RebalanceDeposit.rebalanceDeposit(
            tokenA,
            tokenB,
            sqrtPriceX96Upper,
            sqrtPriceX96Lower,
            sqrtPriceX96,
            amount0,
            amount1
        );
        //3. Swap token A or token B using UniswapV3 SwapRouter
        uint farmAmount = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: isSwapA ? tokenA : tokenB,
                tokenOut: isSwapA ? tokenB : tokenA,
                fee: fee,
                recipient: address(this),
                deadline: type(uint256).max,
                amountIn: baseAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        amount0 = isSwapA ? amount0 - baseAmount : amount0 + farmAmount;
        amount1 = isSwapA ? amount1 + farmAmount : amount1 - baseAmount;
        //4. Increase liquidity
        (successLiquidity, successA, successB) = positionManager
            .increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: amount0,
                    amount1Desired: amount1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: type(uint256).max
                })
            );
    }
}
