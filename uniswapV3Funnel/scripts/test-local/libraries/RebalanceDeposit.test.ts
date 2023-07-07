import { ethers } from "hardhat";

import {
  ISwapRouter,
  IUniswapV3Pool,
  IWETH9,
  RebalanceDepositTest,
  RebalanceDepositTest__factory,
} from "../../../typechain-types";

import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/src/signers";

const POOLADDRESS_MATIC_WETH: string =
  "0x290A6a7460B308ee3F19023D2D00dE604bcf5B42";
const SWAP_ROUTER: string = "0xE592427A0AEce92De3Edee1F18E0157C05861564";
const WETH_ADDRESS: string = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";

const setting = async (
  _pool: string,
  _weth: string,
  _swapRouter: string,
  upper: bigint,
  lower: bigint
) => {
  const UniswapV3Pool: IUniswapV3Pool = await ethers.getContractAt(
    "IUniswapV3Pool",
    _pool
  );
  const token0: string = await UniswapV3Pool.token0(); // MATIC:  "0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0"
  const token1: string = await UniswapV3Pool.token1(); // WETH:  "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
  const [signer] = await ethers.getSigners();

  console.log("Wrapping ETH");
  const WETH: IWETH9 = await ethers.getContractAt("IWETH9", _weth);
  await WETH.deposit({ value: ethers.parseEther("2000") }).then((tx) =>
    tx.wait()
  );
  console.log(
    "User's balance of WETH, ETH:",
    ethers.formatEther(await WETH.balanceOf(signer.address)),
    ethers.formatEther(await signer.provider.getBalance(signer.address))
  );
  console.log("Set Swap Router");
  const SwapRouter: ISwapRouter = await ethers.getContractAt(
    "ISwapRouter",
    SWAP_ROUTER
  );

  await WETH.approve(SWAP_ROUTER, ethers.MaxUint256).then((tx) => tx.wait());

  console.log("Swap WETH to MATIC");

  await SwapRouter.exactInputSingle({
    tokenIn: WETH_ADDRESS,
    tokenOut: token0,
    fee: 3000,
    recipient: signer.address,
    deadline: ethers.MaxUint256,
    amountIn: ethers.parseEther("1000"),
    amountOutMinimum: 0,
    sqrtPriceLimitX96: 0,
  }).then((tx) => tx.wait());
  const { sqrtPriceX96, tick } = await UniswapV3Pool.slot0();
  const tickCurrent: bigint = tick;

  // console.log("Swap WETH to token1");
  const tickUpper: bigint = tick + upper;
  const tickLower: bigint = tick - lower;
  return {
    SwapRouter,
    UniswapV3Pool,
    WETH,
    tick,
    tickLower,
    tickUpper,
    token0,
    token1,
  };
};
async function test(
  _pool: string,
  _weth: string,
  _swapRouter: string,
  fee: number
) {
  console.log("Setting up Test Environment");
  let {
    SwapRouter: swapRouter,
    UniswapV3Pool: UniswapV3Pool,
    WETH: weth,
    tick: tick,
    tickLower: tickLower,
    tickUpper: tickUpper,
    token0: token0,
    token1: token1,
  } = await setting(_pool, _weth, _swapRouter, 2000n, 1000n);
  console.log("Signer");
  const [signer] = await ethers.getSigners();
  console.log("Test function rebalanceDeposit()");
  const rebalanceDeposit_f = await ethers.getContractFactory(
    "RebalanceDepositTest"
  );
  const rebalanceDeposit = await rebalanceDeposit_f
    .deploy()
    .then((t) => t.waitForDeployment());

  console.log(
    "RebalanceDeposit deployed to:",
    await rebalanceDeposit.getAddress()
  );

  console.log("Test Rebalance Deposit Test");
  tick = await UniswapV3Pool.slot0().then((t) => t.tick);
  const { baseAmount, isSwapX } = await rebalanceDeposit.rebalanceDepositTest(
    _pool,
    tickUpper,
    tickLower,
    ethers.parseEther("10"),
    ethers.parseEther("10")
  );
  console.log("Base Amount , isSwapX ", baseAmount, isSwapX);
  if (isSwapX) {
    console.log("Swap X to Y");
    await swapRouter.exactInputSingle({
      tokenIn: token0,
      tokenOut: token1,
      fee: fee,
      recipient: signer.address,
      deadline: 1514739398841430622086649900n,
      amountIn: baseAmount,
      amountOutMinimum: 1,
      sqrtPriceLimitX96: 0,
    });
  } else {
    console.log("Swap Y to X");
    await swapRouter.exactInputSingle({
      tokenIn: token1,
      tokenOut: token0,
      fee: fee,
      recipient: signer.address,
      deadline: 1514739398841430622086649900n,
      amountIn: baseAmount,
      amountOutMinimum: 1,
      sqrtPriceLimitX96: 0,
    });
  }
}

test(POOLADDRESS_MATIC_WETH, WETH_ADDRESS, SWAP_ROUTER, 3000);
