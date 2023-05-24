const hre = require("hardhat");

async function main() {
  const aaContract = await hre.ethers.getContractFactory("ArchetypeAvatars");

  const owner = "0x0417fb78c0aC3fc728C13bE94d606B36f3486A01";

  const treasury = "0xfdAb64Dd15434aFa0F4f13cc89E4D96f62B54232";

  const paymentToken = "0x73A4dC4215Dc3eb6AaE3C7AaFD2514cB34e5D983";

  const aa = await aaContract.deploy(
    "NetvrkArchetypeAvatars",
    "NVKAA",
    "https://api.netvrk.co/api/avatar/archetypes/",
    treasury,
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
