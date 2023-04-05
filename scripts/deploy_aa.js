const hre = require("hardhat");

async function main() {
  const aaContract = await hre.ethers.getContractFactory("ArchetypeAvatars");
  const owner = "0x39dDcADed26E1B213129C9c1134EE9Fe0e6283bd";
  const paymentToken = "0x39dDcADed26E1B213129C9c1134EE9Fe0e6283bd"

  const aa = await aaContract.deploy("AA", "AA", "https://api.example.com/", owner, owner, paymentToken);

  await aa.deployed();

  console.log(`ArchetypeAvatars contract deployed to ${aa.address}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
