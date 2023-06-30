// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity =0.7.6;
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
     * if depositUSDRatio, A/B == 40/60 is the current ratio decided by upper tick and lower tick
     * Rebalance: A(63) + B(37) -> A(40) + B(60)
     * Partition: A(100) + B(0) -> A(40) + B(60)
     * Decompose: C(100) -> A(40) + B(60)
     ******************************************************************************/

    //sqrtPriceX = sqrt(amountY/amountX) * 2^96
    function rebalanceAndAddLiquidity(
        address tokenA,
        address tokenB,
        uint24 fee,
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
        // 1. sort token0 and token1
        require(tokenA != tokenB, "token0 and token1 must be different");
        (tokenA, tokenB, amountA, amountB) = tokenA < tokenB
            ? (tokenA, tokenB, amountA, amountB)
            : (tokenB, tokenA, amountB, amountA);
        // 2. rebalance and add liquidity
        (
            tokenId,
            successLiquidity,
            successA,
            successB
        ) = _rebalanceAndAddLiquidity(
            tokenA,
            tokenB,
            fee,
            sqrtPriceX96Upper,
            sqrtPriceX96Lower,
            amountA,
            amountB,
            msg.sender,
            to //if mint by myself, to = msg.sender
        );
        // 3. Transfer tokens back to user if there is any left
        _transferRestTokens(tokenA, tokenB, msg.sender);
    }

    // partition function is not needed, because we can use rebalance to do the same thing

    function decomposeAndAddLiquidity(
        address tokenA,
        address tokenB,
        uint24 fee,
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
        require(tokenA != tokenB, "token0 and token1 must be different");

        //1. sort token0 and token1
        (tokenA, tokenB) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        require(
            tokenA == path[path.length - 1] || tokenB == path[path.length - 1],
            "path must end with tokenA or tokenB"
        );
        //2. Transfer tokenC to this contract
        (path[0]).safeTransferFrom(msg.sender, address(this), amountC);
        //3. Swap amountC of tokenC to token0 or token1
        uint amountOut;
        {
            amountOut = swapRouter.exactInput(
                ISwapRouter.ExactInputParams(
                    abi.encodePacked(path),
                    address(this),
                    type(uint).max,
                    amountC,
                    0
                )
            );
        }

        //3. Rebalance amountOut and add liquidity and mint to "to"
        if (tokenA == path[path.length - 1]) {
            (
                tokenId,
                successLiquidity,
                successA,
                successB
            ) = _rebalanceAndAddLiquidity(
                tokenA,
                tokenB,
                fee,
                sqrtPriceX96Upper,
                sqrtPriceX96Lower,
                amountOut,
                0,
                address(this),
                to
            );
        } else if (tokenB == path[path.length - 1]) {
            (
                tokenId,
                successLiquidity,
                successA,
                successB
            ) = _rebalanceAndAddLiquidity(
                tokenA,
                tokenB,
                fee,
                sqrtPriceX96Upper,
                sqrtPriceX96Lower,
                0,
                amountOut,
                address(this),
                to
            );
        }
        //4. Transfer back to user if there is any left
        _transferRestTokens(tokenA, tokenB, msg.sender);
    }

    /*** add liquidity to existing pool ***/
    function rebalanceAndIncreaseLiquidity(
        uint tokenId,
        address tokenA,
        address tokenB,
        uint amountA,
        uint amountB
    ) external returns (uint successLiquidity, uint successA, uint successB) {
        require(tokenA != tokenB, "tokenA and tokenB must be different");
        //1. sort tokenA and tokenB
        (tokenA, tokenB, amountA, amountB) = tokenA < tokenB
            ? (tokenA, tokenB, amountA, amountB)
            : (tokenB, tokenA, amountB, amountA);
        //2. rebalance and increase liquidity
        (
            successLiquidity,
            ,
            ,
            successA,
            successB
        ) = _rebalanceAndIncreaseLiquidity(
            tokenId,
            amountA,
            amountB,
            msg.sender
        );

        // Transfer back to user if there is any left
        _transferRestTokens(tokenA, tokenB, msg.sender);
    }

    // function partitionAndIncreaseLiquidity is not needed, because we can use rebalance to do the same thing
    function decomposeAndIncreaseLiquidity(
        uint tokenId,
        address tokenC,
        uint amountC,
        address[] memory path // tokenC -> tokenA or tokenB path
    ) external returns (uint successLiquidity, uint successA, uint successB) {
        // 1. Transfer tokenC to this contract
        tokenC.safeTransferFrom(msg.sender, address(this), amountC);

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

        (
            successLiquidity,
            tokenA,
            tokenB,
            successA,
            successB
        ) = _rebalanceAndIncreaseLiquidity(tokenId, amountOut, 0, msg.sender);
        // 3. Transfer back to user if there is any left
        _transferRestTokens(tokenA, tokenB, msg.sender);
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
        address(path1[path1.length - 1]).safeTransfer(
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

        (path1[path1.length - 1]).safeTransfer(
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
        address tokenA,
        address tokenB, //already sorted
        uint24 fee,
        uint160 sqrtPriceX96Upper,
        uint160 sqrtPriceX96Lower,
        uint amountA,
        uint amountB,
        address from, //user
        address to
    )
        internal
        returns (uint tokenId, uint liquidity, uint successA, uint successB)
    {
        // Get Pool Address and current price
        address pool = factory.getPool(tokenA, tokenB, fee);
        require(pool != address(0), "pool does not exist");
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        //1. Transfer tokenA and tokenB to this contract
        if (from != address(this)) {
            tokenA.safeTransferFrom(from, address(this), amountA);
            tokenB.safeTransferFrom(from, address(this), amountB);
        }
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
                deadline: type(uint).max,
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
                deadline: type(uint).max
            })
        );
    }

    function _rebalanceAndIncreaseLiquidity(
        uint tokenId,
        uint amountA, //-> amount of tokenA
        uint amountB, //-> amount of tokenB
        address from //user
    )
        internal
        returns (
            uint successLiquidity,
            address tokenA,
            address tokenB,
            uint successA,
            uint successB
        )
    {
        uint160 sqrtPriceX96Lower;
        uint160 sqrtPriceX96Upper;
        uint24 fee;
        {
            int24 tickLower;
            int24 tickUpper;
            (, , , , fee, tickLower, tickUpper, , , , , ) = positionManager
                .positions(tokenId);

            sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(tickLower);
            sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(tickUpper);
        }
        uint160 sqrtPriceX96;
        {
            address pool = factory.getPool(tokenA, tokenB, fee);
            (sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        }
        //1. Calculate how much token A to swap or how much token B to swap
        (uint baseAmount, bool isSwapA) = RebalanceDeposit.rebalanceDeposit(
            tokenA,
            tokenB,
            sqrtPriceX96Upper,
            sqrtPriceX96Lower,
            sqrtPriceX96,
            amountA,
            amountB
        );
        //2. Transfer NFT,tokenA and tokenB to this contract
        positionManager.safeTransferFrom(from, address(this), tokenId);
        if (from != address(this)) {
            tokenA.safeTransferFrom(from, address(this), amountA);
            tokenB.safeTransferFrom(from, address(this), amountB);
        }
        //3. Swap token A or token B using UniswapV3 SwapRouter
        uint farmAmount = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: isSwapA ? tokenA : tokenB,
                tokenOut: isSwapA ? tokenB : tokenA,
                fee: fee,
                recipient: address(this),
                deadline: type(uint).max,
                amountIn: baseAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        amountA = isSwapA ? amountA - baseAmount : amountA + farmAmount;
        amountB = isSwapA ? amountB + farmAmount : amountB - baseAmount;
        //4. Increase liquidity
        (successLiquidity, successA, successB) = positionManager
            .increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: amountA,
                    amount1Desired: amountB,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: type(uint).max
                })
            );
    }
}
