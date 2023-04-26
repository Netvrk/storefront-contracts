# Store Front Contract

#### Goerli Network (Testnet)

- Store Front: [0x994eA299D72F1B0690B3730E7dc7ce825a378046](https://goerli.etherscan.io/address/0x994eA299D72F1B0690B3730E7dc7ce825a378046)
- NRGY: [0x34562283739db04b7eB67521BFb5C9118F0C0844](https://mumbai.polygonscan.com/address/0x34562283739db04b7eB67521BFb5C9118F0C0844)

** Archetype Avatar **

- [0x0fAd993f895F56F05bddFC4744Cd74B012512AdC](https://mumbai.polygonscan.com/address/0x0fAd993f895F56F05bddFC4744Cd74B012512AdC)
- [0xF8d2aD3dD3D89C459C666756e599CF23941E82db](https://mumbai.polygonscan.com/address/0xF8d2aD3dD3D89C459C666756e599CF23941E82db)

### Documentation

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
