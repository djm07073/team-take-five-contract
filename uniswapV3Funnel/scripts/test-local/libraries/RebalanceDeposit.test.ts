import { ethers } from "hardhat";

import {
  ISwapRouter,
  IWETH9,
  RebalanceDepositTest,
  RebalanceDepositTest__factory,
} from "../../typechain-types";
import { IUniswapV3Pool } from "../../typechain-types/contracts/interfaces";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/src/signers";
const POOLADDRESS_MATIC_WETH: string =
  "0x290A6a7460B308ee3F19023D2D00dE604bcf5B42";
const SWAP_ROUTER: string = "0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45";
const WETH_ADDRESS: string = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";
describe("Rebalance Deposit", function () {
  let pool: string;
  let SwapRouter: ISwapRouter;
  let UniswapV3Pool: IUniswapV3Pool;
  let token0: string;
  let token1: string;
  let rebalanceDeposit: RebalanceDepositTest;
  let WETH: IWETH9;
  let signer: SignerWithAddress;
  let tickCurrent: bigint;
  const setting = async (_pool: string, _fee: number) => {
    pool = _pool;
    UniswapV3Pool = await ethers.getContractAt("IUniswapV3Pool", pool);
    const { sqrtPriceX96, tick } = await UniswapV3Pool.slot0();
    tickCurrent = tick;
    token0 = await UniswapV3Pool.token0(); // WETH:  "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    token1 = await UniswapV3Pool.token1(); // MATIC:  "0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0"
    console.log("Wrapping ETH");
    await WETH.deposit({ value: ethers.parseEther("50") });
    console.log(" Swap WETH to MATIC");

    const sqrtPriceX96Upper: bigint = sqrtPriceX96 * BigInt(1.1);
    const sqrtPriceX96Lower: bigint = sqrtPriceX96 * BigInt(0.9);
    return { sqrtPriceX96Lower, sqrtPriceX96Upper, token0 };
  };

  before("Setting", async function () {
    console.log("Set Swap Router");
    const [signer] = await ethers.getSigners();
    SwapRouter = await ethers.getContractAt("ISwapRouter", SWAP_ROUTER);
    WETH = await ethers.getContractAt("IWETH9", WETH_ADDRESS);
    it("Swap WETH to MATIC", async function () {
      SwapRouter.exactInputSingle({
        tokenIn: token1,
        tokenOut: token0,
        fee: 3000,
        recipient: signer,
        deadline: 1514739398841430622086649900n,
        amountIn: ethers.parseEther("1"),
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      });
    });
  });

  it('test function rebalanceDeposit() with WETH - MATIC Pool , fee = "0.3%"', function () {
    let fee: number = 3000;
    let sqrtPriceX96Upper: bigint;
    let sqrtPriceX96Lower: bigint;
    it("Setting Upper Price & Lower Price of Pool", async function () {
      const { sqrtPriceX96Lower, sqrtPriceX96Upper } = await setting(
        POOLADDRESS_MATIC_WETH,
        3000
      );
      const rebalanceDeposit_f = await ethers.getContractFactory(
        "RebalanceDepositTest"
      );
      const rebalanceDeposit = await rebalanceDeposit_f.deploy();
      await rebalanceDeposit.waitForDeployment();
      console.log(
        "rebalanceDeposit deployed to:",
        await rebalanceDeposit.getAddress()
      );
    });
    it("Test Rebalance Deposit Test", async function () {
      const amountX = ethers.parseEther("1");
      const amountY = ethers.parseEther("1");
      const t = await rebalanceDeposit.rebalanceDepositTest(
        pool,
        sqrtPriceX96Lower,
        sqrtPriceX96Upper,
        amountX,
        amountY
      );
      console.log("Base Amount , isSwapX ", t.baseAmount, t.isSwapX);
      if (t.isSwapX) {
        console.log("Swap X to Y");
        await SwapRouter.exactInputSingle({
          tokenIn: token0,
          tokenOut: token1,
          fee: fee,
          recipient: signer.address,
          deadline: 1514739398841430622086649900,
          amountIn: t.baseAmount,
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0,
        });
      } else {
        console.log("Swap Y to X");
        await SwapRouter.exactInputSingle({
          tokenIn: token1,
          tokenOut: token0,
          fee: fee,
          recipient: signer.address,
          deadline: 1514739398841430622086649900n,
          amountIn: t.baseAmount,
          amountOutMinimum: 1,
          sqrtPriceLimitX96: 0,
        });
      }
    });
  });

  it("test WETH - MATIC Pool , fee = 0.05%", async function () {});
});
