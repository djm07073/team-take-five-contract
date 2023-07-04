// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity >=0.7.6;
pragma abicoder v2;
import "./libraries/TickMath.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/RebalanceDeposit.sol";
import "./interfaces/IERC20Minimal.sol";

contract UniswapV3Funnel {
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
     * if depositUSDRatio, A/B == 40/60 is the current ratio decided by upper tick and lower tick
     * Rebalance: A(63) + B(37) -> A(40) + B(60)
     * Partition: A(100) + B(0) -> A(40) + B(60)
     * Decompose: C(100) -> A(40) + B(60)
     ******************************************************************************/

    //sqrtPriceX = sqrt(amountY/amountX) * 2^96
    function rebalanceAndAddLiquidity(
        IUniswapV3Pool pool, //(factory, tokenA, tokenB, fee)
        uint160 sqrtPriceX96Upper,
        uint160 sqrtPriceX96Lower,
        uint amountA,
        uint amountB,
        address to
    )
        external
        returns (
            uint tokenId,
            uint successLiquidity,
            uint successA,
            uint successB
        )
    {
        require(address(pool) != address(0), "pool must exist");

        // 1. transfer tokenA and tokenB to this contract
        TransferHelper.safeTransferFrom(
            pool.token0(),
            msg.sender,
            address(this),
            amountA
        );
        TransferHelper.safeTransferFrom(
            pool.token1(),
            msg.sender,
            address(this),
            amountB
        );
        // 2. rebalance and add liquidity
        (
            tokenId,
            successLiquidity,
            successA,
            successB
        ) = _rebalanceAndAddLiquidity(
            IUniswapV3Pool(pool),
            sqrtPriceX96Upper,
            sqrtPriceX96Lower,
            to //if mint by myself, to = msg.sender
        );
        // 4. Transfer tokens back to user if there is any left
        _transferRestTokens(
            IERC20Minimal(pool.token0()),
            IERC20Minimal(pool.token0()),
            msg.sender
        );
    }

    // partition function is not needed, because we can use rebalance to do the same thing

    function decomposeAndAddLiquidity(
        address pool, //(facto)
        uint160 sqrtPriceX96Upper,
        uint160 sqrtPriceX96Lower,
        uint amountC,
        address to,
        address[] memory path // path[0] = tokenC -> token0 or token1 path
    )
        external
        returns (
            uint tokenId,
            uint successLiquidity,
            uint successA,
            uint successB
        )
    {
        require(pool != address(0), "pool must exist");
        require(
            IUniswapV3Pool(pool).token0() == path[path.length - 1] ||
                IUniswapV3Pool(pool).token1() == path[path.length - 1],
            "path must end with tokenA or tokenB"
        );
        //2. Transfer tokenC to this contract
        TransferHelper.safeTransferFrom(
            (path[0]),
            msg.sender,
            address(this),
            amountC
        );
        //3. Swap amountC of tokenC to token0 or token1

        swapRouter.exactInput(
            ISwapRouter.ExactInputParams(
                abi.encodePacked(path),
                address(this),
                type(uint).max,
                amountC,
                0
            )
        );

        //4. Rebalance amountOut and add liquidity and mint to "to"

        (
            tokenId,
            successLiquidity,
            successA,
            successB
        ) = _rebalanceAndAddLiquidity(
            IUniswapV3Pool(pool),
            sqrtPriceX96Upper,
            sqrtPriceX96Lower,
            to
        );

        //4. Transfer back to user if there is any left
        _transferRestTokens(
            IERC20Minimal(IUniswapV3Pool(pool).token0()),
            IERC20Minimal(IUniswapV3Pool(pool).token1()),
            msg.sender
        );
    }

    /*** add liquidity to existing pool ***/
    function rebalanceAndIncreaseLiquidity(
        uint tokenId,
        IUniswapV3Pool pool,
        uint112 amountA, //
        uint112 amountB
    ) external returns (uint successLiquidity) {
        // 1. transfer tokenA and tokenB to this contract
        TransferHelper.safeTransferFrom(
            pool.token0(),
            msg.sender,
            address(this),
            amountA
        );
        TransferHelper.safeTransferFrom(
            pool.token1(),
            msg.sender,
            address(this),
            amountB
        );
        // 3. rebalance and increase liquidity
        (successLiquidity) = _rebalanceAndIncreaseLiquidity(
            tokenId,
            amountA,
            amountB,
            msg.sender
        );

        // 4. Transfer back to user if there is any left
        _transferRestTokens(
            IERC20Minimal(pool.token0()),
            IERC20Minimal(pool.token1()),
            msg.sender
        );
    }

    // function partitionAndIncreaseLiquidity is not needed, because we can use rebalance to do the same thing
    function decomposeAndIncreaseLiquidity(
        uint tokenId,
        address tokenC,
        uint amountC,
        address[] memory path // tokenC -> tokenA or tokenB path
    ) external returns (uint successLiquidity) {
        // 1. Transfer tokenC to this contract
        TransferHelper.safeTransferFrom(
            tokenC,
            msg.sender,
            address(this),
            amountC
        );

        // 2. Swap amountC of tokenC to tokenA
        uint amountOut = swapRouter.exactInput(
            ISwapRouter.ExactInputParams(
                abi.encodePacked(path),
                address(this),
                type(uint).max,
                amountC,
                0
            )
        );
        address tokenA;
        address tokenB;

        (successLiquidity) = _rebalanceAndIncreaseLiquidity(
            tokenId,
            uint112(amountOut),
            0,
            msg.sender
        );
        // 3. Transfer back to user if there is any left
        _transferRestTokens(
            IERC20Minimal(tokenA),
            IERC20Minimal(tokenB),
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
                type(uint).max,
                amount0,
                0
            )
        );
        uint amount1Out = swapRouter.exactInput(
            ISwapRouter.ExactInputParams(
                abi.encodePacked(path2),
                address(this),
                type(uint).max,
                amount1,
                0
            )
        );
        //4. Transfer dstToken to user & Transfer NFT to user
        TransferHelper.safeTransfer(
            address(path1[path1.length - 1]),
            to,
            amount0Out + amount1Out
        );
        positionManager.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    /*** remove liquidity ***/
    function removeLiquidity(
        uint tokenId,
        uint128 liquidityToRemove, // should be calculated by frontend
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
            address tokenA,
            address tokenB,
            ,
            ,
            ,
            uint128 liquidity,
            ,
            ,
            ,

        ) = positionManager.positions(tokenId);
        require(
            path1[0] == tokenA && path2[0] == tokenB,
            "path of src token is wrong"
        );
        //2. Transfer NFT to this contract
        positionManager.safeTransferFrom(msg.sender, address(this), tokenId);
        //3. Decrease liquidity
        (uint amountA, uint amountB) = positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToRemove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint).max
            })
        );

        //4. swap to dstToken and transfer to user
        uint amountAOut;
        uint amountBOut;
        //4.1 swap token0 to dstToken
        {
            amountAOut = swapRouter.exactInput(
                ISwapRouter.ExactInputParams(
                    abi.encodePacked(path1),
                    address(this),
                    type(uint).max,
                    amountA,
                    0
                )
            );
            //4.2 swap token1 to dstToken
            amountBOut = swapRouter.exactInput(
                ISwapRouter.ExactInputParams(
                    abi.encodePacked(path2),
                    address(this),
                    type(uint).max,
                    amountB,
                    0
                )
            );
        }
        //4.3 transfer dstToken to "to"

        TransferHelper.safeTransfer(
            (path1[path1.length - 1]),
            msg.sender,
            amountAOut + amountBOut
        );

        //5. if rest of liquidity is 0, burn NFT, otherwise return to user
        if (liquidity == liquidityToRemove) {
            positionManager.burn(tokenId);
        } else {
            positionManager.safeTransferFrom(
                address(this),
                msg.sender,
                tokenId
            );
        }
    }

    function _transferRestTokens(
        IERC20Minimal tokenA,
        IERC20Minimal tokenB,
        address to
    ) internal {
        if (tokenA.balanceOf(address(this)) != 0) {
            TransferHelper.safeTransferFrom(
                address(tokenA),
                address(this),
                to,
                tokenA.balanceOf(address(this))
            );
        }
        if (tokenB.balanceOf(address(this)) != 0) {
            TransferHelper.safeTransferFrom(
                address(tokenB),
                address(this),
                to,
                tokenB.balanceOf(address(this))
            );
        }
    }

    function _rebalanceAndAddLiquidity(
        IUniswapV3Pool pool,
        uint160 sqrtPriceX96Upper,
        uint160 sqrtPriceX96Lower,
        address to
    )
        internal
        returns (
            uint tokenId,
            uint successLiquidity,
            uint successA,
            uint successB
        )
    {
        //1. Calculate how much token A to swap or how much token B to swap
        (uint baseAmount, bool isSwapA) = RebalanceDeposit.rebalanceDeposit(
            pool,
            sqrtPriceX96Upper,
            sqrtPriceX96Lower,
            uint112(IERC20Minimal(pool.token0()).balanceOf(address(this))),
            uint112(IERC20Minimal(pool.token1()).balanceOf(address(this)))
        );
        //2. Swap token A or token B using UniswapV3 SwapRouter
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: isSwapA ? (pool.token0()) : (pool.token1()),
                tokenOut: isSwapA ? (pool.token1()) : (pool.token0()),
                fee: pool.fee(),
                recipient: address(this),
                deadline: type(uint).max,
                amountIn: baseAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Get Tick From Price
        int24 tickLower = TickMath.getTickAtSqrtRatio(sqrtPriceX96Lower);
        int24 tickUpper = TickMath.getTickAtSqrtRatio(sqrtPriceX96Upper);
        //3. Add liquidity To UniswapV3 and Mint to user
        (tokenId, successLiquidity, successA, successB) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: pool.token0(),
                token1: pool.token1(),
                fee: pool.fee(),
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: IERC20Minimal(pool.token0()).balanceOf(
                    address(this)
                ),
                amount1Desired: IERC20Minimal(pool.token1()).balanceOf(
                    address(this)
                ),
                amount0Min: 0,
                amount1Min: 0,
                recipient: to,
                deadline: type(uint).max
            })
        );
    }

    function _rebalanceAndIncreaseLiquidity(
        uint tokenId,
        uint112 amountA, //-> amount of tokenA
        uint112 amountB, //-> amount of tokenB
        address from //user
    ) internal returns (uint) {
        //1. Calculate how much token A to swap or how much token B to swap

        {
            (
                uint baseAmount,
                bool isSwapA,
                ,
                ,
                uint24 fee,
                address _tokenA,
                address _tokenB
            ) = RebalanceDeposit.rebalanceIncrease(
                    positionManager,
                    factory,
                    tokenId,
                    amountA,
                    amountB
                );

            //2. Transfer NFT,tokenA and tokenB to this contract
            positionManager.safeTransferFrom(from, address(this), tokenId);
            if (from != address(this)) {
                TransferHelper.safeTransferFrom(
                    _tokenA,
                    from,
                    address(this),
                    amountA
                );
                TransferHelper.safeTransferFrom(
                    _tokenB,
                    from,
                    address(this),
                    amountB
                );
            }
            {
                //3. Swap token A or token B using UniswapV3 SwapRouter
                uint farmAmount = swapRouter.exactInputSingle(
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: isSwapA ? _tokenA : _tokenB,
                        tokenOut: isSwapA ? _tokenB : _tokenA,
                        fee: fee,
                        recipient: address(this),
                        deadline: type(uint).max,
                        amountIn: baseAmount,
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    })
                );

                amountA = isSwapA
                    ? amountA - uint112(baseAmount)
                    : amountA + uint112(farmAmount);
                amountB = isSwapA
                    ? amountB + uint112(farmAmount)
                    : amountB - uint112(baseAmount);
            }
        }
        //4. Increase liquidity
        (uint successLiquidity, , ) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amountA,
                amount1Desired: amountB,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint).max
            })
        );

        return (successLiquidity);
    }
}
