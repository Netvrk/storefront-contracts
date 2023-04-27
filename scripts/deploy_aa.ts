const hre = require("hardhat");

async function main() {
  const aaContract = await hre.ethers.getContractFactory("ArchetypeAvatars");
  const owner = "0xF3d66FFc6E51db57A4d8231020F373A14190567F";
  const paymentToken = "0xF5B84B4F60F47616e79d7a46d43706B90AdD1e56";

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
