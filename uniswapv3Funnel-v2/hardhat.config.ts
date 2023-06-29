import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

import dotenv from "dotenv";
dotenv.config();
const SH_PK: string = process.env.SH!;
const SH_PK2: string = process.env.SH2!;
const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.7.6",
        settings: {
          viaIR: true,
          optimizer: {
            enabled: true,
            runs: 3000,
          },
        },
      },
      {
        version: "0.8.18",

        settings: {
          optimizer: {
            enabled: true,
            runs: 3000,
          },
          viaIR: true,
        },
      },
    ],

    overrides: {
      "contracts/uniswapV2/core": {
        version: "0.5.16",
      },
      "contracts/uniswapV2/periphery": {
        version: "0.6.6",
      },
      "libraries/PoolAddress.sol": { version: "0.5.16" },
    },
  },

  networks: {
    // hardhat: {
    //   forking: {
    //     url: "https://public-01.testnet.thebifrost.io/rpc",
    //   }
    // },

    baobab: {
      url: "https://api.baobab.klaytn.net:8651",
      accounts: [SH_PK],
    },
    bifrost_testnet: {
      chainId: 49088,
      url: "https://public-01.testnet.thebifrost.io/rpc",
      accounts: [SH_PK],
    },
    ethereum: {
      chainId: 1,
      url: "https://eth.llamarpc.com",
      accounts: [SH_PK],
    },
    bsc: {
      chainId: 56,
      url: "https://bsc.blockpi.network/v1/rpc/public",
      accounts: [SH_PK],
    },
    polygon: {
      chainId: 137,
      url: "https://polygon.llamarpc.com",
      accounts: [SH_PK],
    },
    goerli: {
      chainId: 5,
      url: "https://goerli.blockpi.network/v1/rpc/public",
      accounts: [SH_PK2],
    },
    matic: {
      chainId: 137,
      url: "https://polygon.llamarpc.com",
      accounts: [SH_PK],
    },
    mumbai: {
      chainId: 80001,
      url: "https://polygon-mumbai-bor.publicnode.com",
      accounts: [SH_PK],
      gasPrice: 80000000000,
    },
    tbsc: {
      chainId: 97,
      url: "https://data-seed-prebsc-1-s2.binance.org:8545",
      accounts: [SH_PK],
    },
    chiado: {
      chainId: 10200,
      url: "https://rpc.chiadochain.net",
      accounts: [SH_PK],
      gasPrice: 1000000000,
    },
    sepolia: {
      chainId: 11155111,
      url: "https://rpc.sepolia.org",
      accounts: [SH_PK],
    },
    aurora_test: {
      chainId: 1313161555,
      url: "https://testnet.aurora.dev",
      accounts: [SH_PK2],
      gasPrice: 100000000000,
    },
  },
};

export default config;
