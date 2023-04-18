import { time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { Signer } from "ethers";
import { ethers, upgrades } from "hardhat";
import keccak256 from "keccak256";
import MerkleTree from "merkletreejs";
import { ArchetypeAvatars, NRGY } from "../typechain-types";

describe("Archetype Avatars ", function () {
  let aAvatars: ArchetypeAvatars;
  let nrgy: NRGY;
  let owner: Signer;
  let user: Signer;
  let user2: Signer;
  let ownerAddress: string;
  let userAddress: string;
  let user2Address: string;

  let merkleRoot: string;
  let ownerMerkleProof: string[];
  let userMerkeleProof: string[];

  let now: number;

  before(async function () {
    [owner, user, user2] = await ethers.getSigners();
    ownerAddress = await owner.getAddress();
    userAddress = await user.getAddress();
    user2Address = await user2.getAddress();

    // Merkle root and proof for the owner and user addresses
    const leaves = [ownerAddress, userAddress].map((x) => keccak256(x));
    const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });

    merkleRoot = "0x" + tree.getRoot().toString("hex");
    ownerMerkleProof = tree.getHexProof(keccak256(ownerAddress));
    userMerkeleProof = tree.getHexProof(keccak256(userAddress));

    now = await time.latest();
  });

  it("Deployment", async function () {
    const nrgyContract = await ethers.getContractFactory("NRGY");
    nrgy = await nrgyContract.deploy();
    await nrgy.deployed();

    const aAvatarsContract = await ethers.getContractFactory(
      "ArchetypeAvatars"
    );

    aAvatars = (await upgrades.deployProxy(
      aAvatarsContract,
      [
        "MNT",
        "MNT",
        "https://api.example.com/",
        ownerAddress,
        ownerAddress,
        nrgy.address,
      ],
      {
        kind: "uups",
      }
    )) as ArchetypeAvatars;

    await aAvatars.deployed();
  });

  it("Setup contract", async function () {
    await expect(aAvatars.connect(user).setBaseURI("https://api.example.com/"))
      .to.be.reverted;
    await expect(
      aAvatars.connect(user).setContractURI("https://api.example.com/contract")
    ).to.be.reverted;
    await expect(aAvatars.connect(user).setDefaultRoyalty(ownerAddress, 1000))
      .to.be.reverted;
    await aAvatars.setBaseURI("https://api.example.com/");
    await aAvatars.setContractURI("https://api.example.com/contract");
    await aAvatars.setDefaultRoyalty(ownerAddress, 1000);
    expect(await aAvatars.contractURI()).to.be.equal(
      "https://api.example.com/contract"
    );
    const royaltyAmount = ethers.utils.formatEther(
      (await aAvatars.royaltyInfo(1, ethers.utils.parseEther("1")))[1]
    );
    expect(royaltyAmount, "0.1");
    expect(await aAvatars.treasury()).to.be.equal(ownerAddress);
  });

  it("Initialize Tier", async function () {
    await expect(
      aAvatars.connect(user).initTier(1, ethers.utils.parseEther("1"), 20, 2, 5)
    ).to.be.reverted;

    await expect(aAvatars.tiers(6)).to.be.revertedWith("TIER_UNAVAILABLE");

    await expect(
      aAvatars.initTier(101, ethers.utils.parseEther("1"), 20, 2, 5)
    ).to.be.revertedWith("TIER_UNAVAILABLE");
    await expect(
      aAvatars.initTier(1, ethers.utils.parseEther("1"), 0, 2, 5)
    ).to.be.revertedWith("INVALID_SUPPLY");

    await expect(
      aAvatars.initTier(1, ethers.utils.parseEther("1"), 20, 0, 5)
    ).to.be.revertedWith("INVALID_MAX_PER_TX");

    await expect(
      aAvatars.initTier(1, ethers.utils.parseEther("1"), 20, 2, 0)
    ).to.be.revertedWith("INVALID_MAX_PER_WALLET");

    await aAvatars.initTier(1, ethers.utils.parseEther("1"), 20, 2, 5);

    await aAvatars.initTier(2, ethers.utils.parseEther("0"), 20, 2, 5);

    await aAvatars.initTier(3, ethers.utils.parseEther("1"), 20, 2, 5);

    await aAvatars.initTier(4, ethers.utils.parseEther("1"), 20, 2, 5);

    await expect(
      aAvatars.initTier(1, ethers.utils.parseEther("1"), 20, 2, 5)
    ).to.be.revertedWith("TIER_ALREADY_INITIALIZED");

    expect((await aAvatars.totalTiers()).toNumber()).to.be.equal(4);

    const tier1 = await aAvatars.tiers(1);
    expect(tier1.price).to.be.equal(ethers.utils.parseEther("1"));
  });

  it("Withdraw", async function () {
    const balance = await owner.getBalance();
    await aAvatars.withdraw();
    const balance2 = await owner.getBalance();
    expect(balance2.toString()).to.not.equal(balance.toString());
    await expect(aAvatars.withdraw()).to.be.revertedWith("ZERO_BALANCE");
  });
});
