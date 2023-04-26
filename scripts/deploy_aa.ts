const hre = require("hardhat");

async function main() {
  const aaContract = await hre.ethers.getContractFactory("ArchetypeAvatars");
  const owner = "0x08c3405ba60f9263Ec18d20959D1c39F9dff4b4b";
  const paymentToken = "0x34562283739db04b7eB67521BFb5C9118F0C0844";

  const aa = await aaContract.deploy(
    "AA",
    "AA",
    "https://api.example.com/",
    owner,
    owner,
    paymentToken
  );

  await aa.deployed();

  console.log(`ArchetypeAvatars contract deployed to ${aa.address}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
