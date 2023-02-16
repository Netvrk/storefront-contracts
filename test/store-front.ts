import { time } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { Signer } from "ethers";
import { ethers, upgrades } from "hardhat";
import keccak256 from "keccak256";
import MerkleTree from "merkletreejs";
import { StoreFront } from "../typechain-types";

describe("Store Front ", function () {
  let storeFront: StoreFront;

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
    const storeFrontContract = await ethers.getContractFactory("StoreFront");
    storeFront = (await upgrades.deployProxy(
      storeFrontContract,
      ["MNT", "MNT", "https://api.example.com/", ownerAddress, ownerAddress],
      {
        kind: "uups",
      }
    )) as StoreFront;

    await storeFront.deployed();
  });

  it("Setup contract", async function () {
    await expect(
      storeFront.connect(user).setBaseURI("https://api.example.com/")
    ).to.be.reverted;
    await expect(
      storeFront
        .connect(user)
        .setContractURI("https://api.example.com/contract")
    ).to.be.reverted;
    await expect(storeFront.connect(user).setDefaultRoyalty(ownerAddress, 1000))
      .to.be.reverted;
    await storeFront.setBaseURI("https://api.example.com/");
    await storeFront.setContractURI("https://api.example.com/contract");
    await storeFront.setDefaultRoyalty(ownerAddress, 1000);
    expect(await storeFront.contractURI()).to.be.equal(
      "https://api.example.com/contract"
    );
    const royaltyAmount = ethers.utils.formatEther(
      (await storeFront.royaltyInfo(1, ethers.utils.parseEther("1")))[1]
    );
    expect(royaltyAmount, "0.1");
    expect(await storeFront.treasury()).to.be.equal(ownerAddress);
  });

  it("Initialize Tier", async function () {
    await expect(
      storeFront
        .connect(user)
        .initTier(1, ethers.utils.parseEther("1"), 20, 2, 5)
    ).to.be.reverted;

    await expect(storeFront.tiers(6)).to.be.revertedWith("TIER_UNAVAILABLE");

    await expect(
      storeFront.initTier(101, ethers.utils.parseEther("1"), 20, 2, 5)
    ).to.be.revertedWith("TIER_UNAVAILABLE");
    await expect(
      storeFront.initTier(1, ethers.utils.parseEther("1"), 0, 2, 5)
    ).to.be.revertedWith("INVALID_SUPPLY");

    await expect(
      storeFront.initTier(1, ethers.utils.parseEther("1"), 20, 0, 5)
    ).to.be.revertedWith("INVALID_MAX_PER_TX");

    await expect(
      storeFront.initTier(1, ethers.utils.parseEther("1"), 20, 2, 0)
    ).to.be.revertedWith("INVALID_MAX_PER_WALLET");

    await storeFront.initTier(1, ethers.utils.parseEther("1"), 20, 2, 5);

    await storeFront.initTier(2, ethers.utils.parseEther("0"), 20, 2, 5);

    await storeFront.initTier(3, ethers.utils.parseEther("1"), 20, 2, 5);

    await storeFront.initTier(4, ethers.utils.parseEther("1"), 20, 2, 5);

    await expect(
      storeFront.initTier(1, ethers.utils.parseEther("1"), 20, 2, 5)
    ).to.be.revertedWith("TIER_ALREADY_INITIALIZED");

    expect((await storeFront.totalTiers()).toNumber()).to.be.equal(4);

    const tier1 = await storeFront.tiers(1);
    expect(tier1.price).to.be.equal(ethers.utils.parseEther("1"));
  });

  it("Start Sale", async function () {
    await expect(storeFront.connect(user).startSale(5, now, now + 86400, 20)).to
      .be.reverted;
    await expect(storeFront.sales(6)).to.be.revertedWith("TIER_UNAVAILABLE");
    await expect(
      storeFront.mint([1, 2, 3], [2, 2, 2], {
        value: ethers.utils.parseEther("6"),
      })
    ).to.be.revertedWith("SALE_NOT_ACTIVE");

    await expect(
      storeFront.startSale(5, now, now + 86400, 20)
    ).to.be.revertedWith("TIER_UNAVAILABLE");

    await expect(
      storeFront.startSale(1, now + 100000, now + 86400, 20)
    ).to.be.revertedWith("INVALID_SALE_TIME");

    await expect(
      storeFront.startSale(1, now, now + 86400, 0)
    ).to.be.revertedWith("INVALID_SUPPLY");

    await storeFront.startSale(1, now, now + 86400, 20);

    await storeFront.startSale(2, now, now + 86400, 20);

    await storeFront.startSale(3, now, now + 86400, 20);

    await expect(
      storeFront.startSale(1, now, now + 86400, 20)
    ).to.be.revertedWith("SALE_ALREADY_INITIALIZED");

    expect(await storeFront.isSaleActive(1)).to.be.deep.equal(true);
    expect(await storeFront.isSaleActive(2)).to.be.deep.equal(true);
    expect(await storeFront.isSaleActive(3)).to.be.deep.equal(true);

    const sale1 = await storeFront.sales(1);
    expect(sale1.saleStart.toNumber()).to.be.equal(now);
    expect(sale1.saleEnd.toNumber()).to.be.equal(now + 86400);
  });

  it("Update Sale", async function () {
    await expect(storeFront.connect(user).updateSale(5, now, now + 86400, 20))
      .to.be.reverted;
    await expect(
      storeFront.updateSale(5, now, now + 86400, 20)
    ).to.be.revertedWith("TIER_UNAVAILABLE");
    await expect(
      storeFront.updateSale(4, now + 100000, now + 86400, 20)
    ).to.be.revertedWith("SALE_NOT_INITIALIZED");
    await expect(
      storeFront.updateSale(1, now + 100000, now + 86400, 20)
    ).to.be.revertedWith("INVALID_SALE_TIME");

    await expect(
      storeFront.updateSale(1, now, now + 86400, 0)
    ).to.be.revertedWith("INVALID_SUPPLY");

    await storeFront.updateSale(1, now, now + 2 * 86400, 20);
  });

  it("Sale Mint", async function () {
    await expect(
      storeFront.mint([1, 2, 3], [2, 2], {
        value: ethers.utils.parseEther("6"),
      })
    ).to.be.revertedWith("INVALID_TIER_SIZE");

    await expect(
      storeFront.mint([1, 2, 5], [2, 2, 2], {
        value: ethers.utils.parseEther("6"),
      })
    ).to.be.revertedWith("TIER_UNAVAILABLE");

    await expect(
      storeFront.mint([1, 2, 3], [2, 2, 2], {
        value: ethers.utils.parseEther("3"),
      })
    ).to.be.revertedWith("INSUFFICIENT_FUND");

    await expect(
      storeFront.mint([1, 2, 3], [2, 2, 3], {
        value: ethers.utils.parseEther("7"),
      })
    ).to.be.revertedWith("MAX_PER_TX_EXCEEDED");

    await storeFront.mint([1, 2, 3], [2, 2, 2], {
      value: ethers.utils.parseEther("6"),
    });

    expect(await storeFront.tokenURI(101)).to.be.equal(
      "https://api.example.com/101"
    );
  });

  it("Token Indexing", async function () {
    await expect(storeFront.balanceOfTier(ownerAddress, 15)).to.be.revertedWith(
      "TIER_UNAVAILABLE"
    );

    const ownerTierTokenBalance = (
      await storeFront.balanceOfTier(ownerAddress, 1)
    ).toNumber();

    expect(ownerTierTokenBalance).to.be.equal(2);
    const maxTiers = (await storeFront.maxTiers()).toNumber();

    await expect(
      storeFront.tierTokenOfOwnerByIndex(ownerAddress, 5, 1)
    ).to.be.revertedWith("TIER_UNAVAILABLE");

    await expect(
      storeFront.tierTokenOfOwnerByIndex(ownerAddress, 1, 10)
    ).to.be.revertedWith("INVALID_INDEX");

    for (let x = 0; x < ownerTierTokenBalance; x++) {
      const tokenId = await storeFront.tierTokenOfOwnerByIndex(
        ownerAddress,
        1,
        x
      );

      expect(tokenId.toNumber()).to.be.equal(maxTiers + x * maxTiers + 1);
    }
    const totalRevenue = await storeFront.totalRevenue();
    const balance = await ethers.provider.getBalance(storeFront.address);
    expect(ethers.utils.formatEther(totalRevenue)).to.be.equal(
      ethers.utils.formatEther(balance)
    );

    await expect(storeFront.tierTokenByIndex(5, 1)).to.be.revertedWith(
      "TIER_UNAVAILABLE"
    );
    const tierToken = await storeFront.tierTokenByIndex(1, 3);
    expect(tierToken.toNumber()).to.be.equal(3 * maxTiers + 1);
  });

  it("Update Tier", async function () {
    await expect(
      storeFront
        .connect(user)
        .updateTier(1, ethers.utils.parseEther("1"), 20, 2, 5)
    ).to.be.reverted;

    await expect(
      storeFront.updateTier(101, ethers.utils.parseEther("1"), 20, 2, 5)
    ).to.be.revertedWith("TIER_UNAVAILABLE");

    await expect(
      storeFront.updateTier(1, ethers.utils.parseEther("1"), 0, 2, 5)
    ).to.be.revertedWith("INVALID_SUPPLY");

    await expect(
      storeFront.updateTier(1, ethers.utils.parseEther("1"), 1, 2, 5)
    ).to.be.revertedWith("INVALID_SUPPLY");

    await expect(
      storeFront.updateTier(1, ethers.utils.parseEther("1"), 20, 0, 5)
    ).to.be.revertedWith("INVALID_MAX_PER_TX");

    await expect(
      storeFront.updateTier(1, ethers.utils.parseEther("1"), 20, 2, 0)
    ).to.be.revertedWith("INVALID_MAX_PER_WALLET");

    await storeFront.updateTier(1, ethers.utils.parseEther("1"), 3, 2, 4);

    await expect(
      storeFront.mint([1], [2], {
        value: ethers.utils.parseEther("2"),
      })
    ).to.be.revertedWith("MAX_SUPPLY_EXCEEDED");

    await storeFront.updateTier(1, ethers.utils.parseEther("1"), 10, 2, 2);

    await expect(
      storeFront.mint([1], [2], {
        value: ethers.utils.parseEther("2"),
      })
    ).to.be.revertedWith("MAX_PER_WALLET_EXCEEDED");
  });

  it("Stop Sale", async function () {
    await expect(storeFront.connect(user).stopSale(1)).to.be.reverted;
    await expect(storeFront.stopSale(5)).to.be.revertedWith("TIER_UNAVAILABLE");
    await expect(storeFront.stopSale(4)).to.be.revertedWith(
      "SALE_NOT_INITIALIZED"
    );

    await storeFront.stopSale(1);

    await expect(
      storeFront.mint([1], [1], { value: ethers.utils.parseEther("1") })
    ).to.be.revertedWith("SALE_NOT_ACTIVE");

    expect(await storeFront.isSaleActive(1)).to.be.deep.equal(false);
  });

  it("Start Presale", async function () {
    await storeFront.updateTier(1, ethers.utils.parseEther("1"), 20, 2, 5);

    await expect(
      storeFront.connect(user).startPresale(1, now, now + 86400, merkleRoot, 20)
    ).to.be.reverted;

    await expect(storeFront.presales(6)).to.be.revertedWith("TIER_UNAVAILABLE");

    await expect(
      storeFront.presaleMint([1], [2], [ownerMerkleProof], {
        value: ethers.utils.parseEther("6"),
      })
    ).to.be.revertedWith("PRESALE_NOT_ACTIVE");

    await expect(
      storeFront.startPresale(6, now, now + 86400, merkleRoot, 20)
    ).to.be.revertedWith("TIER_UNAVAILABLE");

    await expect(
      storeFront.startPresale(1, now + 100000, now + 86400, merkleRoot, 20)
    ).to.be.revertedWith("INVALID_PRESALE_TIME");

    await expect(
      storeFront.startPresale(1, now, now + 86400, merkleRoot, 0)
    ).to.be.revertedWith("INVALID_SUPPLY");

    await storeFront.startPresale(1, now, now + 86400, merkleRoot, 20);

    await expect(
      storeFront.startPresale(1, now, now + 86400, merkleRoot, 20)
    ).to.be.revertedWith("PRESALE_ALREADY_INITIALIZED");

    expect(await storeFront.isPresaleActive(1)).to.be.deep.equal(true);

    const presale1 = await storeFront.presales(1);
    expect(presale1.presaleStart.toNumber()).to.be.equal(now);
    expect(presale1.presaleEnd.toNumber()).to.be.equal(now + 86400);
  });

  it("Update Presale", async function () {
    await expect(
      storeFront
        .connect(user)
        .updatePresale(1, now, now + 86400, merkleRoot, 20)
    ).to.be.reverted;

    await expect(
      storeFront.updatePresale(6, now, now + 86400, merkleRoot, 20)
    ).to.be.revertedWith("TIER_UNAVAILABLE");

    await expect(
      storeFront.updatePresale(2, now, now + 86400, merkleRoot, 20)
    ).to.be.revertedWith("PRESALE_NOT_INITIALIZED");

    await expect(
      storeFront.updatePresale(1, now + 100000, now + 86400, merkleRoot, 20)
    ).to.be.revertedWith("INVALID_PRESALE_TIME");

    await expect(
      storeFront.updatePresale(1, now, now + 86400, merkleRoot, 2)
    ).to.be.revertedWith("INVALID_SUPPLY");

    await storeFront.updatePresale(1, now, now + 2 * 86400, merkleRoot, 20);
  });

  it("Presale Mint", async function () {
    await expect(
      storeFront.presaleMint([1], [2, 2], [ownerMerkleProof], {
        value: ethers.utils.parseEther("4"),
      })
    ).to.be.revertedWith("INVALID_TIER_SIZE");

    await expect(
      storeFront.presaleMint([1, 2], [2, 2], [ownerMerkleProof], {
        value: ethers.utils.parseEther("4"),
      })
    ).to.be.revertedWith("INVALID_MERKLE_SIZE");

    await expect(
      storeFront.presaleMint(
        [1, 2],
        [2, 2],
        [ownerMerkleProof, ownerMerkleProof],
        {
          value: ethers.utils.parseEther("4"),
        }
      )
    ).to.be.revertedWith("PRESALE_NOT_ACTIVE");

    await expect(
      storeFront.presaleMint(
        [1, 6],
        [2, 2],
        [ownerMerkleProof, ownerMerkleProof],
        {
          value: ethers.utils.parseEther("4"),
        }
      )
    ).to.be.revertedWith("TIER_UNAVAILABLE");

    await expect(
      storeFront.presaleMint([1], [2], [ownerMerkleProof], {
        value: ethers.utils.parseEther("1"),
      })
    ).to.be.revertedWith("INSUFFICIENT_FUND");

    await expect(
      storeFront.connect(user2).presaleMint([1], [2], [ownerMerkleProof], {
        value: ethers.utils.parseEther("1"),
      })
    ).to.be.revertedWith("USER_NOT_WHITELISTED");

    await storeFront.presaleMint([1], [2], [ownerMerkleProof], {
      value: ethers.utils.parseEther("2"),
    });

    await storeFront.connect(user).presaleMint([1], [2], [userMerkeleProof], {
      value: ethers.utils.parseEther("2"),
    });
  });

  it("Stop Preale", async function () {
    await expect(storeFront.connect(user).stopPresale(1)).to.be.reverted;
    await expect(storeFront.stopPresale(5)).to.be.revertedWith(
      "TIER_UNAVAILABLE"
    );
    await expect(storeFront.stopPresale(4)).to.be.revertedWith(
      "PRESALE_NOT_INITIALIZED"
    );

    await storeFront.stopPresale(1);

    await expect(
      storeFront.presaleMint([1], [1], [ownerMerkleProof], {
        value: ethers.utils.parseEther("1"),
      })
    ).to.be.revertedWith("PRESALE_NOT_ACTIVE");

    expect(await storeFront.isPresaleActive(1)).to.be.deep.equal(false);
  });

  it("Airdrop mint", async function () {
    await expect(
      storeFront
        .connect(user)
        .airdropMint([userAddress, ownerAddress], [1, 1], [1, 1])
    ).to.be.reverted;

    await expect(
      storeFront.airdropMint([userAddress, ownerAddress], [1], [1, 1])
    ).to.be.revertedWith("INVALID_TIER_SIZE");

    await expect(
      storeFront.airdropMint([userAddress, ownerAddress], [1, 1], [1])
    ).to.be.revertedWith("INVALID_TIER_SIZE");

    const balanceOfOwner = (
      await storeFront.balanceOf(ownerAddress)
    ).toNumber();
    const balanceOfUser = (await storeFront.balanceOf(userAddress)).toNumber();

    // Airdrop
    await storeFront.airdropMint([ownerAddress, userAddress], [1, 1], [1, 1]);

    const balanceOfOwner2 = (
      await storeFront.balanceOf(ownerAddress)
    ).toNumber();
    const balanceOfUser2 = (await storeFront.balanceOf(userAddress)).toNumber();

    expect(balanceOfOwner + 1).to.be.equal(balanceOfOwner2);
    expect(balanceOfUser + 1).to.be.equal(balanceOfUser2);
  });

  it("Withdraw", async function () {
    const balance = await owner.getBalance();
    await storeFront.withdraw();
    const balance2 = await owner.getBalance();
    expect(balance2.toString()).to.not.equal(balance.toString());
    await expect(storeFront.withdraw()).to.be.revertedWith("ZERO_BALANCE");
  });
});
