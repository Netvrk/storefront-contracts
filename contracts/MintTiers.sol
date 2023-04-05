// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "hardhat/console.sol";

/*
SALES PHASES:
1. Free claim for whitelisted addresses (address, max qty)
2. Pre-sale for whitelisted addresses w/ bonus pack discounts (address, max qty, price)
3. Pre-sale for whitelisted address w/ promo code option (address)
4. Public sale w/ promo code option

NEED TO CHECK:
-removed upgradability (to support NFTpay mint)
-added NFTpay requirements (mint, whitelist, etc.)
-ERC20 token instead of native currency
-promo codes

NEED TO DO:
-sales phases
-events?
---track influencer rewards for leaderboard/contest
*/

contract MintTiers is
    ERC2981,
    AccessControl,
    ReentrancyGuard,
    ERC721Enumerable
{
    using MerkleProof for bytes32[];

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    address private _treasury;
    string private _tokenBaseURI;
    string private _contractURI;
    address private _tokenAddress;
    uint256 private _influencerCommission;

    struct Tier {
        uint256 id;
        uint256 price;
        uint256 maxSupply;
        uint256 supply;
        uint256 maxPerTx;
        uint256 maxPerWallet;
    }

    struct Sale {
        uint256 id;
        uint256 saleStart;
        uint256 saleEnd;
    }

    struct PreSale {
        uint256 id;
        uint256 presaleStart;
        uint256 presaleEnd;
        bytes32 merkleRoot;
    }

    mapping(uint256 => Tier) private _tiers;
    mapping(uint256 => Sale) private _sales;
    mapping(uint256 => PreSale) private _presales;

    mapping(address => mapping(uint256 => uint256)) private _ownerTierBalance;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        private _ownerTierTokens;
    uint256 private _totalRevenue;
    uint256 private constant _maxTiers = 100;
    uint256 private _totalTiers;

    mapping(address => bool) public nftPayWhitelist;

    struct PromoCode {
        uint256 tier;
        address influencer;
        uint256 discount;
        uint256 maxRedeemable;
        uint256 totalRedeemed;
        bool active;
    }
    mapping(bytes32 => PromoCode) private _promoCodes;
    mapping(address => uint256) public _influencerBalances;

    /**
    ////////////////////////////////////////////////////
    // Admin Functions 
    ///////////////////////////////////////////////////
    */

    constructor(
      string memory name_,
      string memory symbol_,
      string memory baseURI_,
      address treasury_,
      address manager,
      address tokenAddress_,
      uint256 influencerCommission_
    ) ERC721(
      name_,
      symbol_
    ) {
      _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
      _setupRole(MANAGER_ROLE, manager);

      _tokenBaseURI = baseURI_;
      _treasury = treasury_;
      _totalTiers = 0;
      _tokenAddress = tokenAddress_;
      _influencerCommission = influencerCommission_;
    }

    // Set NFT base URI
    function setBaseURI(
        string memory newBaseURI_
    ) external virtual onlyRole(MANAGER_ROLE) {
        _tokenBaseURI = newBaseURI_;
    }

    // Set Contract URI
    function setContractURI(
        string memory newContractURI
    ) external virtual onlyRole(MANAGER_ROLE) {
        _contractURI = newContractURI;
    }

    // Set default royalty
    function setDefaultRoyalty(
        address receiver,
        uint96 royalty
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDefaultRoyalty(receiver, royalty);
    }

    /**
    ////////////////////////////////////////////////////
    // Initial Functions 
    ///////////////////////////////////////////////////
    */

    // Initialize tier
    function initTier(
        uint256 id,
        uint256 price,
        uint256 maxSupply,
        uint256 maxPerTx,
        uint256 maxPerWallet
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(id <= _maxTiers, "TIER_UNAVAILABLE");
        require(_tiers[id].id == 0, "TIER_ALREADY_INITIALIZED");
        require(maxSupply > 0, "INVALID_SUPPLY");
        require(maxPerTx > 0, "INVALID_MAX_PER_TX");
        require(maxPerWallet > 0, "INVALID_MAX_PER_WALLET");

        _tiers[id] = Tier(id, price, maxSupply, 0, maxPerTx, maxPerWallet);
        _totalTiers++;
    }

    // Update tier
    function updateTier(
        uint256 id,
        uint256 price,
        uint256 maxSupply,
        uint256 maxPerTx,
        uint256 maxPerWallet
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(id <= _totalTiers, "TIER_UNAVAILABLE");
        require(maxSupply > 0, "INVALID_SUPPLY");
        require(maxSupply > _tiers[id].supply, "INVALID_SUPPLY");
        require(maxPerTx > 0, "INVALID_MAX_PER_TX");
        require(maxPerWallet > 0, "INVALID_MAX_PER_WALLET");

        _tiers[id].price = price;
        _tiers[id].maxSupply = maxSupply;
        _tiers[id].maxPerTx = maxPerTx;
        _tiers[id].maxPerWallet = maxPerWallet;
    }

    // Initialize sale
    function startSale(
        uint256 id,
        uint256 saleStart,
        uint256 saleEnd,
        uint256 maxSupply
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(id <= _totalTiers, "TIER_UNAVAILABLE");
        require(_sales[id].id == 0, "SALE_ALREADY_INITIALIZED");
        require(saleStart < saleEnd, "INVALID_SALE_TIME");
        require(maxSupply > _tiers[id].supply, "INVALID_SUPPLY");

        // Stop presale
        _presales[id].presaleEnd = block.timestamp;

        _sales[id] = Sale(id, saleStart, saleEnd);
        _tiers[id].maxSupply = maxSupply;
    }

    // Update sale
    function updateSale(
        uint256 id,
        uint256 saleStart,
        uint256 saleEnd,
        uint256 maxSupply
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(id <= _totalTiers, "TIER_UNAVAILABLE");
        require(_sales[id].id != 0, "SALE_NOT_INITIALIZED");
        require(saleStart < saleEnd, "INVALID_SALE_TIME");
        require(maxSupply > _tiers[id].supply, "INVALID_SUPPLY");

        _sales[id].saleStart = saleStart;
        _sales[id].saleEnd = saleEnd;

        _tiers[id].maxSupply = maxSupply;
    }

    // Initialize presale
    function startPresale(
        uint256 id,
        uint256 presaleStart,
        uint256 presaleEnd,
        bytes32 merkleRoot_,
        uint256 maxSupply
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(id <= _totalTiers, "TIER_UNAVAILABLE");
        require(_presales[id].id == 0, "PRESALE_ALREADY_INITIALIZED");
        require(presaleStart < presaleEnd, "INVALID_PRESALE_TIME");
        require(maxSupply > _tiers[id].supply, "INVALID_SUPPLY");

        // Stop sale
        _sales[id].saleEnd = block.timestamp;

        _presales[id] = PreSale(id, presaleStart, presaleEnd, merkleRoot_);
        _tiers[id].maxSupply = maxSupply;
    }

    // Update presale
    function updatePresale(
        uint256 id,
        uint256 presaleStart,
        uint256 presaleEnd,
        bytes32 merkleRoot_,
        uint256 maxSupply
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(id <= _totalTiers, "TIER_UNAVAILABLE");
        require(_presales[id].id != 0, "PRESALE_NOT_INITIALIZED");
        require(presaleStart < presaleEnd, "INVALID_PRESALE_TIME");
        require(maxSupply > _tiers[id].supply, "INVALID_SUPPLY");

        _presales[id].presaleStart = presaleStart;
        _presales[id].presaleEnd = presaleEnd;
        _presales[id].merkleRoot = merkleRoot_;
        _tiers[id].maxSupply = maxSupply;
    }

    function stopPresale(
        uint256 tierId
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(_presales[tierId].id != 0, "PRESALE_NOT_INITIALIZED");
        _presales[tierId].presaleEnd = block.timestamp;
    }

    function stopSale(uint256 tierId) external virtual onlyRole(MANAGER_ROLE) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(_sales[tierId].id != 0, "SALE_NOT_INITIALIZED");
        _sales[tierId].saleEnd = block.timestamp;
    }

    // Withdraw all revenues
    function withdraw() external virtual nonReentrant {
        require(address(this).balance > 0, "ZERO_BALANCE");
        uint256 balance = IERC20(_tokenAddress).balanceOf(address(this));
        require(IERC20(_tokenAddress).transferFrom(address(this), _treasury, balance), "TOKEN_TRANSFER_FAIL");
    }

    /**
    ////////////////////////////////////////////////////
    // Public Functions 
    ///////////////////////////////////////////////////
    */

    function mint(
        uint256[] memory tokenTiers,
        uint256[] memory tierSizes
    ) external virtual nonReentrant {
        // Check input lengths
        require(tokenTiers.length == tierSizes.length, "INVALID_TIER_SIZE");

        uint256 totalCost = 0;
        for (uint256 i = 0; i < tokenTiers.length; i++) {
            uint256 tierId = tokenTiers[i];
            uint256 tokenSize = tierSizes[i];

            // Check if tier is available
            require(tierId <= _totalTiers, "TIER_UNAVAILABLE");

            Tier storage tier = _tiers[tierId];

            // Check if sale is active
            require(_isSaleActive(tierId), "SALE_NOT_ACTIVE");

            totalCost += tier.price * tokenSize;
        }

        // Transfer tokens
        require(IERC20(_tokenAddress).transferFrom(msg.sender, address(this), totalCost), "TOKEN_TRANSFER_FAIL");

        // Mint tier
        for (uint256 i = 0; i < tokenTiers.length; i++) {
            _mintTier(msg.sender, tokenTiers[i], tierSizes[i]);
        }

        _totalRevenue = _totalRevenue + totalCost;
    }

    function presaleMint(
        uint256[] memory tokenTiers,
        uint256[] memory tierSizes,
        bytes32[][] calldata merkleProofs
    ) external virtual nonReentrant {
        // Check input lengths
        require(tokenTiers.length == tierSizes.length, "INVALID_TIER_SIZE");
        require(
            tokenTiers.length == merkleProofs.length,
            "INVALID_MERKLE_SIZE"
        );
        uint256 totalCost = 0;
        for (uint256 i = 0; i < tokenTiers.length; i++) {
            uint256 tierId = tokenTiers[i];
            uint256 tokenSize = tierSizes[i];

            require(tierId <= _totalTiers, "TIER_UNAVAILABLE");

            Tier storage tier = _tiers[tierId];

            require(_isPresaleActive(tierId), "PRESALE_NOT_ACTIVE");

            require(
                MerkleProof.verify(
                    merkleProofs[i],
                    _presales[tierId].merkleRoot,
                    keccak256(abi.encodePacked(msg.sender))
                ),
                "USER_NOT_WHITELISTED"
            );

            totalCost += tier.price * tokenSize;
        }

        // transfer tokens
        require(IERC20(_tokenAddress).transferFrom(msg.sender, address(this), totalCost), "TOKEN_TRANSFER_FAIL");

        // Mint tier
        for (uint256 i = 0; i < tokenTiers.length; i++) {
            _mintTier(msg.sender, tokenTiers[i], tierSizes[i]);
        }

        _totalRevenue = _totalRevenue + totalCost;
    }

    // Mint through airdrop
    function airdropMint(
        address[] memory recipients,
        uint256[] memory tokenTiers,
        uint256[] memory tierSizes
    ) external virtual onlyRole(MANAGER_ROLE) nonReentrant {
        // Check lengths
        require(recipients.length == tokenTiers.length, "INVALID_TIER_SIZE");
        require(recipients.length == tierSizes.length, "INVALID_TIER_SIZE");

        for (uint256 i = 0; i < recipients.length; i++) {
            _mintTier(recipients[i], tokenTiers[i], tierSizes[i]);
        }
    }
    
    function nftPayMint(
        uint256 tokenTier,
        uint256 tierSize
    ) external virtual nonReentrant {
        // Check whitelist
        require(nftPayWhitelist[msg.sender], "SENDER_NOT_WHITELISTED");
        
        // Check if tier is available
        require(tokenTier <= _totalTiers, "TIER_UNAVAILABLE");
        
        Tier storage tier = _tiers[tokenTier];
        // Check if sale is active
        require(_isSaleActive(tokenTier), "SALE_NOT_ACTIVE");

        uint256 totalCost = 0;
        totalCost += tier.price * tierSize;
        
        // Transfer tokens
        require(IERC20(_tokenAddress).transferFrom(msg.sender, address(this), totalCost), "TOKEN_TRANSFER_FAIL");

        _mintTier(msg.sender, tokenTier, tierSize);

        _totalRevenue = _totalRevenue + totalCost;
    }

    function addToNftPayWhitelist(address whitelistAddress) external virtual onlyRole(MANAGER_ROLE) nonReentrant {
        nftPayWhitelist[whitelistAddress] = true;
    }

    function withdrawInfluencerRewards() public nonReentrant {
        uint256 reward = _influencerBalances[msg.sender];
        require(reward > 0, 'SENDER REWARD BALANCE IS 0');
        _influencerBalances[msg.sender] = 0;
        IERC20(_tokenAddress).transfer(msg.sender, reward);
    }

    function addPromoCode(
        uint256 tier_,
        bytes32 promoCodeHash_,
        address infuencer_,
        uint256 discount_,
        uint256 maxRedeemable_
    ) external virtual onlyRole(MANAGER_ROLE) nonReentrant {
        require(discount_ > 0, 'DISCOUNT_MUST_BE_GREATER_THAN_0');
        require(discount_ < 100, 'DISCOUNT_MUST_BE_LESS_THAN_100');
        require(maxRedeemable_ > 0, 'MAX_REDEEMEABLE_MUST_BE_GREATER_THAN_0');
        require(_promoCodes[promoCodeHash_].discount == 0, 'PROMO_CODE_ALREADY_EXISTS'); // TODO: better way to check if exists?
        _promoCodes[promoCodeHash_] = PromoCode(
            tier_,
            infuencer_,
            discount_,
            maxRedeemable_,
            0,
            true
        );
    }

    function updatePromoCode(
        uint256 tier_,
        bytes32 promoCodeHash_,
        address infuencer_,
        uint256 discount_,
        uint256 maxRedeemable_,
        bool active_
    ) external virtual onlyRole(MANAGER_ROLE) nonReentrant {
        require(discount_ > 0, 'DISCOUNT MUST BE GREATER THAN 0');
        require(discount_ < 100, 'DISCOUNT_MUST_BE_LESS_THAN_100');
        require(maxRedeemable_ <= _promoCodes[promoCodeHash_].totalRedeemed, 'MAX_REDEEMEABLE_TOO_HIGH');
        require(_promoCodes[promoCodeHash_].discount != 0, 'PROMO CODE DOES NOT EXIST'); // TODO: better way to check if exists?
        _promoCodes[promoCodeHash_] = PromoCode(
            tier_,
            infuencer_,
            discount_,
            maxRedeemable_,
            _promoCodes[promoCodeHash_].totalRedeemed, // TODO: better way to do this?
            active_
        );
    }

    function promoCodeMint(
        uint256 tokenTier_,
        uint256 tierSize_,
        bytes32 promoCodeHash_
    ) external virtual nonReentrant {
        PromoCode memory promoCode = _promoCodes[promoCodeHash_];
        require(promoCode.discount > 0, 'PROMO_CODE_DOES_NOT_EXIST');
        require(promoCode.active == true, 'PROMO_CODE_NOT_ACTIVE');
        require(promoCode.totalRedeemed + tierSize_ <= promoCode.maxRedeemable, 'PROMO_CODE_MAX_REDEEMABLE_EXCEEDED');
        require(promoCode.tier == tokenTier_, 'PROMO_CODE_DOES_NOT_MATCH_TIER');

        // Check if tier is available
        require(tokenTier_ <= _totalTiers, "TIER_UNAVAILABLE");
        Tier storage tier = _tiers[tokenTier_];
        // Check if sale is active
        require(_isSaleActive(tokenTier_), "SALE_NOT_ACTIVE");

        uint256 discountedPrice = tier.price * ((100 - promoCode.discount) / 100);
        uint256 totalCost = discountedPrice * tierSize_;
        uint256 influencerReward = discountedPrice * _influencerCommission / 100;

        _influencerBalances[promoCode.influencer] += influencerReward;
        _promoCodes[promoCodeHash_].totalRedeemed += tierSize_;
        
        // Transfer tokens
        IERC20(_tokenAddress).transfer(address(this), totalCost);

        _mintTier(msg.sender, tokenTier_, tierSize_);

        _totalRevenue = _totalRevenue + (totalCost - influencerReward);
    }

    function promoCodePrealeMint(
        uint256 tokenTier_,
        uint256 tierSize_,
        bytes32 promoCodeHash_,
        bytes32[] calldata merkleProof_
    ) external virtual nonReentrant {
        PromoCode memory promoCode = _promoCodes[promoCodeHash_];
        require(promoCode.discount > 0, 'PROMO_CODE_DOES_NOT_EXIST');
        require(promoCode.active == true, 'PROMO_CODE_NOT_ACTIVE');
        require(promoCode.totalRedeemed + tierSize_ <= promoCode.maxRedeemable, 'PROMO_CODE_MAX_REDEEMABLE_EXCEEDED');
        require(promoCode.tier == tokenTier_, 'PROMO_CODE_DOES_NOT_MATCH_TIER');

        // Check if tier is available
        require(tokenTier_ <= _totalTiers, "TIER_UNAVAILABLE");
        Tier storage tier = _tiers[tokenTier_];
        // Check if sale is active
        require(_isSaleActive(tokenTier_), "SALE_NOT_ACTIVE");

        require(
            MerkleProof.verify(
                merkleProof_,
                _presales[tokenTier_].merkleRoot,
                keccak256(abi.encodePacked(msg.sender))
            ),
            "USER_NOT_WHITELISTED"
        );

        uint256 discountedPrice = tier.price * ((100 - promoCode.discount) / 100);
        uint256 totalCost = discountedPrice * tierSize_;
        uint256 influencerReward = discountedPrice * _influencerCommission / 100;

        _influencerBalances[promoCode.influencer] += influencerReward;
        _promoCodes[promoCodeHash_].totalRedeemed += tierSize_;
        
        // try transfer
        IERC20(_tokenAddress).transfer(address(this), totalCost);

        _mintTier(msg.sender, tokenTier_, tierSize_);

        _totalRevenue = _totalRevenue + (totalCost - influencerReward);
    }

    /**
    ////////////////////////////////////////////////////
    // Internal Functions 
    ///////////////////////////////////////////////////
    */

    function _mintTier(address to, uint256 tierId, uint256 tokenSize) internal {
        Tier storage tier = _tiers[tierId];

        // Check if tier is sold out
        require(
            tier.supply + tokenSize <= tier.maxSupply,
            "MAX_SUPPLY_EXCEEDED"
        );

        // Check if max per tx is not exceeded
        require(tokenSize <= tier.maxPerTx, "MAX_PER_TX_EXCEEDED");

        // Check if max per wallet is not exceeded
        if(!nftPayWhitelist[to]) {
            require(
                _ownerTierBalance[to][tierId] + tokenSize <= tier.maxPerWallet,
                "MAX_PER_WALLET_EXCEEDED"
            );
        }
        
        // Mint tokens
        for (uint256 x = 0; x < tokenSize; x++) {
            uint256 tokenId = _maxTiers + (tier.supply * _maxTiers) + tierId;
            _safeMint(to, tokenId);
            tier.supply++;
            _ownerTierTokens[to][tierId][
                _ownerTierBalance[to][tierId]
            ] = tokenId;
            _ownerTierBalance[to][tierId]++;
        }
    }

    function _isSaleActive(uint256 tierId) internal view returns (bool) {
        return
            block.timestamp >= _sales[tierId].saleStart &&
            block.timestamp <= _sales[tierId].saleEnd;
    }

    function _isPresaleActive(uint256 tierId) internal view returns (bool) {
        return
            block.timestamp >= _presales[tierId].presaleStart &&
            block.timestamp <= _presales[tierId].presaleEnd;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _tokenBaseURI;
    }

    /**
    ////////////////////////////////////////////////////
    // View only functions
    ///////////////////////////////////////////////////
    */

    function contractURI() external view virtual returns (string memory) {
        return _contractURI;
    }

    function treasury() external view virtual returns (address) {
        return _treasury;
    }

    function totalRevenue() external view virtual returns (uint256) {
        return _totalRevenue;
    }

    function maxTiers() external view virtual returns (uint256) {
        return _maxTiers;
    }

    function totalTiers() external view virtual returns (uint256) {
        return _totalTiers;
    }

    function isSaleActive(uint256 tierId) external view virtual returns (bool) {
        return _isSaleActive(tierId);
    }

    function tokenAddress() external view virtual returns (address) {
        return _tokenAddress;
    }

    function influencerCommission() external view virtual returns (uint256) {
        return _influencerCommission;
    }
    
    function isPresaleActive(
        uint256 tierId
    ) external view virtual returns (bool) {
        return _isPresaleActive(tierId);
    }

    function tiers(
        uint256 tierId
    )
        external
        view
        returns (
            uint256 price,
            uint256 supply,
            uint256 maxSupply,
            uint256 maxPerTx,
            uint256 maxPerWallet
        )
    {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        Tier storage tier = _tiers[tierId];
        return (
            tier.price,
            tier.supply,
            tier.maxSupply,
            tier.maxPerTx,
            tier.maxPerWallet
        );
    }

    function sales(
        uint256 tierId
    ) external view returns (uint256 saleStart, uint256 saleEnd) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        Sale storage sale = _sales[tierId];
        return (sale.saleStart, sale.saleEnd);
    }

    function presales(
        uint256 tierId
    )
        external
        view
        returns (uint256 presaleStart, uint256 presaleEnd, bytes32 merkleRoot)
    {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        PreSale storage presale = _presales[tierId];
        return (presale.presaleStart, presale.presaleEnd, presale.merkleRoot);
    }

    function tierTokenByIndex(
        uint256 tierId,
        uint256 index
    ) external view returns (uint256) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        return (index * _maxTiers) + tierId;
    }

    function tierTokenOfOwnerByIndex(
        address owner,
        uint256 tierId,
        uint256 index
    ) external view returns (uint256) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(index < _ownerTierBalance[owner][tierId], "INVALID_INDEX");
        return _ownerTierTokens[owner][tierId][index];
    }

    function balanceOfTier(
        address owner,
        uint256 tierId
    ) external view returns (uint256) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        return _ownerTierBalance[owner][tierId];
    }
    
    function promoCodes(
        bytes32 promoCodeHash
    )
        external
        view
        returns (
            uint256 tier,
            address influencer,
            uint256 discount,
            uint256 maxRedeemable,
            uint256 totalRedeemed,
            bool active
        )
    {
        require(_promoCodes[promoCodeHash].discount > 0, "PROMO_CODE_DOES_NOT_EXIST");
        PromoCode storage promoCode = _promoCodes[promoCodeHash];
        return (
            promoCode.tier,
            promoCode.influencer,
            promoCode.discount,
            promoCode.maxRedeemable,
            promoCode.totalRedeemed,
            promoCode.active
        );
    }

    function influencerBalances(address influencer_) external view virtual returns (uint256) {
        return _influencerBalances[influencer_];
    }

    /**
    ////////////////////////////////////////////////////
    // Override Functions 
    ///////////////////////////////////////////////////
    */
    // The following functions are overrides required by Solidity.
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        virtual
        override(ERC2981, ERC721Enumerable, AccessControl)
        returns (bool)
    {
        if (interfaceId == type(IERC2981).interfaceId) {
            return true;
        }
        return super.supportsInterface(interfaceId);
    }
}
