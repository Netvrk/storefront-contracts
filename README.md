# Store Front Contracts

The **Store Front Contracts** project is a comprehensive suite of smart contracts that facilitate the sale and distribution of NFTs (Non-Fungible Tokens) on the EVM (Ethereum Virtual Machine) blockchain. The primary purpose of these contracts is to manage the minting, sale, and distribution of both **Netvrk Native** NFTs and NFTs from **Partner NFT projects**.

### Key functionalities include:

1. **NFT Tier Management**:
   - The contracts handle different tiers or categories of NFTs, allowing for a structured pricing and availability system. This can include exclusive or limited-edition NFTs available at different price points.
2. **Presale and Public Sale Management**:

   - The contracts offer separate mechanisms for presale and public sales, enabling controlled access to certain NFTs before they are publicly available. This allows projects to reward early adopters or offer special incentives for presale participants.

3. **Airdrops**:

   - The system supports the airdropping of NFTs to specific addresses. This can be useful for rewarding loyal users, incentivizing actions, or promoting a new NFT collection to targeted audiences.

4. **Fund Withdrawals**:
   - The contracts also manage the process of withdrawing funds generated from NFT sales. Funds can be transferred to a designated treasury or wallet, which is typically controlled by the project's admin or development team.

In essence, these contracts create a streamlined, secure, and automated framework for launching and managing NFT projects on the blockchain, making it easier for both creators and buyers to interact with and participate in NFT sales.

## Goerli Network (Testnet)

- **Store Front:** [0x994eA299D72F1B0690B3730E7dc7ce825a378046](https://goerli.etherscan.io/address/0x994eA299D72F1B0690B3730E7dc7ce825a378046)
- **NRGY:** [0xF5B84B4F60F47616e79d7a46d43706B90AdD1e56](https://mumbai.polygonscan.com/address/0xF5B84B4F60F47616e79d7a46d43706B90AdD1e56)
- **Archetype Avatar:** [0xA1cc025c4a606af35bb9f3b5Bc097eF117706af3](https://mumbai.polygonscan.com/address/0xA1cc025c4a606af35bb9f3b5Bc097eF117706af3)

### Specification

#### Tiers

Initialize the contract with the tiers you want to use. The tiers are categories of the NFT tokens. Each tier has a price and a max supply. The price is the price of the token in wei. The max supply is the maximum number of tokens that can be minted in that tier. The max supply per transaction is the maximum number of tokens that can be minted in that tier per transaction. The max supply per wallet is the maximum number of tokens that can be minted in that tier per wallet.

```js
// Interfaces
function initTier(
        uint256 id,
        uint256 price,
        uint256 maxSupply,
        uint256 maxPerTx,
        uint256 maxPerWallet
    ) external virtual onlyRole(MANAGER_ROLE);
function updateTier(
        uint256 id,
        uint256 price,
        uint256 maxSupply,
        uint256 maxPerTx,
        uint256 maxPerWallet
    ) external virtual onlyRole(MANAGER_ROLE);
```

```js
// Usage
await storeFront.initTier(1, ethers.utils.parseEther("1"), 20, 2, 5);
await storeFront.updateTier(1, ethers.utils.parseEther("1"), 10, 2, 2);
```

#### Sale

The sale is the period of time when the minting is open. It takes the start and end time in unix timestamp. The max supply is the maximum number of tokens that can be minted in that sale.

```js
// Interfaces
function startSale(
        uint256 id,
        uint256 saleStart,
        uint256 saleEnd,
        uint256 maxSupply
    ) external virtual onlyRole(MANAGER_ROLE);
function updateSale(
        uint256 id,
        uint256 saleStart,
        uint256 saleEnd,
        uint256 maxSupply
    ) external virtual onlyRole(MANAGER_ROLE);
function stopSale(uint256 tierId) external virtual onlyRole(MANAGER_ROLE);
```

```js
// Usage
await storeFront.startSale(1, now, now + 86400, 20);
await storeFront.updateSale(1, now, now + 2 * 86400, 20);
await storeFront.stopSale(1);
```

#### Presale

Presale is the period when the minting is open for whitelisted addresses. It takes the start and end time in unix timestamp. The max supply is the maximum number of tokens that can be minted in that presale. Merkle root is the root of the merkle tree that contains the whitelisted addresses.

```js
// Interfaces
function startPresale(
        uint256 id,
        uint256 presaleStart,
        uint256 presaleEnd,
        bytes32 merkleRoot_,
        uint256 maxSupply
    ) external virtual onlyRole(MANAGER_ROLE);
function updatePresale(
        uint256 id,
        uint256 presaleStart,
        uint256 presaleEnd,
        bytes32 merkleRoot_,
        uint256 maxSupply
    ) external virtual onlyRole(MANAGER_ROLE);
function stopPresale(
        uint256 tierId
    ) external virtual onlyRole(MANAGER_ROLE);
```

```js
// Usage
await storeFront.startPresale(1, now, now + 86400, merkleRoot, 20);
await storeFront.updatePresale(1, now, now + 2 * 86400, merkleRoot, 20);
await storeFront.stopPresale(1);
```

#### Sale Minting

The minting function is used to mint tokens during the sale period. The function will revert if the sale is not active or if the tier is sold out.

```js
// Interfaces
function mint(
        uint256[] memory tokenTiers,
        uint256[] memory tierSizes
    ) external payable virtual;
```

```js
// Usage
await storeFront.mint([1, 2, 3], [2, 2, 2], {
  value: ethers.utils.parseEther("6"),
});
```

#### Presale Minting

The minting function is used to mint tokens during the presale period. The function will revert if the presale is not active or if the tier is sold out. The function will also revert if the address is not whitelisted. The tier size is the number of tokens to be minted in that tier. The merkle proof is the proof of the address in the merkle tree for each of the tiers.

```js
// Interfaces
function presaleMint(
        uint256[] memory tokenTiers,
        uint256[] memory tierSizes,
        bytes32[][] calldata merkleProofs
    ) external payable virtual
```

```js
// Usage
await storeFront.presaleMint([1], [2], [merkleProof], {
  value: ethers.utils.parseEther("2"),
});
```

#### Airdrop Minting

The airdrop mint function is used to mint tokens for airdrops. Only manager can call this function.

```js
// Interfaces
function airdropMint(
        address[] memory recipients,
        uint256[] memory tokenTiers,
        uint256[] memory tierSizes
    ) external virtual onlyRole(MANAGER_ROLE);
```

```js
// Usage
await storeFront.airdropMint([user1, user2], [1, 1], [1, 1]);
```

#### Withdraw

The withdraw function is used to withdraw the funds from the contract. Only the manager can call this function.

```js
// Interfaces
function withdraw() external virtual;
```

```js
// Usage
await storeFront.withdraw();
```
