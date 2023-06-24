import "@openzeppelin/hardhat-upgrades";
import { ethers, network, upgrades } from "hardhat";
import { saveConfig } from "./deploy-ethseoul/use-config";
import mumbai_address from "../config/configs_mumbai.json";
import goerli_address from "../config/configs_goerli.json";
import { deploy } from "@openzeppelin/hardhat-upgrades/dist/utils";
export async function deployUniswapv2Funnel(
  factoryAddress: string,
  WETHaddress: string
) {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying UniswapV2Funnel with Proxy...");
  const UniswapV2Funnel_f = await ethers.getContractFactory("UniswapV2Funnel");
  const UniswapV2Funnel = await upgrades.deployProxy(
    UniswapV2Funnel_f,
    [WETHaddress],
    { initializer: "initialize" }
  );
  await UniswapV2Funnel.deployed();
  saveConfig(`${network.name}__UniswapV2Funnel_Proxy`, UniswapV2Funnel.address);
  console.log("Setting Fee...");
  const tx = await UniswapV2Funnel.setFeeOf(factoryAddress, 30);
  await tx.wait();

  console.log("Confirm Fee...", await UniswapV2Funnel.feeOf(factoryAddress));
  // UniswapV2Funnel implemantation address
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(
    UniswapV2Funnel.address
  );
  saveConfig(`${network.name}__UniswapV2Funnel`, implementationAddress);
}

// deployUniswapv2Funnel(
//   goerli_address.goerli.UniswapV2Factory,
//   goerli_address.goerli.WETH_18
// );
deployUniswapv2Funnel(
  mumbai_address.mumbai.UniswapV2Factory,
  mumbai_address.mumbai.WETH_18
);
