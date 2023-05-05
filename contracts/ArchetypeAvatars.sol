// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
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
*/

contract ArchetypeAvatars is
    ERC2981,
    AccessControl,
    ReentrancyGuard,
    ERC721Enumerable
{
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    address private _treasury;
    string private _tokenBaseURI;
    string private _contractURI;
    address private _paymentToken;

    // TIER
    struct Tier {
        uint256 id;
        uint256 price;
        uint256 maxSupply;
        uint256 supply;
    }
    mapping(uint256 => Tier) private _tier;

    // TIER BALANCES & REVENUE
    mapping(address => mapping(uint256 => uint256)) private _ownerTierBalance;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        private _ownerTierToken;

    uint256 private _totalRevenue;
    uint256 private constant _maxTiers = 100;
    uint256 private _totalTiers;

    // SALES
    struct Sale {
        uint256 id;
        uint256 startTime;
        uint256 endTime;
    }
    // Tier => Phase => Sale
    mapping(uint256 => mapping(uint256 => Sale)) private _sale;

    // PROMO CODES
    struct PromoCode {
        uint256 tier;
        address influencer;
        uint256 discountPhase3;
        uint256 discountPhase4;
        uint256 commission;
        uint256 maxRedeemable;
        uint256 totalRedeemed;
        bool active;
    }
    mapping(string => PromoCode) private _promoCode;
    mapping(address => uint256) private _influencerRevenue;

    // WHITELIST
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
        address manager_,
        address paymentToken_
    ) ERC721(name_, symbol_) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, manager_);

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
        require(id < _maxTiers, "TIER_UNAVAILABLE");
        require(_tier[id].id == 0, "TIER_ALREADY_INITIALIZED");
        require(maxSupply > 0, "INVALID_MAX_SUPPLY");

        _tier[id] = Tier(id, price, maxSupply, 0);
        _totalTiers++;
    }

    // Update tier
    function updateTier(
        uint256 id,
        uint256 price,
        uint256 maxSupply
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(id <= _totalTiers, "TIER_UNAVAILABLE");
        require(maxSupply > 0, "INVALID_MAX_SUPPLY");
        require(maxSupply > _tier[id].supply, "INVALID_MAX_SUPPLY");

        _tier[id].price = price;
        _tier[id].maxSupply = maxSupply;
    }

    // Update sale
    function updateSale(
        uint256 tierId,
        uint256 phase,
        uint256 startTime,
        uint256 endTime
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(_sale[tierId][phase].id != 0, "SALE_NOT_INITIALIZED");
        require(startTime < endTime, "INVALID_SALE_TIME");

        _sale[tierId][phase].startTime = startTime;
        _sale[tierId][phase].endTime = endTime;
    }

    function stopSale(
        uint256 tierId,
        uint256 phase
    ) external virtual onlyRole(MANAGER_ROLE) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(_sale[tierId][phase].id != 0, "SALE_NOT_INITIALIZED");
        _sale[tierId][phase].endTime = block.timestamp;
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
        require(_totalRevenue > 0, "ZERO_BALANCE");
        IERC20(_paymentToken).transfer(_treasury, _totalRevenue);
        _totalRevenue = 0;
    }

    // Withdraw influencer revenue
    function withdrawInfluencerRevenue(
        address _infulencer
    ) external virtual nonReentrant {
        require(_influencerRevenue[_infulencer] > 0, "ZERO_BALANCE");
        IERC20(_paymentToken).transfer(
            _infulencer,
            _influencerRevenue[_infulencer]
        );
        _influencerRevenue[_infulencer] = 0;
    }

    function updatePromoCode(
        uint256 tier,
        string memory promo,
        address infuencer,
        uint256 discountPhase3,
        uint256 discountPhase4,
        uint256 commission,
        uint256 maxRedeemable,
        bool active
    ) external virtual onlyRole(MANAGER_ROLE) nonReentrant {
        require(tier <= _totalTiers, "TIER_UNAVAILABLE");
        require(bytes(promo).length > 0, "INVALID_PROMO_CODE");
        require(discountPhase3 < 100, "INVALID_DISCOUNT");
        require(discountPhase4 < 100, "INVALID_DISCOUNT");
        require(commission < 100, "INVALID_COMMISION");

        _promoCode[promo] = PromoCode(
            tier,
            infuencer,
            discountPhase3,
            discountPhase4,
            commission,
            maxRedeemable,
            _promoCode[promo].totalRedeemed,
            active
        );
    }

    /*##################################################
    ############ MINT INITIALIZATIONS ##################
    ####################################################
    */
    // PHASE 1: FREE CLAIMS - NETVRK NFT STAKERS

    function updatePhase1(
        uint256 tierId,
        address[] memory recipients,
        uint256[] memory freeClaims,
        uint256 startTime,
        uint256 endTime
    ) external nonReentrant onlyRole(MANAGER_ROLE) {
        require(
            recipients.length == freeClaims.length,
            "INVALID_INPUT_LENGTHS"
        );
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(startTime < endTime, "INVALID_SALE_TIME");
        require(endTime > block.timestamp, "INVALID_SALE_TIME");

        for (uint256 idx = 0; idx < recipients.length; idx++) {
            _phaseWhitelist[recipients[idx]][tierId][1] = PhaseWhiteList(
                freeClaims[idx],
                0,
                0
            );
        }
        _sale[tierId][1] = Sale(tierId, startTime, endTime);
    }

    // PHASE 2: WHITELIST - NETVRK NFT STAKERS

    function updatePhase2(
        uint256 tierId,
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
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(startTime < endTime, "INVALID_SALE_TIME");
        require(endTime > block.timestamp, "INVALID_SALE_TIME");

        for (uint256 idx = 0; idx < recipients.length; idx++) {
            _phaseWhitelist[recipients[idx]][tierId][2] = PhaseWhiteList(
                freeClaims[idx],
                discounts[idx],
                0
            );
        }
        _sale[tierId][2] = Sale(tierId, startTime, endTime);
    }

    // PHASE 3: WHITELIST - WHITELIST - PARTNER PROJECTS

    function updatePhase3(
        uint256 tierId,
        address[] memory recipients,
        uint256 startTime,
        uint256 endTime,
        uint256 maxMint
    ) external nonReentrant onlyRole(MANAGER_ROLE) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(startTime < endTime, "INVALID_SALE_TIME");
        require(endTime > block.timestamp, "INVALID_SALE_TIME");
        require(maxMint > 0, "INVALID_MAX_MINT");

        for (uint256 idx = 0; idx < recipients.length; idx++) {
            _phaseWhitelist[recipients[idx]][tierId][3] = PhaseWhiteList(
                maxMint,
                0,
                0
            );
        }
        _sale[tierId][3] = Sale(tierId, startTime, endTime);
    }

    // PHASE 4: PUBLIC SALE

    function updatePhase4(
        uint256 tierId,
        uint256 startTime,
        uint256 endTime
    ) external nonReentrant onlyRole(MANAGER_ROLE) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(startTime < endTime, "INVALID_SALE_TIME");
        require(endTime > block.timestamp, "INVALID_SALE_TIME");

        _sale[tierId][4] = Sale(tierId, startTime, endTime);
    }

    /*##################################################
    ############### MINT FUNCTIONS #####################
    ####################################################
    */

    // PHASE 0: AIRDROP FROM EXTERNAL CONTRACT

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
                _tier[tierIds[idx]].supply + tierSizes[idx] <=
                    _tier[tierIds[idx]].maxSupply,
                "MAX_SUPPLY_EXCEEDED"
            );
            _mintTier(recipients[idx], tierIds[idx], tierSizes[idx]);
        }
    }

    // PHASE 1: FREE CLAIMS - NETVRK NFT STAKERS

    function mintPhase1(
        uint256 tierId,
        uint256 tierSize
    ) external virtual nonReentrant {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(_isSaleActive(tierId, 1), "SALE_NOT_ACTIVE");
        require(
            _phaseWhitelist[msg.sender][tierId][1].maxMint > 0,
            "USER_NOT_WHITELISTED"
        );
        require(
            _phaseWhitelist[msg.sender][tierId][1].minted + tierSize <=
                _phaseWhitelist[msg.sender][tierId][1].maxMint,
            "MAX_MINT_EXCEEDED"
        );
        // Update minted
        _phaseWhitelist[msg.sender][tierId][1].minted += tierSize;

        // Mint tier
        _mintTier(msg.sender, tierId, tierSize);
    }

    // PHASE 2: WHITELIST - NETVRK NFT STAKERS

    function mintPhase2(
        uint256 tierId,
        uint256 tierSize
    ) external virtual nonReentrant {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(_isSaleActive(tierId, 2), "SALE_NOT_ACTIVE");
        require(
            _phaseWhitelist[msg.sender][tierId][2].maxMint > 0,
            "USER_NOT_WHITELISTED"
        );
        require(
            _phaseWhitelist[msg.sender][tierId][2].minted + tierSize <=
                _phaseWhitelist[msg.sender][tierId][2].maxMint,
            "MAX_MINT_EXCEEDED"
        );

        // Calculate total cost
        uint256 discount = _phaseWhitelist[msg.sender][tierId][2].discount;
        Tier storage tier = _tier[tierId];
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
        _phaseWhitelist[msg.sender][tierId][2].minted += tierSize;
        _totalRevenue = _totalRevenue + totalCost;

        // Mint tier
        _mintTier(msg.sender, tierId, tierSize);
    }

    // PHASE 3: WHITELIST - PARTNER PROJECTS

    function mintPhase3(
        uint256 tierId,
        uint256 tierSize,
        string memory promo
    ) external virtual nonReentrant {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(_isSaleActive(tierId, 3), "SALE_NOT_ACTIVE");
        require(
            _phaseWhitelist[msg.sender][tierId][3].maxMint > 0,
            "USER_NOT_WHITELISTED"
        );
        require(
            _phaseWhitelist[msg.sender][tierId][3].minted + tierSize <=
                _phaseWhitelist[msg.sender][tierId][3].maxMint,
            "MAX_MINT_EXCEEDED"
        );

        // Calculate total cost
        Tier storage tier = _tier[tierId];
        uint256 totalCost = 0;

        // Check Promo
        PromoCode memory promoCode = _promoCode[promo];
        if (promoCode.active) {
            require(promoCode.tier == tierId, "PROMO_INVALID_TIER");
            require(
                promoCode.totalRedeemed + tierSize <= promoCode.maxRedeemable,
                "PROMO_MAX_REDEEMED"
            );

            // Calculate total cost
            uint256 discountedPrice = (tier.price *
                (100 - promoCode.discountPhase3)) / 100;
            totalCost = discountedPrice * tierSize;

            // Check if fund is sufficient
            require(
                IERC20(_paymentToken).balanceOf(msg.sender) >= totalCost,
                "INSUFFICIENT_FUND"
            );

            // Update Revenue and Influencer reward
            uint256 influencerReward = (totalCost * promoCode.commission) / 100;

            _influencerRevenue[promoCode.influencer] =
                _influencerRevenue[promoCode.influencer] +
                influencerReward;

            _totalRevenue = _totalRevenue + (totalCost - influencerReward);

            // Update Promo Redeemed
            _promoCode[promo].totalRedeemed += tierSize;
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
        _phaseWhitelist[msg.sender][tierId][3].minted += tierSize;

        // Mint tier
        _mintTier(msg.sender, tierId, tierSize);
    }

    // PHASE 4: PUBLIC SALE

    function mintPhase4(
        uint256 tierId,
        uint256 tierSize,
        string memory promo
    ) external virtual nonReentrant {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        require(_isSaleActive(tierId, 4), "SALE_NOT_ACTIVE");

        // Calculate total cost
        Tier storage tier = _tier[tierId];
        uint256 totalCost = 0;

        // Check promo code
        PromoCode memory promoCode = _promoCode[promo];
        if (promoCode.active) {
            require(promoCode.tier == tierId, "PROMO_INVALID_TIER");
            require(
                promoCode.totalRedeemed + tierSize <= promoCode.maxRedeemable,
                "PROMO_MAX_REDEEMED"
            );

            // Calculate total cost
            uint256 discountedPrice = (tier.price *
                (100 - promoCode.discountPhase4)) / 100;
            totalCost = discountedPrice * tierSize;

            // Check if fund is sufficient
            require(
                IERC20(_paymentToken).balanceOf(msg.sender) >= totalCost,
                "INSUFFICIENT_FUND"
            );

            // Update Revenue and Infulencer reward
            uint256 influencerReward = (totalCost * promoCode.commission) / 100;

            _influencerRevenue[promoCode.influencer] =
                _influencerRevenue[promoCode.influencer] +
                influencerReward;
            _totalRevenue = _totalRevenue + (totalCost - influencerReward);

            // Update Promo Redeemed
            _promoCode[promo].totalRedeemed += tierSize;
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
        _mintTier(msg.sender, tierId, tierSize);
    }

    /**
    ////////////////////////////////////////////////////
    // Internal Functions 
    ///////////////////////////////////////////////////
    */

    function _mintTier(address to, uint256 tierId, uint256 tokenSize) internal {
        Tier storage tier = _tier[tierId];

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
            _ownerTierToken[to][tierId][
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
            block.timestamp >= _sale[tierId][phase].startTime &&
            block.timestamp <= _sale[tierId][phase].endTime;
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

    function paymentToken() external view virtual returns (address) {
        return _paymentToken;
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

    function influencerRevenue(
        address influencer
    ) external view virtual returns (uint256) {
        return _influencerRevenue[influencer];
    }

    function phaseWhitelisted(
        address wallet,
        uint256 tier,
        uint256 phase
    )
        external
        view
        virtual
        returns (uint256 maxMint, uint256 discount, uint256 minted)
    {
        PhaseWhiteList storage phaseWhitelist = _phaseWhitelist[wallet][tier][
            phase
        ];
        return (
            phaseWhitelist.maxMint,
            phaseWhitelist.discount,
            phaseWhitelist.minted
        );
    }

    function promoInfo(
        string memory promo
    )
        external
        view
        returns (
            uint256 tier,
            address influencer,
            uint256 discountPhase3,
            uint256 discountPhase4,
            uint256 commission,
            uint256 maxRedeemable,
            uint256 totalRedeemed,
            bool active
        )
    {
        PromoCode storage promoCode = _promoCode[promo];
        return (
            promoCode.tier,
            promoCode.influencer,
            promoCode.discountPhase3,
            promoCode.discountPhase4,
            promoCode.commission,
            promoCode.maxRedeemable,
            promoCode.totalRedeemed,
            promoCode.active
        );
    }

    function tierInfo(
        uint256 tierId
    ) external view returns (uint256 price, uint256 supply, uint256 maxSupply) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        Tier storage tier = _tier[tierId];
        return (tier.price, tier.supply, tier.maxSupply);
    }

    function saleInfo(
        uint256 tierId,
        uint256 phase
    ) external view returns (uint256 startTime, uint256 endTime) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        Sale storage sale = _sale[tierId][phase];
        return (sale.startTime, sale.endTime);
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
        return _ownerTierToken[owner][tierId][index];
    }

    function balanceOfTier(
        address owner,
        uint256 tierId
    ) external view returns (uint256) {
        require(tierId <= _totalTiers, "TIER_UNAVAILABLE");
        return _ownerTierBalance[owner][tierId];
    }

    function isSaleActive(
        uint256 tierId,
        uint256 phase
    ) external view virtual returns (bool) {
        return _isSaleActive(tierId, phase);
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
