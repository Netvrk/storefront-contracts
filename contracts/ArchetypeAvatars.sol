// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/MerkleProofUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";

// import "hardhat/console.sol";

/*
PHASES:
Phase 0: Airdrop
Phase 1: Free claim for whitelisted addresses (address, max qty)
Phase 2: Pre-sale for whitelisted addresses w/ bonus pack discounts (address, max qty, price)
Phase 3: Pre-sale for whitelisted address w/ promo code option (address)
Phase 4: Public sale w/ promo code option

TODO:
Events
-emit influencer reward after promo code mint (to be used for an influencer leaderboard)
*/

contract ArchetypeAvatars is
    ERC2981,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC721EnumerableUpgradeable,
    UUPSUpgradeable
{
    using MerkleProofUpgradeable for bytes32[];

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    address private _treasury;
    string private _tokenBaseURI;
    string private _contractURI;
    address private _paymentToken;

    struct Tier {
        uint256 id;
        uint256 price;
        uint256 maxSupply;
        uint256 supply;
        uint256 maxPerTx;
        uint256 maxPerWallet;
    }
    mapping(uint256 => Tier) private _tiers;

    struct Airdrop {
        uint256 id;
        bytes32 merkleRoot;
    }
    struct AirdropCompleted {
        uint256 id;
        bool completed;
    }
    mapping(uint256 => Airdrop) private _airdrops;
    mapping(address => mapping(uint256 => AirdropCompleted))
        public _airdropCompleted;
    uint256 public airdropIndex;

    struct Sale {
        uint256 id;
        uint256 saleStart;
        uint256 saleEnd;
    }
    // Tier => Phase => Sale
    mapping(uint256 => mapping(uint256 => Sale)) private _sales;

    mapping(address => bool) private _nftPayWhitelist;
    mapping(address => mapping(uint256 => uint256)) private _ownerTierBalance;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        private _ownerTierTokens;

    uint256 private _totalRevenue;
    uint256 private constant _maxTiers = 100;
    uint256 private _totalTiers;

    struct PromoCode {
        uint256 tier;
        address influencer;
        uint256 discount;
        uint256 commission;
        uint256 maxRedeemable;
        uint256 totalRedeemed;
        bool active;
    }
    mapping(bytes32 => PromoCode) private _promoCodes;
    mapping(address => uint256) public _influencerBalances;

    struct PhaseWhiteList {
        uint256 maxMint;
        uint256 discount;
        uint256 minted;
    }
    // user => tier/release => phase => whitelist
    mapping(address => mapping(uint256 => mapping(uint256 => PhaseWhiteList)))
        private _phaseWhitelist;

    function initialize(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        address treasury_,
        address manager_,
        address paymentToken_
    ) public initializer {
        __ERC721_init(name_, symbol_);
        __ERC721Enumerable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init_unchained();
        __AccessControl_init_unchained();

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, manager_);

        _tokenBaseURI = baseURI_;
        _treasury = treasury_;
        _paymentToken = paymentToken_;

        airdropIndex = 0;
        _totalTiers = 0;
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

    // Update sale
    function updateSale(
        uint256 tierId,
        uint256 phase,
        uint256 saleStart,
        uint256 saleEnd,
        uint256 maxSupply
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(_sales[tierId][phase].id != 0, "SALE_NOT_INITIALIZED");
        require(saleStart < saleEnd, "INVALID_SALE_TIME");
        require(maxSupply > _tiers[tierId].supply, "INVALID_SUPPLY");

        _sales[tierId][phase].saleStart = saleStart;
        _sales[tierId][phase].saleEnd = saleEnd;

        _tiers[tierId].maxSupply = maxSupply;
    }

    function stopSale(
        uint256 tierId,
        uint256 phase
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(_sales[tierId][phase].id != 0, "SALE_NOT_INITIALIZED");
        _sales[tierId][phase].saleEnd = block.timestamp;
    }

    // Withdraw all revenues
    function withdraw() external virtual nonReentrant {
        require(address(this).balance > 0, "ZERO_BALANCE");
        uint256 balance = IERC20(_paymentToken).balanceOf(address(this));
        IERC20(_paymentToken).transferFrom(address(this), _treasury, balance);
    }

    // Withdraw influencer rewards
    function withdrawInfluencerRewards() external virtual nonReentrant {
        uint256 reward = _influencerBalances[msg.sender];
        require(reward > 0, "ZERO_BALANCE");
        _influencerBalances[msg.sender] = 0;
        IERC20(_paymentToken).transfer(msg.sender, reward);
    }

    function updateNftPayWhitelist(
        address whitelistAddress,
        bool enable
    ) external virtual onlyRole(MANAGER_ROLE) nonReentrant {
        _nftPayWhitelist[whitelistAddress] = enable;
    }

    function addPromoCode(
        uint256 tier,
        bytes32 promoCodeHash,
        address infuencer,
        uint256 discount,
        uint256 commission,
        uint256 maxRedeemable
    ) external virtual onlyRole(MANAGER_ROLE) nonReentrant {
        require(discount > 0 && discount < 100, "INVALID_DISCOUNT");
        require(commission > 0 && commission < 100, "INVALID_COMMISION");
        require(maxRedeemable > 0, "INVALID_MAX_REDEEMEABLE");
        require(
            _promoCodes[promoCodeHash].discount == 0,
            "PROMO_ALREADY_EXISTS"
        );

        _promoCodes[promoCodeHash] = PromoCode(
            tier,
            infuencer,
            discount,
            commission,
            maxRedeemable,
            0,
            true
        );
    }

    function updatePromoCode(
        uint256 tier,
        bytes32 promoCodeHash,
        address infuencer,
        uint256 discount,
        uint256 commission,
        uint256 maxRedeemable,
        bool active
    ) external virtual onlyRole(MANAGER_ROLE) nonReentrant {
        require(discount > 0 && discount < 100, "INVALID_DISCOUNT");
        require(commission > 0 && commission < 100, "INVALID_COMMISION");
        require(maxRedeemable > 0, "INVALID_MAX_REDEEMEABLE");
        require(
            _promoCodes[promoCodeHash].discount == 0,
            "PROMO_ALREADY_EXISTS"
        );

        _promoCodes[promoCodeHash] = PromoCode(
            tier,
            infuencer,
            discount,
            commission,
            maxRedeemable,
            _promoCodes[promoCodeHash].totalRedeemed,
            active
        );
    }

    /*##################################################
    ################## PHASE 0 #########################
    ############ AIRDROP TO PARTNERS ###################
    ####################################################
    */

    function createAirdrop(
        bytes32 merkleRoot
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(merkleRoot != bytes32(0), "INVALID_MERKLE_ROOT");
        airdropIndex++;
        _airdrops[airdropIndex] = Airdrop(airdropIndex, merkleRoot);
    }

    function startAirdrop(
        address[] memory recipients,
        uint256[] memory tokenTiers,
        uint256[] memory tierSizes,
        bytes32[][] memory merkleProofs
    ) external virtual onlyRole(MANAGER_ROLE) nonReentrant {
        // Check lengths
        require(
            recipients.length == tokenTiers.length,
            "INVALID_INPUT_LENGTHS"
        );
        require(recipients.length == tierSizes.length, "INVALID_INPUT_LENGTHS");
        require(
            recipients.length == merkleProofs.length,
            "INVALID_INPUT_LENGTHS"
        );
        require(airdropIndex > 0, "AIRDROP_NOT_CREATED");

        for (uint256 idx = 0; idx < recipients.length; idx++) {
            require(
                !_airdropCompleted[recipients[idx]][airdropIndex].completed,
                "ALREADY_COMPLETED"
            );
            require(
                MerkleProofUpgradeable.verify(
                    merkleProofs[idx],
                    _airdrops[airdropIndex].merkleRoot,
                    keccak256(
                        abi.encodePacked(
                            recipients[idx],
                            tokenTiers[idx],
                            tierSizes[idx]
                        )
                    )
                ),
                "USER_NOT_WHITELISTED"
            );
            _mintTier(recipients[idx], tokenTiers[idx], tierSizes[idx]);
            _airdropCompleted[recipients[idx]][airdropIndex] = AirdropCompleted(
                airdropIndex,
                true
            );
        }
    }

    /*##################################################
    ################## PHASE 1 #########################
    ###### FREE CLAIMS - NETVRK NFT STAKERS ############
    ####################################################
    */
    function initPhase1(
        uint256 tokenTier,
        address[] memory recipients,
        uint256[] memory freeClaims,
        uint256 startTime,
        uint256 endTime
    ) external nonReentrant onlyRole(MANAGER_ROLE) {
        require(
            recipients.length == freeClaims.length,
            "INVALID_INPUT_LENGTHS"
        );
        require(tokenTier <= _totalTiers, "TIER_UNAVAILABLE");
        require(startTime < endTime, "INVALID_PRESALE_TIME");

        for (uint256 idx = 0; idx < recipients.length; idx++) {
            _phaseWhitelist[recipients[idx]][tokenTier][1] = PhaseWhiteList(
                freeClaims[idx],
                100,
                0
            );
        }
        _sales[tokenTier][1] = Sale(tokenTier, startTime, endTime);
    }

    // Phase 1: Free claim for whitelisted addresses (address, max qty)
    function mintPhase1(
        uint256 tokenTier,
        uint256 tierSize
    ) external virtual nonReentrant {
        require(tokenTier <= _totalTiers, "TIER_UNAVAILABLE");
        require(_isSaleActive(tokenTier, 1), "SALE_NOT_ACTIVE");
        require(
            _phaseWhitelist[msg.sender][tokenTier][1].maxMint > 0,
            "USER_NOT_WHITELISTED"
        );
        require(
            _phaseWhitelist[msg.sender][tokenTier][1].minted + tierSize <=
                _phaseWhitelist[msg.sender][tokenTier][1].maxMint,
            "MAX_MINT_EXCEEDED"
        );
        _phaseWhitelist[msg.sender][tokenTier][1].minted += tierSize;
        _mintTier(msg.sender, tokenTier, tierSize);
    }

    /*##################################################
    ################## PHASE 2 #########################
    ######## WHITELIST - NETVRK NFT STAKERS ############
    ####################################################
    */

    function initPhase2(
        uint256 tokenTier,
        address[] memory recipients,
        uint256[] memory freeClaims,
        uint256[] memory discounts,
        uint256 startTime,
        uint256 endTime
    ) external nonReentrant onlyRole(MANAGER_ROLE) {
        require(
            recipients.length == freeClaims.length,
            "INVALID_INPUT_LENGTHS"
        );
        require(recipients.length == discounts.length, "INVALID_INPUT_LENGTHS");
        require(tokenTier <= _totalTiers, "TIER_UNAVAILABLE");
        require(startTime < endTime, "INVALID_PRESALE_TIME");

        for (uint256 idx = 0; idx < recipients.length; idx++) {
            _phaseWhitelist[recipients[idx]][tokenTier][2] = PhaseWhiteList(
                freeClaims[idx],
                discounts[idx],
                0
            );
        }
        _sales[tokenTier][2] = Sale(tokenTier, startTime, endTime);
    }

    // Phase 2: Pre-sale for whitelisted addresses w/ bonus pack discounts (address, max qty, discount)
    function mintPhase2(
        uint256 tokenTier,
        uint256 tierSize
    ) external virtual nonReentrant {
        require(tokenTier <= _totalTiers, "TIER_UNAVAILABLE");
        require(_isSaleActive(tokenTier, 2), "SALE_NOT_ACTIVE");
        require(
            _phaseWhitelist[msg.sender][tokenTier][2].maxMint > 0,
            "USER_NOT_WHITELISTED"
        );
        require(
            _phaseWhitelist[msg.sender][tokenTier][2].minted + tierSize <=
                _phaseWhitelist[msg.sender][tokenTier][2].maxMint,
            "MAX_MINT_EXCEEDED"
        );

        // Calculate total cost
        uint256 discount = _phaseWhitelist[msg.sender][tokenTier][2].discount;
        Tier storage tier = _tiers[tokenTier];
        uint256 discountedPrice = tier.price * ((100 - discount) / 100);
        uint256 totalCost = discountedPrice * tierSize;

        // Check if fund is sufficient
        require(
            IERC20(_paymentToken).balanceOf(msg.sender) >= totalCost,
            "INSUFFICIENT_FUND"
        );

        // Transfer token
        IERC20(_paymentToken).transferFrom(
            msg.sender,
            address(this),
            totalCost
        );

        // Update Mint and revenue
        _phaseWhitelist[msg.sender][tokenTier][2].minted += tierSize;
        _totalRevenue = _totalRevenue + totalCost;

        // Mint tier
        _mintTier(msg.sender, tokenTier, tierSize);
    }

    /*##################################################
    ################## PHASE 3 #########################
    ######### WHITELIST - PARTNER PROJECTS #############
    ####################################################
    */

    function initPhase3(
        uint256 tokenTier,
        address[] memory recipients,
        uint256 startTime,
        uint256 endTime,
        uint256 maxPerWallet,
        uint256 maxPerTx
    ) external nonReentrant onlyRole(MANAGER_ROLE) {
        require(tokenTier <= _totalTiers, "TIER_UNAVAILABLE");
        require(startTime < endTime, "INVALID_PRESALE_TIME");
        require(maxPerWallet > 0, "INVALID_MAX_PER_WALLET");
        require(maxPerTx > 0, "INVALID_MAX_PER_TX");

        for (uint256 idx = 0; idx < recipients.length; idx++) {
            _phaseWhitelist[recipients[idx]][tokenTier][3] = PhaseWhiteList(
                maxPerWallet,
                0,
                0
            );
        }
        _sales[tokenTier][3] = Sale(tokenTier, startTime, endTime);
        _tiers[tokenTier].maxPerTx = maxPerTx;
        _tiers[tokenTier].maxPerWallet = maxPerWallet;
    }

    function mintPhase3(
        uint256 tokenTier,
        uint256 tierSize,
        bytes32 promoCodeHash
    ) external virtual nonReentrant {
        require(tokenTier <= _totalTiers, "TIER_UNAVAILABLE");
        require(_isSaleActive(tokenTier, 3), "SALE_NOT_ACTIVE");
        require(
            _phaseWhitelist[msg.sender][tokenTier][3].maxMint > 0,
            "USER_NOT_WHITELISTED"
        );
        require(
            _phaseWhitelist[msg.sender][tokenTier][3].minted + tierSize <=
                _phaseWhitelist[msg.sender][tokenTier][3].maxMint,
            "MAX_MINT_EXCEEDED"
        );

        // Calculate total cost
        Tier storage tier = _tiers[tokenTier];
        uint256 totalCost = 0;
        if (promoCodeHash.length > 0) {
            PromoCode memory promoCode = _promoCodes[promoCodeHash];
            require(promoCode.active == true, "PROMO_NOT_ACTIVE");
            require(
                promoCode.totalRedeemed + tierSize <= promoCode.maxRedeemable,
                "PROMO_MAX_REDEEMABLE_EXCEEDED"
            );
            require(promoCode.tier == tokenTier, "PROMO_DOES_NOT_MATCH_TIER");
            uint256 discountedPrice = tier.price *
                ((100 - promoCode.discount) / 100);
            totalCost = discountedPrice * tierSize;

            // Check if fund is sufficient
            require(
                IERC20(_paymentToken).balanceOf(msg.sender) >= totalCost,
                "INSUFFICIENT_FUND"
            );

            // Update Revenue
            uint256 influencerReward = (discountedPrice *
                promoCode.commission) / 100;
            _influencerBalances[promoCode.influencer] += influencerReward;
            _promoCodes[promoCodeHash].totalRedeemed += tierSize;
            _totalRevenue = _totalRevenue + (totalCost - influencerReward);
        } else {
            // Update Revenue
            totalCost = tier.price * tierSize;

            // Check if fund is sufficient
            require(
                IERC20(_paymentToken).balanceOf(msg.sender) >= totalCost,
                "INSUFFICIENT_FUND"
            );
            // Update Revenue
            _totalRevenue = _totalRevenue + totalCost;
        }

        // Transfer tokens
        IERC20(_paymentToken).transferFrom(
            msg.sender,
            address(this),
            totalCost
        );

        // Update Mint
        _phaseWhitelist[msg.sender][tokenTier][3].minted += tierSize;

        // Mint tier
        _mintTier(msg.sender, tokenTier, tierSize);
    }

    /*##################################################
    ################## PHASE 4 #########################
    ################ PUBLIC SALE #######################
    ####################################################
    */

    function initPhase4(
        uint256 tokenTier,
        uint256 startTime,
        uint256 endTime,
        uint256 maxSupply,
        uint256 maxPerWallet,
        uint256 maxPerTx
    ) external nonReentrant onlyRole(MANAGER_ROLE) {
        require(tokenTier <= _totalTiers, "TIER_UNAVAILABLE");
        require(startTime < endTime, "INVALID_SALE_TIME");
        require(maxSupply > _tiers[tokenTier].supply, "INVALID_SUPPLY");
        require(maxPerWallet > 0, "INVALID_MAX_PER_WALLET");
        require(maxPerTx > 0, "INVALID_MAX_PER_TX");

        _sales[tokenTier][4] = Sale(tokenTier, startTime, endTime);
        _tiers[tokenTier].maxPerTx = maxPerTx;
        _tiers[tokenTier].maxPerWallet = maxPerWallet;
        _tiers[tokenTier].maxSupply = maxSupply;
    }

    function mintPhase4(
        uint256 tokenTier,
        uint256 tierSize,
        bytes32 promoCodeHash
    ) external virtual nonReentrant {
        require(tokenTier <= _totalTiers, "TIER_UNAVAILABLE");
        require(_isSaleActive(tokenTier, 4), "SALE_NOT_ACTIVE");

        // Calculate total cost
        Tier storage tier = _tiers[tokenTier];
        uint256 totalCost = 0;
        if (promoCodeHash.length > 0) {
            PromoCode memory promoCode = _promoCodes[promoCodeHash];
            require(promoCode.active == true, "PROMO_NOT_ACTIVE");
            require(
                promoCode.totalRedeemed + tierSize <= promoCode.maxRedeemable,
                "PROMO_MAX_REDEEMABLE_EXCEEDED"
            );
            require(promoCode.tier == tokenTier, "PROMO_DOES_NOT_MATCH_TIER");
            uint256 discountedPrice = tier.price *
                ((100 - promoCode.discount) / 100);
            totalCost = discountedPrice * tierSize;

            // Check if fund is sufficient
            require(
                IERC20(_paymentToken).balanceOf(msg.sender) >= totalCost,
                "INSUFFICIENT_FUND"
            );

            // Update Revenue
            uint256 influencerReward = (discountedPrice *
                promoCode.commission) / 100;
            _influencerBalances[promoCode.influencer] += influencerReward;
            _promoCodes[promoCodeHash].totalRedeemed += tierSize;
            _totalRevenue = _totalRevenue + (totalCost - influencerReward);
        } else {
            // Update Revenue
            totalCost = tier.price * tierSize;

            // Check if fund is sufficient
            require(
                IERC20(_paymentToken).balanceOf(msg.sender) >= totalCost,
                "INSUFFICIENT_FUND"
            );
            // Update Revenue
            _totalRevenue = _totalRevenue + totalCost;
        }

        // Transfer tokens
        IERC20(_paymentToken).transferFrom(
            msg.sender,
            address(this),
            totalCost
        );

        // Mint tier
        _mintTier(msg.sender, tokenTier, tierSize);
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
        // TODO: Check if this is correct
        if (!_nftPayWhitelist[to]) {
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

    function _isSaleActive(
        uint256 tierId,
        uint256 phase
    ) internal view returns (bool) {
        return
            block.timestamp >= _sales[tierId][phase].saleStart &&
            block.timestamp <= _sales[tierId][phase].saleEnd;
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

    function isSaleActive(
        uint256 tierId,
        uint256 phase
    ) external view virtual returns (bool) {
        return _isSaleActive(tierId, phase);
    }

    function paymentToken() external view virtual returns (address) {
        return _paymentToken;
    }

    function influencerBalances(
        address influencer
    ) external view virtual returns (uint256) {
        return _influencerBalances[influencer];
    }

    function nftPayWhitelist(
        address nftPay
    ) external view virtual returns (bool) {
        return _nftPayWhitelist[nftPay];
    }

    function phaseWhitelisted(
        address wallet,
        uint256 tier,
        uint256 phase
    ) external view virtual returns (PhaseWhiteList memory) {
        return _phaseWhitelist[wallet][tier][phase];
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
        uint256 tierId,
        uint256 phase
    ) external view returns (uint256 saleStart, uint256 saleEnd) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        Sale storage sale = _sales[tierId][phase];
        return (sale.saleStart, sale.saleEnd);
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

    function promoCodeInfo(
        bytes32 promoCodeHash
    ) external view returns (PromoCode memory) {
        require(
            _promoCodes[promoCodeHash].discount > 0,
            "PROMO_DOES_NOT_EXIST"
        );
        PromoCode storage promoCode = _promoCodes[promoCodeHash];
        return promoCode;
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
        override(ERC2981, ERC721EnumerableUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        if (interfaceId == type(IERC2981).interfaceId) {
            return true;
        }
        return super.supportsInterface(interfaceId);
    }

    // UUPS proxy function
    function _authorizeUpgrade(
        address
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
