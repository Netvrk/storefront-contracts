import { ethers, upgrades } from "hardhat";
import { StoreFront } from "../typechain-types";

async function main() {
  const sfContract = await ethers.getContractFactory("StoreFront");
  const owner = "0x20eA1E1f04Bdd6B0f0E1Ec0BD6B1E17c0a186C7D";
  const sf = (await upgrades.deployProxy(
    sfContract,
    ["MNT", "MNT", "https://api.example.com/", owner, owner],
    {
      kind: "uups",
    }
  )) as StoreFront;

  await sf.deployed();

  console.log(`StoreFront contract deployed to ${sf.address}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
