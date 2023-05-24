import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import dotenv from "dotenv";
import { HardhatUserConfig } from "hardhat/config";
import "solidity-coverage";

dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.17",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    goerli: {
      url: process.env.GOERLI_URL || "",
      accounts:
        process.env.PRIVATE_KEY_1 !== undefined
          ? [process.env.PRIVATE_KEY_1]
          : [],
    },
    mumbai: {
      url: process.env.MUMBAI_URL || "",
      accounts:
        process.env.PRIVATE_KEY_1 !== undefined
          ? [process.env.PRIVATE_KEY_1]
          : [],
    },
    polygon: {
      url: process.env.POLYGON_URL || "",
      accounts:
        process.env.PRIVATE_KEY_1 !== undefined
          ? [process.env.PRIVATE_KEY_1]
          : [],
      // gasPrice: 100,
    },
  },
  gasReporter: {
    enabled: false,
    currency: "USD",
    gasPrice: 21,
  },
  etherscan: {
    // apiKey: process.env.ETHERSCAN_API_KEY || "",
    apiKey: process.env.POLYGON_API_KEY || "",
  },
};

export default config;
