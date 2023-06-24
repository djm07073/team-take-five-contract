// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "./uniswapV2/periphery/libraries/UniswapV2LibraryV8.sol";
import "./uniswapV2/core/interfaces/IUniswapV2ERC20.sol";
import "./uniswapV2/periphery/libraries/SafeMath.sol";
import "./uniswapV2/core/libraries/Math.sol";
import "./uniswapV2/periphery/libraries/TransferHelper.sol";
import "./interfaces/IWETH9.sol";
import "hardhat/console.sol";

contract UniswapV2Funnel {
    using SafeMath for uint;
    address public owner;
    address public WETH;
    mapping(address => uint32) public feeOf;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        _;
    }
    /**
     * reserveb0b reserve of baseToken in pair0
     * reserveb00 reserve of farm0 in pair0
     * reserveb1b reserve of baseToken in pair1
     * reserveb11 reserve of farm1 in pair1
     * reserve010 reserve of farm0 in pair01
     * reserve011 reserve of farm1 in pair01
     */
    struct Reserves3 {
        uint112 reserveb0b;
        uint112 reserveb00;
        uint32 feeb0Bps;
        uint112 reserveb1b;
        uint112 reserveb11;
        uint32 feeb1Bps;
        uint112 reserve010;
        uint112 reserve011;
    }

    // for efficient memory use
    struct AmountPair {
        uint112 amount0;
        uint112 amount1;
    }

    function initialize(address WETH_) external {
        owner = msg.sender;
        WETH = WETH_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!OWNER");
        _;
    }

    function setOwner(address owner_) external onlyOwner {
        owner = owner_;
    }

    function setFeeOf(address factory, uint32 feeBps) public onlyOwner {
        feeOf[factory] = feeBps;
    }

    function _transferFromSenderOrWrap(
        address token,
        address to,
        uint amount
    ) private {
        if (token == WETH) {
            // require(msg.value == amount, "FUNNEL:!msg.value");
            TransferHelper.safeTransfer(WETH, to, amount);
        } else {
            TransferHelper.safeTransferFrom(token, msg.sender, to, amount);
        }
    }

    /**
     * A/B pair에 유동성 공급을 할때
     * partition: A -> A + B
     * rebalance: A + B -> A + B (비율 재조정)
     * decompose: A -> B + C
     * 위의 세가지 방법을 통해 유동성공급을 수행합니다.
     */

    /*********************************************
     * 1.한 자산을 재조정해서 Uniswap에 유동성 공급 (A -> A + B)
     *********************************************/

    function partitionAndAddLiquidity(
        address pair,
        address baseToken,
        address to,
        uint baseAmount
    ) public payable returns (uint liquidity) {
        address factory = IUniswapV2Pair(pair).factory();
        address farmToken = IUniswapV2Pair(pair).token0() == baseToken
            ? IUniswapV2Pair(pair).token1()
            : IUniswapV2Pair(pair).token0();
        baseToken = IUniswapV2Pair(pair).token0() == baseToken
            ? IUniswapV2Pair(pair).token0()
            : IUniswapV2Pair(pair).token1();
        if (baseToken == WETH) {
            IWETH9(WETH).deposit{value: baseAmount}();
        }

        // 1. rebalance baseAmount and farmAmount
        // 2. swap one of part to farmToken(value of baseToken > value of farmToken) or baseToken (value of baseToken < value of farmToken)
        // 3. add liquidity
        uint112 rBase;
        uint112 rFarm;

        (rBase, rFarm, ) = IUniswapV2Pair(pair).getReserves();

        if (baseToken > farmToken) (rBase, rFarm) = (rFarm, rBase);

        uint32 fee = feeOf[factory];
        // 1. rebalance baseAmount into 2 parts
        (uint swapAmount, uint swappedAmount, ) = optimalSwapAmount(
            baseAmount,
            0,
            uint112(rBase),
            uint112(rFarm),
            fee
        );

        // part of baseToken -> farmToken
        _swapFromSender(
            IUniswapV2Pair(pair),
            baseToken,
            farmToken,
            swapAmount,
            swappedAmount,
            address(this)
        );
        // 3. add liquidity
        // 3-1. transfer rest baseAmount to pair (user -> pair)
        _transferFromSenderOrWrap(baseToken, pair, baseAmount - swapAmount);
        // 3-2. transfer farmAmount to pair (this -> pair)
        TransferHelper.safeTransfer(farmToken, pair, swappedAmount);
        // 3-3. mint liquidity
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    /****************************************************
     * 2. 두 자산의 비율을 재조정해서 유동성 공급 (A + B -> A + B)
     *****************************************************/

    function rebalanceAndAddLiquidity(
        address pair,
        address baseToken,
        address to,
        uint baseAmount,
        uint farmAmount
    ) public payable returns (uint liquidity) {
        address factory = IUniswapV2Pair(pair).factory();
        address farmToken = IUniswapV2Pair(pair).token0() == baseToken
            ? IUniswapV2Pair(pair).token1()
            : IUniswapV2Pair(pair).token0();
        baseToken = IUniswapV2Pair(pair).token0() == baseToken
            ? IUniswapV2Pair(pair).token0()
            : IUniswapV2Pair(pair).token1();

        if (baseToken == WETH) {
            IWETH9(WETH).deposit{value: baseAmount}();
        } else if (farmToken == WETH) {
            IWETH9(WETH).deposit{value: farmAmount}();
        }

        // 1. rebalance baseAmount and farmAmount
        // 2. swap one of part to farmToken(value of baseToken > value of farmToken) or baseToken (value of baseToken < value of farmToken)
        // 3. add liquidity

        uint112 rBase;
        uint112 rFarm;

        (rBase, rFarm, ) = IUniswapV2Pair(pair).getReserves();

        if (baseToken > farmToken) (rBase, rFarm) = (rFarm, rBase);

        uint32 fee = feeOf[factory];
        // 1. rebalance baseAmount into 2 parts
        (uint swapAmount, uint swappedAmount, bool swap0) = optimalSwapAmount(
            baseAmount,
            farmAmount,
            uint112(rBase),
            uint112(rFarm),
            fee
        );

        //2. swap one of part to farmToken(value of baseToken > value of farmToken) or baseToken (value of baseToken < value of farmToken)
        if (swap0) {
            // part of baseToken -> farmToken
            _swapFromSender(
                IUniswapV2Pair(pair),
                baseToken,
                farmToken,
                swapAmount,
                swappedAmount,
                address(this)
            );
            // 3. add liquidity
            // 3-1. transfer rest baseAmount to pair (user -> pair)
            _transferFromSenderOrWrap(baseToken, pair, baseAmount - swapAmount);
            _transferFromSenderOrWrap(farmToken, pair, farmAmount);
            // 3-2. transfer farmAmount to pair (this -> pair)
            TransferHelper.safeTransfer(farmToken, pair, swappedAmount);
            // 3-3. mint liquidity
            liquidity = IUniswapV2Pair(pair).mint(to);
        } else {
            _swapFromSender(
                IUniswapV2Pair(pair),
                farmToken,
                baseToken,
                swapAmount,
                swappedAmount,
                address(this)
            );
            // 3. add liquidity
            // 3-1. transfer rest baseAmount to pair (user -> pair)
            _transferFromSenderOrWrap(farmToken, pair, farmAmount - swapAmount);
            // TransferHelper.safeTransferFrom(
            //     farmToken,
            //     msg.sender,
            //     pair,
            //     farmAmount - swapAmount
            // );
            // 3-2. transfer farmAmount to pair (this -> pair)
            _transferFromSenderOrWrap(baseToken, pair, baseAmount);
            // TransferHelper.safeTransferFrom(baseToken, msg.sender, pair, baseAmount);
            TransferHelper.safeTransfer(baseToken, pair, swappedAmount);
            // 3-3. mint liquidity
            liquidity = IUniswapV2Pair(pair).mint(to);
        }
    }

    /**
     * @dev Compute optimal swap amount
     * @param amount0 token0 Input Amount
     * @param amount1 token1 Input Amount
     * @param reserve0 token0 Reserved Amount in Syncswap Pair
     * @param reserve1 token1 Reserved Amount in Syncswap Pair
     * @param feeBps : decimals=4
     * @return swapAmount amount to swap
     * @return swappedAmount swap result amount
     * @return swap0 if true, swap `amountSwap` from token0 to token1. else, vise versa.
     */
    function optimalSwapAmount(
        uint amount0,
        uint amount1,
        uint112 reserve0,
        uint112 reserve1,
        uint32 feeBps
    ) public pure returns (uint swapAmount, uint swappedAmount, bool swap0) {
        if (amount0 * reserve1 >= amount1 * reserve0) {
            swap0 = true;
            swapAmount = _optimalSwapAmountIn(
                // amount0 - (amount1 * reserve0) / reserve1,
                amount0,
                amount1,
                reserve0,
                reserve1,
                feeBps
            );
            swappedAmount = UniswapV2Library.getAmountOut(
                uint112(swapAmount),
                reserve0,
                reserve1,
                feeBps
            );
        } else {
            // default swap0 = false
            // swap0 = false;
            swapAmount = _optimalSwapAmountIn(
                // amount1 - (amount0 * reserve1) / reserve0,
                amount1,
                amount0,
                reserve1,
                reserve0,
                feeBps
            );
            swappedAmount = UniswapV2Library.getAmountOut(
                uint112(swapAmount),
                reserve1,
                reserve0,
                feeBps
            );
        }
    }

    /**
     * let t be optimal swap amount,
     * simplified formula is:
     * t^2
     * + ( (2-fee) * (rIn) / (1-fee) ) * t
     * + rIn * (amountIn * rOut - amountOut * rIn) / (1-fee)(amountOut + reserveOut) = 0
     *
     */
    function _optimalSwapAmountIn(
        uint amountIn,
        uint amountOut,
        uint112 reserveIn,
        uint112 reserveOut,
        uint32 feeBps
    ) internal pure returns (uint swapAmount) {
        uint b = (uint(2e4 - feeBps) * reserveIn) / (1e4 - feeBps) / 2;
        uint c = (uint(reserveIn) *
            (amountIn * reserveOut - amountOut * reserveIn)) /
            (((1e4 - feeBps) * (reserveOut + amountOut)) / 1e4);
        // use quadratic formula
        swapAmount = Math.sqrt(b ** 2 + c) - b;
    }

    /*******************************************************************
     * 3. 한 자산을 두 가지의 다른 토큰으로 스왑하여 Uniswap에 유동성 공급(C -> A + B)
     *******************************************************************/
    function decomposeAndAddLiquidity(
        address baseToken,
        IUniswapV2Pair farmPair,
        address to,
        uint112 baseAmount
    ) public payable returns (uint liquidity) {
        address factory = farmPair.factory();
        address farm0 = farmPair.token0();
        address farm1 = farmPair.token1();
        if (baseToken == WETH) {
            IWETH9(WETH).deposit{value: baseAmount}();
        }

        if (farm0 > farm1) (farm0, farm1) = (farm1, farm0);

        address pairb0 = UniswapV2Library.pairFor(factory, baseToken, farm0);
        address pairb1 = UniswapV2Library.pairFor(factory, baseToken, farm1);
        address pair01 = UniswapV2Library.pairFor(factory, farm0, farm1);

        Reserves3 memory reserves;
        {
            uint32 feeBps = feeOf[factory];
            reserves = Reserves3(0, 0, feeBps, 0, 0, feeBps, 0, 0);
        }

        // baseAmount에서 farm0 / farm1로 스왑되어야 할 양
        AmountPair memory swapAmounts = AmountPair(0, 0);
        // baseAmount에서 farm0 / farm1로 스왑된 후의 양
        AmountPair memory farmAmounts = AmountPair(0, 0);

        {
            (uint112 reserveb0b, uint112 reserveb00, ) = IUniswapV2Pair(pairb0)
                .getReserves();
            if (baseToken > farm0)
                (reserveb0b, reserveb00) = (reserveb00, reserveb0b);
            reserves.reserveb0b = reserveb0b;
            reserves.reserveb00 = reserveb00;
        }
        {
            (uint112 reserveb1b, uint112 reserveb11, ) = IUniswapV2Pair(pairb1)
                .getReserves();
            if (baseToken > farm1)
                (reserveb1b, reserveb11) = (reserveb11, reserveb1b);
            reserves.reserveb1b = reserveb1b;
            reserves.reserveb11 = reserveb11;
        }
        {
            (uint112 reserve010, uint112 reserve011, ) = IUniswapV2Pair(pair01)
                .getReserves();
            reserves.reserve010 = reserve010;
            reserves.reserve011 = reserve011;
        }
        {
            swapAmounts.amount0 = optimalDecomposeAmount(baseAmount, reserves);
            swapAmounts.amount1 = baseAmount - swapAmounts.amount0;
            // 1. swap base -> farm0
            farmAmounts.amount0 = uint112(
                UniswapV2Library.getAmountOut(
                    swapAmounts.amount0,
                    reserves.reserveb0b,
                    reserves.reserveb00,
                    reserves.feeb0Bps
                )
            );
            // 2. swap base -> farm1
            farmAmounts.amount1 = uint112(
                UniswapV2Library.getAmountOut(
                    swapAmounts.amount1,
                    reserves.reserveb1b,
                    reserves.reserveb11,
                    reserves.feeb1Bps
                )
            );
        }

        {
            (uint112 remainedAmount, bool remain0) = calcRemainedAmount(
                farmAmounts.amount0,
                farmAmounts.amount1,
                reserves.reserve010,
                reserves.reserve011
            );

            if (remain0) {
                farmAmounts.amount0 -= remainedAmount;
                swapAmounts.amount0 = UniswapV2Library.getAmountIn(
                    farmAmounts.amount0,
                    reserves.reserveb0b,
                    reserves.reserveb00,
                    reserves.feeb0Bps
                );
            } else {
                farmAmounts.amount1 -= remainedAmount;
                swapAmounts.amount1 = UniswapV2Library.getAmountIn(
                    farmAmounts.amount1,
                    reserves.reserveb1b,
                    reserves.reserveb11,
                    reserves.feeb1Bps
                );
            }
        }

        _swapFromSender(
            IUniswapV2Pair(pairb0),
            baseToken,
            farm0,
            swapAmounts.amount0,
            farmAmounts.amount0,
            pair01
        );

        _swapFromSender(
            IUniswapV2Pair(pairb1),
            baseToken,
            farm1,
            swapAmounts.amount1,
            farmAmounts.amount1,
            pair01
        );

        liquidity = IUniswapV2Pair(pair01).mint(to);
    }

    /************************************
     * 원하는 토큰으로 유동성 제거
     ************************************/
    /**
     *
     * @param lpAddress liquidity pool address
     * @param liquidity liquidity amount
     * @param to receiver address
     * @param path1 path1 for swap baseToken -> destToken
     * @param path2 path2 for swap farmToken -> destToken
     * TODO:vs farmToken -> baseToken, then baseToken -> destToken??
     */
    function removeLiquidityAndSwapToDstToken(
        address lpAddress,
        uint liquidity,
        address to,
        address[] calldata path1,
        address[] calldata path2,
        uint dstTokenMin,
        uint deadline
    ) external returns (uint dstTokenAmount) {
        require(
            path1[path1.length - 1] == path2[path2.length - 1],
            "dstToken must be the same"
        );

        address pair = lpAddress;
        address factory = IUniswapV2Pair(lpAddress).factory();
        uint32 feeBps = feeOf[factory];
        //* 1. remove liquidity
        //* path1[0] : baseToken , path2[0]: farmToken
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(address(this));
        (address token0, ) = UniswapV2Library.sortTokens(path1[0], path2[0]);
        (uint baseAmount, uint farmAmount) = path1[0] == token0
            ? (amount0, amount1)
            : (amount1, amount0);

        //* 2. swap baseToken -> dstToken, then transfer to to
        uint[] memory amountFromBase = _swapExactTokensForTokens(
            factory,
            baseAmount,
            1,
            path1,
            to,
            deadline,
            feeBps
        );
        //* 3. swap farmToken -> dstToken, then transfer to to
        uint[] memory amountFromFarm = _swapExactTokensForTokens(
            factory,
            farmAmount,
            1,
            path2,
            to,
            deadline,
            feeBps
        );
        //* dstTokenAmount
        dstTokenAmount =
            amountFromBase[amountFromBase.length - 1] +
            amountFromFarm[amountFromFarm.length - 1];
        require(
            dstTokenAmount >= dstTokenMin,
            "should be more than min-amount"
        );
    }

    function removeLiquidityAndSwapToETH(
        address lpAdress,
        uint liquidity,
        address to,
        address[] calldata path1,
        address[] calldata path2,
        uint dstTokenMin,
        uint deadline,
        uint32 feeBps
    ) external returns (uint dstTokenAmount) {
        require(
            path1[path1.length - 1] == path2[path2.length - 1] &&
                path1[path1.length - 1] == WETH,
            "destination should be WETH"
        );
        address factory = IUniswapV2Pair(lpAdress).factory();
        address pair = lpAdress;
        //* 1. remove liquidity
        //* path1[0] : baseToken , path2[0]: farmToken
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(address(this));
        (address token0, ) = UniswapV2Library.sortTokens(path1[0], path2[0]);
        (uint baseAmount, uint farmAmount) = path1[0] == token0
            ? (amount0, amount1)
            : (amount1, amount0);

        //* 2. swap baseToken -> dstToken, then transfer to to
        uint[] memory amountFromBase = _swapExactTokensForETH(
            factory,
            baseAmount,
            1,
            path1,
            to,
            deadline,
            feeBps
        );
        //* 3. swap farmToken -> dstToken, then transfer to to
        uint[] memory amountFromFarm = _swapExactTokensForETH(
            factory,
            farmAmount,
            1,
            path2,
            to,
            deadline,
            feeBps
        );
        //* dstTokenAmount
        dstTokenAmount =
            amountFromBase[amountFromBase.length - 1] +
            amountFromFarm[amountFromFarm.length - 1];
        require(
            dstTokenAmount >= dstTokenMin,
            "should be more than min-amount"
        );
    }

    /**
     * swap2 = decompose
     */
    function optimalDecomposeAmount(
        uint baseAmount,
        Reserves3 memory reserves
    ) public pure returns (uint112 swapAmount0) {
        uint k1;
        uint sqrtK1;
        bool k1Sign;
        {
            uint k1_left = uint256(reserves.reserveb00) * reserves.reserve011;
            uint k1_right = uint256(reserves.reserveb11) * reserves.reserve010;
            k1Sign = k1_left > k1_right;
            k1 = k1Sign ? k1_left - k1_right : k1_right - k1_left;
            k1 =
                (((k1 * (1e4 - reserves.feeb0Bps)) / 1e4) *
                    (1e4 - reserves.feeb1Bps)) /
                1e4;
            sqrtK1 = Math.sqrt(k1);
        }

        uint B;
        uint C;
        {
            uint k2;
            {
                // k2
                (uint112 x, uint112 y, uint112 z) = sort3(
                    reserves.reserveb0b,
                    reserves.reserveb11,
                    reserves.reserve010
                );
                k2 = (((uint(x) * y) / sqrtK1) * z) / sqrtK1;
            }

            uint k3;
            {
                // k3
                (uint112 u, uint112 v, uint112 w) = sort3(
                    reserves.reserveb00,
                    reserves.reserveb1b,
                    reserves.reserve011
                );

                k3 = (((uint(u) * v) / sqrtK1) * w) / sqrtK1;
            }

            B = (k1Sign ? baseAmount + k2 + k3 : k2 + k3 - baseAmount) / 2;
            C = baseAmount * k2;
        }

        swapAmount0 = k1Sign
            ? uint112(B - Math.sqrt(B * B - C))
            : uint112(Math.sqrt(B * B + C) - B);
    }

    // sort 3 numbers in descending order
    function sort3(
        uint112 a,
        uint112 b,
        uint112 c
    ) internal pure returns (uint112, uint112, uint112) {
        if (a < b) (a, b) = (b, a);
        if (a < c) (a, c) = (c, a);
        if (b < c) (b, c) = (c, b);
        return (a, b, c);
    }

    /********  UTILS  ********/
    function _swapFromSender(
        IUniswapV2Pair pair,
        address tokenIn,
        address tokenOut,
        uint amountIn,
        uint amountOut,
        address to
    ) internal {
        _transferFromSenderOrWrap(tokenIn, address(pair), amountIn);
        if (tokenIn < tokenOut) {
            IUniswapV2Pair(pair).swap(0, amountOut, to, new bytes(0));
        } else {
            IUniswapV2Pair(pair).swap(amountOut, 0, to, new bytes(0));
        }
    }

    function _swap(
        address factory,
        uint[] memory amounts,
        address[] memory path,
        address _to
    ) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = UniswapV2Library.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0
                ? (uint(0), amountOut)
                : (amountOut, uint(0));
            address to = i < path.length - 2
                ? UniswapV2Library.pairFor(factory, output, path[i + 2])
                : _to;
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output))
                .swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function _swapExactTokensForTokens(
        address factory,
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint32 feeBps
    ) internal ensure(deadline) returns (uint[] memory amounts) {
        amounts = UniswapV2Library.getAmountsOut(
            factory,
            amountIn,
            path,
            feeBps
        );

        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        TransferHelper.safeTransfer(
            path[0],
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = UniswapV2Library.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            // console.log(amountOut);
            (uint amount0Out, uint amount1Out) = input == token0
                ? (uint(0), amountOut)
                : (amountOut, uint(0));
            address _to = i < path.length - 2
                ? UniswapV2Library.pairFor(factory, output, path[i + 2])
                : to;
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output))
                .swap(amount0Out, amount1Out, _to, new bytes(0));
        }
    }

    function _swapExactTokensForETH(
        address factory,
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint32 feeBps
    ) internal ensure(deadline) returns (uint[] memory amounts) {
        require(path[path.length - 1] == WETH, "UniswapV2Router: INVALID_PATH");
        amounts = UniswapV2Library.getAmountsOut(
            factory,
            amountIn,
            path,
            feeBps
        );
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        TransferHelper.safeTransfer(
            path[0],
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(factory, amounts, path, address(this));
        IWETH9(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    // 유동성 공급하고 남는양 계산
    function calcRemainedAmount(
        uint112 amount0,
        uint112 amount1,
        uint112 reserve0,
        uint112 reserve1
    ) internal pure returns (uint112 remainedAmount, bool remain0) {
        uint112 amount1Optimal = uint112(
            UniswapV2Library.quote(amount0, reserve0, reserve1)
        );
        if (amount1Optimal <= amount1) {
            // token1이 remained
            remainedAmount = amount1 - amount1Optimal;
        } else {
            uint112 amount0Optimal = uint112(
                UniswapV2Library.quote(amount1, reserve1, reserve0)
            );
            remainedAmount = amount0 - amount0Optimal;
            remain0 = true;
        }
    }

    /**
     *
     * @param pair address of pair(liquidity pool)
     * @param baseToken address of baseToken
     * @param baseAmount amount of baseToken
     * @param farmAmount amount of farmToken
     * @return swapAmount amount to swap
     * @return swappedAmount result amount swapped
     * @return liquidity liquidity minted
     * @return swap0 if true, swap baseToken to farmToken, else swap farmToken to baseToken
     */
    function calculateOptimalRebalanceAmount(
        // address factory,
        IUniswapV2Pair pair,
        address baseToken,
        uint112 baseAmount,
        uint112 farmAmount
    )
        external
        view
        returns (
            uint swapAmount,
            uint swappedAmount,
            uint liquidity,
            bool swap0
        )
    {
        address farmToken = pair.token1() == baseToken
            ? pair.token0()
            : pair.token1();
        baseToken = pair.token0() == baseToken ? pair.token0() : pair.token1();

        (uint112 rBase, uint112 rFarm, ) = pair.getReserves();
        if (baseToken > farmToken) (rBase, rFarm) = (rFarm, rBase);

        address factory = pair.factory();

        uint32 fee = feeOf[factory];
        (swapAmount, swappedAmount, swap0) = optimalSwapAmount(
            baseAmount,
            farmAmount,
            uint112(rBase),
            uint112(rFarm),
            fee
        );

        //* amount0 =  amountOfBaseToken, amount1 = amountOfFarmToken
        if (swap0) {
            baseAmount -= uint112(swapAmount);
            farmAmount += uint112(swappedAmount);
            rBase += uint112(swapAmount);
            rFarm -= uint112(swappedAmount);
        } else {
            baseAmount += uint112(swappedAmount);
            farmAmount -= uint112(swapAmount);
            rBase -= uint112(swappedAmount);
            rFarm += uint112(swapAmount);
        }

        {
            uint _totalSupply = pair.totalSupply();
            liquidity = Math.min(
                (_totalSupply * baseAmount) / rBase,
                (_totalSupply * farmAmount) / rFarm
            );
        }
    }

    // function calculateOptimalRebalanceAmount();
    function calculateOptimalDecomposeAmount(
        address baseToken,
        IUniswapV2Pair farmPair,
        uint112 baseAmount
    )
        external
        view
        returns (
            uint112 swapAmount0,
            uint112 swapAmount1,
            uint112 farmAmount0,
            uint112 farmAmount1,
            uint liquidity,
            uint112 remainedBaseAmount
        )
    {
        address farm0 = farmPair.token0();
        address farm1 = farmPair.token1();
        address factory = farmPair.factory();
        bool swapped;
        if (farm0 > farm1) (farm0, farm1, swapped) = (farm1, farm0, true);

        Reserves3 memory reserves;
        {
            uint32 feeBps = feeOf[factory];
            reserves = Reserves3(0, 0, feeBps, 0, 0, feeBps, 0, 0);
        }
        {
            (uint112 reserveb0b, uint112 reserveb00, ) = IUniswapV2Pair(
                UniswapV2Library.pairFor(factory, baseToken, farm0)
            ).getReserves();
            if (baseToken > farm0)
                (reserveb0b, reserveb00) = (reserveb00, reserveb0b);
            reserves.reserveb0b = reserveb0b;
            reserves.reserveb00 = reserveb00;
        }
        {
            (uint112 reserveb1b, uint112 reserveb11, ) = IUniswapV2Pair(
                UniswapV2Library.pairFor(factory, baseToken, farm1)
            ).getReserves();
            if (baseToken > farm1)
                (reserveb1b, reserveb11) = (reserveb11, reserveb1b);
            reserves.reserveb1b = reserveb1b;
            reserves.reserveb11 = reserveb11;
        }
        {
            (uint112 reserve010, uint112 reserve011, ) = IUniswapV2Pair(
                UniswapV2Library.pairFor(factory, farm0, farm1)
            ).getReserves();
            reserves.reserve010 = reserve010;
            reserves.reserve011 = reserve011;
        }

        swapAmount0 = optimalDecomposeAmount(baseAmount, reserves);
        swapAmount1 = baseAmount - swapAmount0;

        // 1. swap base -> farm0
        farmAmount0 = UniswapV2Library.getAmountOut(
            swapAmount0,
            reserves.reserveb0b,
            reserves.reserveb00,
            reserves.feeb0Bps
        );
        // 2. swap base -> farm1
        farmAmount1 = UniswapV2Library.getAmountOut(
            swapAmount1,
            reserves.reserveb1b,
            reserves.reserveb11,
            reserves.feeb1Bps
        );

        {
            (uint112 remainedFarmAmount, bool remain0) = calcRemainedAmount(
                farmAmount0,
                farmAmount1,
                reserves.reserve010,
                reserves.reserve011
            );

            if (remain0) {
                farmAmount0 -= remainedFarmAmount;
                swapAmount0 = UniswapV2Library.getAmountIn(
                    farmAmount0,
                    reserves.reserveb0b,
                    reserves.reserveb00,
                    reserves.feeb0Bps
                );
            } else {
                farmAmount1 -= remainedFarmAmount;
                swapAmount1 = UniswapV2Library.getAmountIn(
                    farmAmount1,
                    reserves.reserveb1b,
                    reserves.reserveb11,
                    reserves.feeb1Bps
                );
            }
            remainedBaseAmount = baseAmount - swapAmount0 - swapAmount1;
        }

        {
            uint _totalSupply = IUniswapV2Pair(
                UniswapV2Library.pairFor(factory, farm0, farm1)
            ).totalSupply();
            liquidity = (_totalSupply * farmAmount0) / reserves.reserve010;
        }

        if (swapped) (farmAmount0, farmAmount1) = (farmAmount1, farmAmount0);
    }

    function calculateDstAmountByRemoveLiquidity(
        address lpAddress,
        uint liquidity,
        address[] calldata path1,
        address[] calldata path2
    ) external view returns (uint dstAmount) {
        address factory = IUniswapV2Pair(lpAddress).factory();
        address pair = IUniswapV2Factory(factory).getPair(path1[0], path2[0]);
        uint32 feeBps = feeOf[factory];
        (uint112 balance0, uint112 balance1, ) = IUniswapV2Pair(pair)
            .getReserves();

        uint _totalSupply = IUniswapV2Pair(pair).totalSupply();
        //* calculate baseAmount, farmAmount if remove liquidity
        (uint balanceOfBase, uint balanceOfFarm) = (path1[0] < path2[0])
            ? (balance0, balance1)
            : (balance1, balance0);

        uint baseAmount = liquidity.mul(balanceOfBase) / _totalSupply; // using balances ensures pro-rata distribution
        uint farmAmount = liquidity.mul(balanceOfFarm) / _totalSupply;
        console.log("baseAmount: %s, farmAmount: %s", baseAmount, farmAmount);
        //..ok
        //* get baseAmounts, farmAmounts
        uint[] memory baseToDstAmounts = UniswapV2Library.getAmountsOut(
            factory,
            baseAmount,
            path1,
            feeBps
        );
        for (uint i = 0; i < baseToDstAmounts.length; i++) {
            console.log("baseToDstAmounts[%s]: %s", i, baseToDstAmounts[i]);
        }
        uint[] memory farmToDstAmounts = UniswapV2Library.getAmountsOut(
            factory,
            farmAmount,
            path2,
            feeBps
        );
        for (uint i = 0; i < farmToDstAmounts.length; i++) {
            console.log("farmToDstAmounts[%s]: %s", i, farmToDstAmounts[i]);
        }
        dstAmount =
            baseToDstAmounts[baseToDstAmounts.length - 1] +
            farmToDstAmounts[farmToDstAmounts.length - 1];
    }
}
