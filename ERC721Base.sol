// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {ERC721A} from "../eip/ERC721A.sol";

import "../extension/ContractMetadata.sol";
import "../extension/Multicall.sol";
import "../extension/Ownable.sol";
import "../extension/Royalty.sol";
import "../extension/BatchMintMetadata.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../lib/TWStrings.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract ERC721Base is
    ERC721A,
    ContractMetadata,
    Multicall,
    Ownable,
    Royalty,
    BatchMintMetadata,
    ReentrancyGuard
{
    using TWStrings for uint256;
    using SafeMath for uint256;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    address payable bank;
    uint256 avaxFee;
    AggregatorV3Interface internal priceFeedAvax;

    /*//////////////////////////////////////////////////////////////
                            Mappings
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 => string) private fullURI;
    mapping(address => uint256) public whitelistAddress;
    mapping(address => string) private companyWalletToName;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event companyNFTMinted(
        uint256 indexed quantity,
        address companyAddress,
        uint256 timestamp
    );

    /*//////////////////////////////////////////////////////////////
                            Constructor
    //////////////////////////////////////////////////////////////*/

    constructor(
        string memory _name,
        string memory _symbol,
        address _royaltyRecipient,
        uint128 _royaltyBps,
        address payable _bank,
        address avaxAggregator
    ) ERC721A(_name, _symbol) {
        _setupOwner(msg.sender);
        _setupDefaultRoyaltyInfo(_royaltyRecipient, _royaltyBps);
        bank = _bank;
        priceFeedAvax = AggregatorV3Interface(avaxAggregator);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC165 Logic
    //////////////////////////////////////////////////////////////*/

    /// @dev See ERC165: https://eips.ethereum.org/EIPS/eip-165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721A, IERC165)
        returns (bool)
    {
        return
            interfaceId == 0x01ffc9a7 || // ERC165 Interface ID for ERC165
            interfaceId == 0x80ac58cd || // ERC165 Interface ID for ERC721
            interfaceId == 0x5b5e139f || // ERC165 Interface ID for ERC721Metadata
            interfaceId == type(IERC2981).interfaceId; // ERC165 ID for ERC2981
    }

    /*//////////////////////////////////////////////////////////////
                        Overriden ERC721 logic
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice         Returns the metadata URI for an NFT.
     *  @dev            See `BatchMintMetadata` for handling of metadata in this contract.
     *
     *  @param _tokenId The tokenId of an NFT.
     */
    function tokenURI(uint256 _tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        string memory fullUriForToken = fullURI[_tokenId];
        if (bytes(fullUriForToken).length > 0) {
            return fullUriForToken;
        }

        string memory batchUri = getBaseURI(_tokenId);
        return string(abi.encodePacked(batchUri, _tokenId.toString()));
    }

    /*//////////////////////////////////////////////////////////////
                            Minting logic
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice          Lets an authorized address mint an NFT to a recipient.
     *  @dev             The logic in the `_canMint` function determines whether the caller is authorized to mint NFTs.
     *
     *  @param _to       The recipient of the NFT to mint.
     *  @param _tokenURI The full metadata URI for the NFT minted.
     */
    function mintTo(address _to, string memory _tokenURI)
        public
        virtual
        nonReentrant
    {
        require(_canMint(), "Not authorized to mint.");
        fullURI[nextTokenIdToMint()] = _tokenURI;
        _safeMint(_to, 1, "");
    }

    /**
     *  @notice          Lets an authorized address mint multiple NFTs at once to a recipient.
     *  @dev             The logic in the `_canMint` function determines whether the caller is authorized to mint NFTs.
     *
     *  @param _to       The recipient of the NFT to mint.
     *  @param _quantity The number of NFTs to mint.
     *  @param _baseURI  The baseURI for the `n` number of NFTs minted. The metadata for each NFT is `baseURI/tokenId`
     *  @param _data     Additional data to pass along during the minting of the NFT.
     *  @dev unWhitelistUser() after nft mint- permissions are unique and added once.
     */
    function batchMintTo(
        address _to,
        uint256 _quantity,
        string memory _baseURI,
        bytes memory _data,
        uint256 indexOfCertificate
    ) public payable virtual nonReentrant {
        if (isWhitelisted(msg.sender)) {
            if (indexOfCertificate == 0) {
                (bool success, ) = bank.call{
                    value: getLatestPrice10() * _quantity
                }("");
                require(success, "cannot send AVAX");
            } else if (indexOfCertificate == 1) {
                (bool success, ) = bank.call{
                    value: getLatestPrice75() * _quantity
                }("");
                require(success, "cannot send AVAX");
            } else if (indexOfCertificate == 2) {
                (bool success, ) = bank.call{
                    value: getLatestPrice200() * _quantity
                }("");
                require(success, "cannot send AVAX");
            }

            _batchMintMetadata(nextTokenIdToMint(), _quantity, _baseURI);
            _safeMint(_to, _quantity, _data);
            unWhitelistUser(msg.sender);
        }

        emit companyNFTMinted(_quantity, msg.sender, block.timestamp);
    }

    /**
     *  @notice         Lets an owner or approved operator burn the NFT of the given tokenId.
     *  @dev            ERC721A's `_burn(uint256,bool)` internally checks for token approvals.
     *
     *  @param _tokenId The tokenId of the NFT to burn.
     */
    function burn(uint256 _tokenId) external virtual {
        _burn(_tokenId, true);
    }

    /*//////////////////////////////////////////////////////////////
                        Withdraw funds
    //////////////////////////////////////////////////////////////*/

    function withdraw(address payable recipient) external payable {
        require(_canMint(), "Not authorized to withdraw.");
        recipient.transfer(address(this).balance);
    }

    /*//////////////////////////////////////////////////////////////
                        Public setters
    //////////////////////////////////////////////////////////////*/

    function whitelistUser(address companyWallet) external {
        whitelistAddress[companyWallet] = 1;
    }

    function unWhitelistUser(address companyWallet) internal {
        whitelistAddress[companyWallet] = 0;
    }

    function matchTheWalletToCompany(address wallet, string memory companyName)
        external
    {
        companyWalletToName[wallet] = companyName;
    }

    /*//////////////////////////////////////////////////////////////
                        Public getters
    //////////////////////////////////////////////////////////////*/

    /// @notice The tokenId assigned to the next new NFT to be minted.
    function nextTokenIdToMint() public view virtual returns (uint256) {
        return _currentIndex;
    }

    /// @notice check if user wallet is whitelisted (inline if statement)

    function isWhitelisted(address userAddress) public view returns (bool) {
        return whitelistAddress[userAddress] != 0 ? true : false;
    }

    /// @notice we pay 3 prices: 10 USD, 75 USD and 200 USD. All in the equivalent of the AVAX token.
    /// The functions correspond to index 0 -> 1 -> 2

    function getLatestPrice10() public view returns (uint256) {
        (
            ,
            /*uint80 roundID*/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = priceFeedAvax.latestRoundData();

        uint256 exactPrice = 1000000000000000000000000000 / uint256(price);

        return exactPrice;
    }

    function getLatestPrice75() public view returns (uint256) {
        (
            ,
            /*uint80 roundID*/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = priceFeedAvax.latestRoundData();

        uint256 exactPrice = 7500000000000000000000000000 / uint256(price);

        return exactPrice;
    }

    function getLatestPrice200() public view returns (uint256) {
        (
            ,
            /*uint80 roundID*/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = priceFeedAvax.latestRoundData();

        uint256 exactPrice = 20000000000000000000000000000 / uint256(price);

        return exactPrice;
    }

    /// @notice returns company name

    function getCompanyNameByWallet(address wallet)
        external
        view
        returns (string memory)
    {
        return companyWalletToName[wallet];
    }

    /*//////////////////////////////////////////////////////////////
                        Internal (overrideable) functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns whether contract metadata can be set in the given execution context.
    function _canSetContractURI()
        internal
        view
        virtual
        override
        returns (bool)
    {
        return msg.sender == owner();
    }

    /// @dev Returns whether a token can be minted in the given execution context.
    function _canMint() internal view virtual returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Returns whether owner can be set in the given execution context.
    function _canSetOwner() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Returns whether royalty info can be set in the given execution context.
    function _canSetRoyaltyInfo()
        internal
        view
        virtual
        override
        returns (bool)
    {
        return msg.sender == owner();
    }
}
