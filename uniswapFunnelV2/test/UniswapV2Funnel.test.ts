import { BigNumberish } from "ethers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { deployFixture } from "../scripts/deploy";
import { UniswapV2Factory, UniswapV2Funnel, token } from "../typechain-types";

let addressBook: Awaited<ReturnType<typeof deployFixture>>;
let funnel: UniswapV2Funnel;
const { parseEther, formatEther } = ethers.utils;

describe("UniswapV2Funnel", function () {
  const balanceOf = async (tokenAddress: string, account: string) => {
    if (tokenAddress === addressBook.WETH) {
      return ethers.provider.getBalance(account);
    } else {
      const token = await ethers.getContractAt("IUniswapV2ERC20", tokenAddress);
      return token.balanceOf(account);
    }
  };
  const approve = async (
    tokenAddress: string,
    spender: string,
    amount: BigNumberish
  ) => {
    const token = await ethers.getContractAt("IUniswapV2ERC20", tokenAddress);
    return token.approve(spender, amount).then((tx) => tx.wait());
  };

  it("Deploy Fixtures", async function () {
    addressBook = await deployFixture();
  });

  it("deploy UniswapV2Funnel", async function () {
    const [deployer] = await ethers.getSigners();
    const funnelFactory = await ethers.getContractFactory("UniswapV2Funnel");
    funnel = await funnelFactory
      .deploy(addressBook.WETH)
      .then((f) => f.deployed());

    const tx = await funnel.setFeeOf(addressBook.factory, 30);
    await tx.wait();

    expect(await funnel.feeOf(addressBook.factory)).to.equal(30);
    expect(await funnel.owner()).to.equal(deployer.address);
  });

  for (const [_base, _farm0, _farm1] of [
    [0, 1, 2],
    [1, 2, 0],
    [2, 0, 1],
  ]) {
    it(`decomposeAndAddLiquidity: BASE ${_base} + FARM ${_farm0}, ${_farm1}`, async function () {
      let gasUsed = 0;

      const tokens = [
        // addressBook.WETH,
        addressBook.token0,
        addressBook.token1,
        addressBook.token2,
      ];
      const [deployer] = await ethers.getSigners();

      const amountIn0 = parseEther("1");

      if (tokens[_base] !== addressBook.WETH) {
        await approve(tokens[_base], funnel.address, amountIn0);
      }

      const lpAddress = await ethers
        .getContractAt("IUniswapV2Factory", addressBook.factory)
        .then((f) => f.getPair(tokens[_farm0], tokens[_farm1]));
      const expected = await funnel.calculateOptimalDecomposeAmount(
        tokens[_base],
        lpAddress,
        amountIn0
      );

      const beforeLpBalance = await balanceOf(lpAddress, deployer.address);
      const beforeBaseBalance = await balanceOf(
        tokens[_base],
        deployer.address
      );

      const tx = await funnel.decomposeAndAddLiquidity(
        tokens[_base],
        lpAddress,
        deployer.address,
        amountIn0,
        { value: tokens[_base] === addressBook.WETH ? amountIn0 : 0 }
      );

      const receipt = await tx.wait();

      const afterLpBalance = await balanceOf(lpAddress, deployer.address);
      const afterBaseBalance = await balanceOf(tokens[_base], deployer.address);

      expect(afterLpBalance.sub(beforeLpBalance)).to.eq(expected.liquidity);
      if (tokens[_base] === addressBook.WETH) {
        const usedBaseAmount = expected.remainedBaseAmount.sub(
          tx.gasPrice!.mul(receipt.gasUsed)
        );
        expect(afterBaseBalance.sub(beforeBaseBalance).add(amountIn0)).eq(
          usedBaseAmount
        );
      } else {
        expect(afterBaseBalance.sub(beforeBaseBalance).add(amountIn0)).eq(
          expected.remainedBaseAmount
        );
      }
    });
  }

  const [_base, _farm] = [0, 1];
  it(`partitionAndAddLiquidity: BASE ${_base} + FARM ${_farm}`, async function () {
    const tokens = [addressBook.token0, addressBook.token1, addressBook.token2];
    const [deployer] = await ethers.getSigners();

    const amountInBase = parseEther("3");
    await approve(tokens[_base], funnel.address, amountInBase);

    const lpAddress = await ethers
      .getContractAt("IUniswapV2Factory", addressBook.factory)
      .then((f) => f.getPair(tokens[_base], tokens[_farm]));
    const expected = await funnel.calculateOptimalRebalanceAmount(
      lpAddress,
      tokens[_base],
      amountInBase,
      "0"
    );
    const beforeLpBalance = await balanceOf(lpAddress, deployer.address);
    const beforeBaseBalance = await balanceOf(tokens[_base], deployer.address);
    const tx = await funnel.partitionAndAddLiquidity(
      lpAddress,
      tokens[_base],
      deployer.address,
      amountInBase,
      {
        value:
          tokens[_base] === addressBook.WETH
            ? amountInBase
            : ethers.constants.Zero,
      }
    );
    await tx.wait();
    const afterLpBalance = await balanceOf(lpAddress, deployer.address);
    const afterBaseBalance = await balanceOf(tokens[_base], deployer.address);
    expect(afterLpBalance.sub(beforeLpBalance)).to.eq(expected.liquidity);
    expect(beforeBaseBalance.sub(afterBaseBalance)).to.eq(amountInBase);
  });

  it(`rebalanceAndAddLiquidity: BASE ${_base} + FARM ${_farm}`, async function () {
    const tokens = [addressBook.token0, addressBook.token1, addressBook.token2];
    const [deployer] = await ethers.getSigners();

    const amountInBase = parseEther("3");
    const amountInFarm = parseEther("4");
    await approve(tokens[_base], funnel.address, amountInBase);
    await approve(tokens[_farm], funnel.address, amountInFarm);

    const lpAddress = await ethers
      .getContractAt("IUniswapV2Factory", addressBook.factory)
      .then((f) => f.getPair(tokens[_base], tokens[_farm]));
    const expected = await funnel.calculateOptimalRebalanceAmount(
      lpAddress,
      tokens[_base],
      amountInBase,
      amountInFarm
    );
    const beforeLpBalance = await balanceOf(lpAddress, deployer.address);
    const beforeBaseBalance = await balanceOf(tokens[_base], deployer.address);
    const beforeFarmBalance = await balanceOf(tokens[_farm], deployer.address);
    const tx = await funnel.rebalanceAndAddLiquidity(
      lpAddress,
      tokens[_base],
      deployer.address,
      amountInBase,
      amountInFarm,
      {
        value:
          tokens[_base] === addressBook.WETH
            ? amountInBase
            : tokens[_farm] === addressBook.WETH
            ? amountInFarm
            : ethers.constants.Zero,
      }
    );
    await tx.wait();
    const afterLpBalance = await balanceOf(lpAddress, deployer.address);
    const afterBaseBalance = await balanceOf(tokens[_base], deployer.address);
    const afterFarmBalance = await balanceOf(tokens[_farm], deployer.address);

    expect(afterLpBalance.sub(beforeLpBalance)).to.eq(expected.liquidity);
    expect(beforeBaseBalance.sub(afterBaseBalance)).to.eq(amountInBase);
    expect(beforeFarmBalance.sub(afterFarmBalance)).to.eq(amountInFarm);
  });

  it("partition", async function () {
    const [deployer] = await ethers.getSigners();
    const tokens = [addressBook.token0, addressBook.token1, addressBook.token2];
    await approve(addressBook.token0, funnel.address, parseEther("1"));
    const lpAddress = await ethers
      .getContractAt("IUniswapV2Factory", addressBook.factory)
      .then((f) => f.getPair(tokens[_base], tokens[_farm]));
    await funnel.partitionAndAddLiquidity(
      lpAddress,
      addressBook.token0,
      deployer.address,
      parseEther("1"),
      { value: parseEther("1") }
    );
  });
  it("removeLiquidity", async function () {
    const [deployer] = await ethers.getSigners();
    const tokens = [addressBook.token0, addressBook.token1, addressBook.token2];
    const lpAddress = await ethers
      .getContractAt("IUniswapV2Factory", addressBook.factory)
      .then((f) => f.getPair(tokens[0], tokens[1]));

    const beforeLpBalance = await balanceOf(lpAddress, deployer.address);
    const token2BeforeBalance = await balanceOf(tokens[2], deployer.address);
    console.log("beforeLpBalance:", ethers.utils.formatEther(beforeLpBalance));
    console.log(
      "beforetoken2Balance:",
      ethers.utils.formatEther(token2BeforeBalance)
    );

    const path1 = [addressBook.token0, addressBook.token2];
    const path2 = [addressBook.token1, addressBook.token2];
    await approve(lpAddress, funnel.address, beforeLpBalance);
    const LPToken = await ethers.getContractAt("UniswapV2Pair", lpAddress);

    const dstExpectedToken2Amount =
      await funnel.calculateDstAmountByRemoveLiquidity(
        lpAddress,
        beforeLpBalance,
        path1,
        path2
      );
    console.log(
      "dstExpectedToken2Amount:",
      ethers.utils.formatEther(dstExpectedToken2Amount)
    );
    await approve(LPToken.address, funnel.address, beforeLpBalance);
    await funnel
      .removeLiquidityAndSwapToDstToken(
        lpAddress,
        beforeLpBalance,
        deployer.address,
        path1,
        path2,
        1,
        ethers.constants.MaxUint256
      )
      .then((tx) => tx.wait());

    const dstToken2Amount = (await balanceOf(tokens[2], deployer.address)).sub(
      token2BeforeBalance
    );
    expect(dstToken2Amount).to.eq(dstExpectedToken2Amount);
    const afterLpBalance = await balanceOf(lpAddress, deployer.address);
    const token2AfterBalance = await balanceOf(tokens[2], deployer.address);
    console.log("afterLpBalance:", ethers.utils.formatEther(afterLpBalance));
    console.log(
      "aftertoken2Balance:",
      ethers.utils.formatEther(token2AfterBalance)
    );
  });
});
