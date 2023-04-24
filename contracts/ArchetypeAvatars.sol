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
PHASES:
Phase 0: Airdrop
Phase 1: Free claim for whitelisted addresses (address, max qty)
Phase 2: Pre-sale for whitelisted addresses w/ bonus pack discounts (address, max qty, price)
Phase 3: Pre-sale for whitelisted address w/ promo code option (address)
Phase 4: Public sale w/ promo code option
*/

contract ArchetypeAvatars is
    ERC2981,
    AccessControl,
    ReentrancyGuard,
    ERC721Enumerable
{
    using MerkleProof for bytes32[];

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    address private _treasury;
    string private _tokenBaseURI;
    string private _contractURI;
    address private _paymentToken;

    struct Tier {
        uint256 id;
        uint256 price;
        uint256 maxSupply;
        uint256 supply;
    }
    mapping(uint256 => Tier) private _tiers;

    struct Sale {
        uint256 id;
        uint256 saleStart;
        uint256 saleEnd;
    }
    // Tier => Phase => Sale
    mapping(uint256 => mapping(uint256 => Sale)) private _sales;

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
    mapping(string => PromoCode) private _promoCodes;
    mapping(address => uint256) public _influencerBalances;

    struct PhaseWhiteList {
        uint256 maxMint;
        uint256 discount;
        uint256 minted;
    }
    // user => tier/release => phase => whitelist
    mapping(address => mapping(uint256 => mapping(uint256 => PhaseWhiteList)))
        private _phaseWhitelist;

    constructor(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        address treasury_,
        address manager,
        address paymentToken_
    ) ERC721(name_, symbol_) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, manager);

        _tokenBaseURI = baseURI_;
        _treasury = treasury_;
        _totalTiers = 0;
        _paymentToken = paymentToken_;
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

    // Set treasury address
    function updateTreasury(
        address newTreasury
    ) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _treasury = newTreasury;
    }

    // Mint function for extenral airdrop contract
    function bulkMint(
        address[] memory recipients,
        uint256[] memory tierIds,
        uint256[] memory tierSizes
    ) external virtual onlyRole(MINTER_ROLE) {
        require(recipients.length == tierIds.length, "INVALID_INPUT");
        require(recipients.length == tierSizes.length, "INVALID_INPUT");

        for (uint256 idx = 0; idx < recipients.length; idx++) {
            require(tierIds[idx] <= _totalTiers, "TIER_UNAVAILABLE");
            require(tierSizes[idx] > 0, "INVALID_SUPPLY");
            require(
                _tiers[tierIds[idx]].supply + tierSizes[idx] <=
                    _tiers[tierIds[idx]].maxSupply,
                "INVALID_SUPPLY"
            );
            _mintTier(recipients[idx], tierIds[idx], tierSizes[idx]);
        }
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
        uint256 maxSupply
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(id <= _maxTiers, "TIER_UNAVAILABLE");
        require(_tiers[id].id == 0, "TIER_ALREADY_INITIALIZED");
        require(maxSupply > 0, "INVALID_SUPPLY");

        _tiers[id] = Tier(id, price, maxSupply, 0);
        _totalTiers++;
    }

    // Update tier
    function updateTier(
        uint256 id,
        uint256 price,
        uint256 maxSupply
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(id <= _totalTiers, "TIER_UNAVAILABLE");
        require(maxSupply > 0, "INVALID_SUPPLY");
        require(maxSupply > _tiers[id].supply, "INVALID_SUPPLY");

        _tiers[id].price = price;
        _tiers[id].maxSupply = maxSupply;
    }

    // Update sale
    function updateSale(
        uint256 tierId,
        uint256 phase,
        uint256 saleStart,
        uint256 saleEnd
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(_sales[tierId][phase].id != 0, "SALE_NOT_INITIALIZED");
        require(saleStart < saleEnd, "INVALID_SALE_TIME");

        _sales[tierId][phase].saleStart = saleStart;
        _sales[tierId][phase].saleEnd = saleEnd;
    }

    function stopSale(
        uint256 tierId,
        uint256 phase
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(_sales[tierId][phase].id != 0, "SALE_NOT_INITIALIZED");
        _sales[tierId][phase].saleEnd = block.timestamp;
    }

    // Withdraw all amounts (revenue, influencer rewards, etc.)
    function withdraw()
        external
        virtual
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 balance = IERC20(_paymentToken).balanceOf(address(this));
        require(balance > 0, "ZERO_BALANCE");
        IERC20(_paymentToken).transfer(_treasury, balance);
    }

    // Withdraw all revenues
    function withdrawRevenue() external virtual nonReentrant {
        uint256 revenue = _totalRevenue;
        require(revenue > 0, "ZERO_BALANCE");
        _totalRevenue = 0;
        IERC20(_paymentToken).transfer(_treasury, revenue);
    }

    // Withdraw influencer rewards
    function withdrawInfluencerRewards(
        address _infulencer
    ) external virtual nonReentrant {
        uint256 reward = _influencerBalances[_infulencer];
        require(reward > 0, "ZERO_BALANCE");
        _influencerBalances[_infulencer] = 0;
        IERC20(_paymentToken).transfer(_infulencer, reward);
    }

    function updatePromoCode(
        uint256 tier,
        string memory promo,
        address infuencer,
        uint256 discount,
        uint256 commission,
        uint256 maxRedeemable,
        bool active
    ) external virtual onlyRole(MANAGER_ROLE) nonReentrant {
        require(discount < 100, "INVALID_DISCOUNT");
        require(commission < 100, "INVALID_COMMISION");

        _promoCodes[promo] = PromoCode(
            tier,
            infuencer,
            discount,
            commission,
            maxRedeemable,
            _promoCodes[promo].totalRedeemed,
            active
        );
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
        uint256 discountedPrice = (tier.price * (100 - discount)) / 100;
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
        uint256 maxMint
    ) external nonReentrant onlyRole(MANAGER_ROLE) {
        require(tokenTier <= _totalTiers, "TIER_UNAVAILABLE");
        require(startTime < endTime, "INVALID_PRESALE_TIME");
        require(maxMint > 0, "INVALID_MAX_MINT");

        for (uint256 idx = 0; idx < recipients.length; idx++) {
            _phaseWhitelist[recipients[idx]][tokenTier][3] = PhaseWhiteList(
                maxMint,
                0,
                0
            );
        }
        _sales[tokenTier][3] = Sale(tokenTier, startTime, endTime);
    }

    function mintPhase3(
        uint256 tokenTier,
        uint256 tierSize,
        string memory promo
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
        if (bytes(promo).length > 0) {
            PromoCode memory promoCode = _promoCodes[promo];
            require(promoCode.active == true, "PROMO_NOT_ACTIVE");
            require(
                promoCode.totalRedeemed + tierSize <= promoCode.maxRedeemable,
                "PROMO_MAX_REDEEMABLE_EXCEEDED"
            );
            require(promoCode.tier == tokenTier, "PROMO_DOES_NOT_MATCH_TIER");
            uint256 discountedPrice = (tier.price *
                (100 - promoCode.discount)) / 100;
            totalCost = discountedPrice * tierSize;

            // Check if fund is sufficient
            require(
                IERC20(_paymentToken).balanceOf(msg.sender) >= totalCost,
                "INSUFFICIENT_FUND"
            );

            _promoCodes[promo].totalRedeemed += tierSize;
            // Update Revenue
            uint256 influencerReward = (discountedPrice *
                promoCode.commission) / 100;

            _influencerBalances[promoCode.influencer] =
                _influencerBalances[promoCode.influencer] +
                influencerReward;

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
        uint256 maxSupply
    ) external nonReentrant onlyRole(MANAGER_ROLE) {
        require(tokenTier <= _totalTiers, "TIER_UNAVAILABLE");
        require(startTime < endTime, "INVALID_SALE_TIME");
        require(maxSupply > _tiers[tokenTier].supply, "INVALID_SUPPLY");

        _sales[tokenTier][4] = Sale(tokenTier, startTime, endTime);
        _tiers[tokenTier].maxSupply = maxSupply;
    }

    function mintPhase4(
        uint256 tokenTier,
        uint256 tierSize,
        string memory promo
    ) external virtual nonReentrant {
        require(tokenTier <= _totalTiers, "TIER_UNAVAILABLE");
        require(_isSaleActive(tokenTier, 4), "SALE_NOT_ACTIVE");

        // Calculate total cost
        Tier storage tier = _tiers[tokenTier];
        uint256 totalCost = 0;
        if (bytes(promo).length > 0) {
            PromoCode memory promoCode = _promoCodes[promo];
            require(promoCode.active == true, "PROMO_NOT_ACTIVE");
            require(
                promoCode.totalRedeemed + tierSize <= promoCode.maxRedeemable,
                "PROMO_MAX_REDEEMABLE_EXCEEDED"
            );
            require(promoCode.tier == tokenTier, "PROMO_DOES_NOT_MATCH_TIER");
            uint256 discountedPrice = (tier.price *
                (100 - promoCode.discount)) / 100;
            totalCost = discountedPrice * tierSize;

            // Check if fund is sufficient
            require(
                IERC20(_paymentToken).balanceOf(msg.sender) >= totalCost,
                "INSUFFICIENT_FUND"
            );

            // Update Revenue
            uint256 influencerReward = (discountedPrice *
                promoCode.commission) / 100;

            _influencerBalances[promoCode.influencer] =
                _influencerBalances[promoCode.influencer] +
                influencerReward;

            _promoCodes[promo].totalRedeemed += tierSize;
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

    function phaseWhitelisted(
        address wallet,
        uint256 tier,
        uint256 phase
    ) external view virtual returns (PhaseWhiteList memory) {
        return _phaseWhitelist[wallet][tier][phase];
    }

    function tiers(
        uint256 tierId
    ) external view returns (uint256 price, uint256 supply, uint256 maxSupply) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        Tier storage tier = _tiers[tierId];
        return (tier.price, tier.supply, tier.maxSupply);
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
        string memory promo
    ) external view returns (PromoCode memory) {
        PromoCode storage promoCode = _promoCodes[promo];
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
        override(ERC2981, ERC721Enumerable, AccessControl)
        returns (bool)
    {
        if (interfaceId == type(IERC2981).interfaceId) {
            return true;
        }
        return super.supportsInterface(interfaceId);
    }
}
