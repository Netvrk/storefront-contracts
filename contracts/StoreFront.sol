// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/MerkleProofUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/MerkleProofUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "hardhat/console.sol";

contract StoreFront is
    ERC2981,
    ContextUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ERC721EnumerableUpgradeable
{
    using MerkleProofUpgradeable for bytes32[];
    using AddressUpgradeable for address;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    address private _treasury;
    string private _tokenBaseURI;
    string private _contractURI;

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

    /**
    ////////////////////////////////////////////////////
    // Admin Functions 
    ///////////////////////////////////////////////////
    */

    function initialize(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        address treasury_,
        address manager
    ) public initializer {
        __ERC721_init(name_, symbol_);
        __ERC721Enumerable_init();
        __UUPSUpgradeable_init();
        __Context_init_unchained();
        __ReentrancyGuard_init_unchained();
        __AccessControl_init_unchained();

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, manager);

        _tokenBaseURI = baseURI_;
        _treasury = treasury_;
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
        require(price > 0, "INVALID_PRICE");
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
        require(price > 0, "INVALID_PRICE");

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
        uint256 balance = address(this).balance;
        AddressUpgradeable.sendValue(payable(_treasury), balance);
    }

    /**
    ////////////////////////////////////////////////////
    // Public Functions 
    ///////////////////////////////////////////////////
    */

    function mint(
        uint256[] memory tokenTiers,
        uint256[] memory tierSizes
    ) external payable virtual nonReentrant {
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

        // Check if fund is sufficient
        require(msg.value >= totalCost, "INSUFFICIENT_FUND");

        // Mint tier
        for (uint256 i = 0; i < tokenTiers.length; i++) {
            _mintTier(msg.sender, tokenTiers[i], tierSizes[i]);
        }

        _totalRevenue = _totalRevenue + msg.value;
    }

    function presaleMint(
        uint256[] memory tokenTiers,
        uint256[] memory tierSizes,
        bytes32[][] calldata merkleProofs
    ) external payable virtual nonReentrant {
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
                MerkleProofUpgradeable.verify(
                    merkleProofs[i],
                    _presales[tierId].merkleRoot,
                    keccak256(abi.encodePacked(_msgSender()))
                ),
                "USER_NOT_WHITELISTED"
            );

            totalCost += tier.price * tokenSize;
        }

        // Check if fund is sufficient
        require(msg.value >= totalCost, "INSUFFICIENT_FUND");

        // Mint tier
        for (uint256 i = 0; i < tokenTiers.length; i++) {
            _mintTier(msg.sender, tokenTiers[i], tierSizes[i]);
        }

        _totalRevenue = _totalRevenue + msg.value;
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
        require(
            _ownerTierBalance[to][tierId] + tokenSize <= tier.maxPerWallet,
            "MAX_PER_WALLET_EXCEEDED"
        );

        // Mint tokens
        for (uint256 j = 0; j < tokenSize; j++) {
            uint256 tokenId = (tier.supply * _maxTiers) + tierId;
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
