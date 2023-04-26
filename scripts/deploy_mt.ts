const hre = require("hardhat");

async function main() {
  const mtContract = await hre.ethers.getContractFactory("MintTiers");
  const owner = "0x39dDcADed26E1B213129C9c1134EE9Fe0e6283bd";

  const mt = await mtContract.deploy("MNT", "MNT", "https://api.example.com/", owner, owner);

  await mt.deployed();

  console.log(`MintTiers contract deployed to ${mt.address}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
