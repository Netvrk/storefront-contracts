import { ethers, upgrades } from "hardhat";
import { StoreFront } from "../typechain-types";

async function main() {
  const sfContract = await ethers.getContractFactory("StoreFront");
  const owner = "0x39dDcADed26E1B213129C9c1134EE9Fe0e6283bd";
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
