import { time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { Signer } from "ethers";
import { ethers } from "hardhat";
import keccak256 from "keccak256";
import MerkleTree from "merkletreejs";
import { ArchetypeAvatars, NRGY } from "../typechain-types";

describe("Archetype Avatars ", function () {
  let avatar: ArchetypeAvatars;
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

    // Transfer tokens to users
    await nrgy.transfer(userAddress, ethers.utils.parseEther("1000"));
    await nrgy.transfer(user2Address, ethers.utils.parseEther("1000"));

    const aAvatarsContract = await ethers.getContractFactory(
      "ArchetypeAvatars"
    );

    avatar = (await aAvatarsContract.deploy(
      "MNT",
      "MNT",
      "https://api.example.com/",
      ownerAddress,
      ownerAddress,
      nrgy.address
    )) as ArchetypeAvatars;

    await avatar.deployed();

    // Approve avatar contract to spend NRGY
    await nrgy.approve(avatar.address, ethers.utils.parseEther("1000"));
    await nrgy
      .connect(user)
      .approve(avatar.address, ethers.utils.parseEther("1000"));
    await nrgy
      .connect(user2)
      .approve(avatar.address, ethers.utils.parseEther("1000"));
  });

  it("Setup contract", async function () {
    await expect(avatar.connect(user).setBaseURI("https://api.example.com/")).to
      .be.reverted;
    await expect(
      avatar.connect(user).setContractURI("https://api.example.com/contract")
    ).to.be.reverted;
    await expect(avatar.connect(user).setDefaultRoyalty(ownerAddress, 1000)).to
      .be.reverted;
    await avatar.setBaseURI("https://api.example.com/");
    await avatar.setContractURI("https://api.example.com/contract");
    await avatar.setDefaultRoyalty(ownerAddress, 1000);
    expect(await avatar.contractURI()).to.be.equal(
      "https://api.example.com/contract"
    );
    const royaltyAmount = ethers.utils.formatEther(
      (await avatar.royaltyInfo(1, ethers.utils.parseEther("1")))[1]
    );
    expect(royaltyAmount, "0.1");
    expect(await avatar.treasury()).to.be.equal(ownerAddress);
  });

  it("Initialize Tier", async function () {
    await expect(
      avatar.connect(user).initTier(1, ethers.utils.parseEther("1"), 20, 2, 5)
    ).to.be.reverted;

    await expect(avatar.tiers(6)).to.be.revertedWith("TIER_UNAVAILABLE");

    await expect(
      avatar.initTier(101, ethers.utils.parseEther("1"), 20, 2, 5)
    ).to.be.revertedWith("TIER_UNAVAILABLE");
    await expect(
      avatar.initTier(1, ethers.utils.parseEther("1"), 0, 2, 5)
    ).to.be.revertedWith("INVALID_SUPPLY");

    await expect(
      avatar.initTier(1, ethers.utils.parseEther("1"), 20, 0, 5)
    ).to.be.revertedWith("INVALID_MAX_PER_TX");

    await expect(
      avatar.initTier(1, ethers.utils.parseEther("1"), 20, 2, 0)
    ).to.be.revertedWith("INVALID_MAX_PER_WALLET");

    await avatar.initTier(1, ethers.utils.parseEther("1"), 20, 2, 5);

    await avatar.initTier(2, ethers.utils.parseEther("0"), 20, 2, 5);

    await avatar.initTier(3, ethers.utils.parseEther("1"), 20, 2, 5);

    await avatar.initTier(4, ethers.utils.parseEther("1"), 20, 2, 5);

    await expect(
      avatar.initTier(1, ethers.utils.parseEther("1"), 20, 2, 5)
    ).to.be.revertedWith("TIER_ALREADY_INITIALIZED");

    expect((await avatar.totalTiers()).toNumber()).to.be.equal(4);

    const tier1 = await avatar.tiers(1);
    expect(tier1.price).to.be.equal(ethers.utils.parseEther("1"));
  });

  it("Phase 1", async function () {
    const startTime = now;
    const endTime = now + 1000;
    await avatar.initPhase1(
      1,
      [ownerAddress, userAddress],
      [1, 2],
      startTime,
      endTime
    );
    expect(await avatar.isSaleActive(1, 1)).to.be.true;

    await avatar.mintPhase1(1, 1);
    await avatar.connect(user).mintPhase1(1, 1);
    await avatar.connect(user).mintPhase1(1, 1);
    await expect(avatar.connect(user2).mintPhase1(1, 1)).to.be.revertedWith(
      "USER_NOT_WHITELISTED"
    );
    await expect(avatar.connect(user).mintPhase1(1, 1)).to.be.revertedWith(
      "MAX_MINT_EXCEEDED"
    );
    await expect(avatar.connect(user).mintPhase1(1, 1)).to.be.revertedWith(
      "MAX_MINT_EXCEEDED"
    );

    now = await time.increase(2000);
    await expect(avatar.connect(user).mintPhase1(1, 1)).to.be.revertedWith(
      "SALE_NOT_ACTIVE"
    );
  });

  it("Phase 2", async function () {
    const startTime = now;
    const endTime = now + 1000;

    await avatar.initPhase2(
      1,
      [ownerAddress, userAddress],
      [1, 3],
      [30, 20],
      startTime,
      endTime
    );

    expect(await avatar.isSaleActive(1, 2)).to.be.true;

    await avatar.mintPhase2(1, 1);
    await avatar.connect(user).mintPhase2(1, 1);
    await avatar.connect(user).mintPhase2(1, 2);
    await expect(avatar.connect(user2).mintPhase2(1, 1)).to.be.revertedWith(
      "USER_NOT_WHITELISTED"
    );
    await expect(avatar.connect(user).mintPhase2(1, 1)).to.be.revertedWith(
      "MAX_MINT_EXCEEDED"
    );
    await expect(avatar.connect(user).mintPhase2(1, 1)).to.be.revertedWith(
      "MAX_MINT_EXCEEDED"
    );

    now = await time.increase(2000);
    await expect(avatar.connect(user).mintPhase2(1, 1)).to.be.revertedWith(
      "SALE_NOT_ACTIVE"
    );
  });

  it("Add Promo Code", async function () {
    await avatar.updatePromoCode(1, "xyz", ownerAddress, 12, 10, 5, true);
    expect((await avatar.promoCodeInfo("xyz")).active).to.be.true;
  });

  it("Phase 3", async function () {
    const startTime = now;
    const endTime = now + 1000;
    await avatar.initPhase3(
      1,
      [ownerAddress, userAddress],
      startTime,
      endTime,
      4,
      2
    );

    await avatar.mintPhase3(1, 1, "xyz");
    await expect(avatar.mintPhase3(1, 2, "abc")).to.be.revertedWith(
      "PROMO_NOT_ACTIVE"
    );
    await expect(avatar.mintPhase3(1, 2, "xyz")).to.be.revertedWith(
      "MAX_PER_WALLET_EXCEEDED"
    );

    await avatar.mintPhase3(1, 1, "");
  });

  it("Remove Promo Code", async function () {
    await avatar.updatePromoCode(
      0,
      "xyz",
      ethers.constants.AddressZero,
      0,
      0,
      0,
      false
    );

    await expect(avatar.mintPhase3(1, 2, "xyz")).to.be.revertedWith(
      "PROMO_NOT_ACTIVE"
    );

    expect((await avatar.promoCodeInfo("xyz")).active).to.be.false;
  });

  it("Phase 4", async function () {
    await avatar.updatePromoCode(1, "abc", ownerAddress, 12, 10, 5, true);

    const startTime = now;
    const endTime = now + 1000;
    await avatar.initPhase4(1, startTime, endTime, 20, 7, 2);

    await avatar.connect(user).mintPhase4(1, 1, "abc");

    await avatar.connect(user).mintPhase4(1, 1, "");
  });

  it("Withdraw", async function () {
    const balance = await owner.getBalance();
    await avatar.withdraw();
    const balance2 = await owner.getBalance();
    expect(balance2.toString()).to.not.equal(balance.toString());
    await expect(avatar.withdraw()).to.be.revertedWith("ZERO_BALANCE");
  });
});
