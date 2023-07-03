// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;



import { ERC1155 } from "../eip/ERC1155.sol";

import "../extension/ContractMetadata.sol";
import "../extension/Ownable.sol";
import "../extension/BatchMintMetadata.sol";
import "../extension/LazyMint.sol";
import "../extension/DefaultOperatorFilterer.sol";

import "../lib/TWStrings.sol";
import "../openzeppelin-presets/security/ReentrancyGuard.sol";
import "./interface/IERCLazyMint.sol";
import { CurrencyTransferLib } from "../lib/CurrencyTransferLib.sol";
import "../eip/interface/IERC20.sol";

contract ERC1155LazyMint is
    ERC1155,
    ContractMetadata,
    Ownable,
    BatchMintMetadata,
    LazyMint,
    DefaultOperatorFilterer,
    ReentrancyGuard,
    IERCLazyMint
{
    using TWStrings for uint256;
    event Log(address sender, uint value, bytes data);
        fallback() external payable {
            emit Log(msg.sender, msg.value, msg.data);
        }
        receive() external payable {
            emit Log(msg.sender, msg.value, "");
        }
    /*//////////////////////////////////////////////////////////////
                        Mappings
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Returns the total supply of NFTs of a given tokenId
     *  @dev Mapping from tokenId => total circulating supply of NFTs of that tokenId.
     */
    mapping(uint256 => uint256) public totalSupply;
    mapping(uint256 => TierMaxSupply) public tierMaxSupply;
    mapping(uint256 => TierCost) public cost;
    address public token;
    bool public presale;
    /*//////////////////////////////////////////////////////////////
                            Constructor
    //////////////////////////////////////////////////////////////*/
    constructor(
        string memory _name,
        string memory _symbol,
        address _token,
        bool _presale
    ) ERC1155(_name, _symbol) {
        _setupOwner(msg.sender);
        _setOperatorRestriction(true);
        token = _token;
        presale = _presale;
    }

    /*//////////////////////////////////////////////////////////////
                    Overriden metadata logic
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the metadata URI for the given tokenId.
    function uri(uint256 _tokenId) public view virtual override returns (string memory) {
        string memory batchUri = _getBaseURI(_tokenId);
        return string(abi.encodePacked(batchUri));
    }
    function withdraw() public payable onlyOwner{
        payable(owner()).transfer(address(this).balance);
    }
    function withdrawToken() public payable onlyOwner{
        CurrencyTransferLib.safeTransferERC20(
            token,
            address(this),
            owner(),
            IERC20(token).balanceOf(address(this))
        );
    }
    /*//////////////////////////////////////////////////////////////
                            CLAIM LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice          Lets an address claim multiple lazy minted NFTs at once to a recipient.
     *                   This function prevents any reentrant calls, and is not allowed to be overridden.
     *
     *                   Contract creators should override `verifyClaim` and `transferTokensOnClaim`
     *                   functions to create custom logic for verification and claiming,
     *                   for e.g. price collection, allowlist, max quantity, etc.
     *
     *  @dev             The logic in `verifyClaim` determines whether the caller is authorized to mint NFTs.
     *                   The logic in `transferTokensOnClaim` does actual minting of tokens,
     *                   can also be used to apply other state changes.
     *
     *  @param _tokenId   The tokenId of the lazy minted NFT to mint.
     *  @param _quantity  The number of tokens to mint.
     */
    function ownerMint(
        uint256 _tokenId,
        uint256 _quantity
    ) public payable virtual nonReentrant onlyOwner {
        require(_tokenId < nextTokenIdToMint(), "invalid id");
        _transferTokensOnClaim(msg.sender, _tokenId, _quantity); 
    }
    function mint(
        uint256 _tokenId,
        uint256 _quantity
    ) public payable virtual nonReentrant {
        require(_tokenId < nextTokenIdToMint(), "invalid id");
        require(totalSupply[_tokenId]+_quantity <= tierMaxSupply[_tokenId].supply, "max supply reached");

        if(presale) {
            require(msg.value == cost[_tokenId].costEth * _quantity, "invalid value");
        } else {
            CurrencyTransferLib.safeTransferERC20(
            token,
            msg.sender,
            address(this),
            cost[_tokenId].costToken * _quantity
        );
        }
        _transferTokensOnClaim(msg.sender, _tokenId, _quantity); 
    }

    function setTierCost(uint256[] memory _tokenId, uint256[] memory _cost, uint256[] memory _pid) external virtual nonReentrant onlyOwner {
        require(_tokenId.length <= nextTokenIdToMint(), "invalid _tokenId");
        for(uint256 i = 0; i < _tokenId.length; i++) {
            if(_pid[i] == 0){
                cost[_tokenId[i]].costEth = _cost[i];
            } else if (_pid[i] == 1){
                cost[_tokenId[i]].costToken = _cost[i];
            } else {
                revert("_pid 0: ethCost, _pid 1: tokenCost");
            }
        }
    }
    function setTierSupply(uint256[] memory _tokenId, uint256[] memory _supplyMax) external virtual nonReentrant onlyOwner {
        require(_tokenId.length <= nextTokenIdToMint(), "invalid _tokenId");
        for(uint256 i = 0; i < _tokenId.length; i++) {
            tierMaxSupply[_tokenId[i]].supply = _supplyMax[i];
        }
    }
    function setPresale(bool _presale) external onlyOwner {
        presale = _presale;
    }
    function setToken(address _token) external onlyOwner {
        token = _token;
    }

    /**
     *  @notice          Override this function to add logic for claim verification, based on conditions
     *                   such as allowlist, price, max quantity etc.
     *
     *  @dev             Checks a request to claim NFTs against a custom condition.
     *
     *  @param _claimer   Caller of the claim function.
     *  @param _tokenId   The tokenId of the lazy minted NFT to mint.
     *  @param _quantity  The number of NFTs being claimed.
     */
    function verifyClaim(
        address _claimer,
        uint256 _tokenId,
        uint256 _quantity
    ) public view virtual {}

    /**
     *  @notice         Lets an owner or approved operator burn NFTs of the given tokenId.
     *
     *  @param _owner   The owner of the NFT to burn.
     *  @param _tokenId The tokenId of the NFT to burn.
     *  @param _amount  The amount of the NFT to burn.
     */
    function burn(
        address _owner,
        uint256 _tokenId,
        uint256 _amount
    ) external override {
        address caller = msg.sender;

        require(caller == _owner || isApprovedForAll[_owner][caller], "Unapproved caller");
        require(balanceOf[_owner][_tokenId] >= _amount, "Not enough tokens owned");

        _burn(_owner, _tokenId, _amount);
    }

    /**
     *  @notice         Lets an owner or approved operator burn NFTs of the given tokenIds.
     *
     *  @param _owner    The owner of the NFTs to burn.
     *  @param _tokenIds The tokenIds of the NFTs to burn.
     *  @param _amounts  The amounts of the NFTs to burn.
     */
    function burnBatch(
        address _owner,
        uint256[] memory _tokenIds,
        uint256[] memory _amounts
    ) external virtual {
        address caller = msg.sender;

        require(caller == _owner || isApprovedForAll[_owner][caller], "Unapproved caller");
        require(_tokenIds.length == _amounts.length, "Length mismatch");

        for (uint256 i = 0; i < _tokenIds.length; i += 1) {
            require(balanceOf[_owner][_tokenIds[i]] >= _amounts[i], "Not enough tokens owned");
        }

        _burnBatch(_owner, _tokenIds, _amounts);
    }


    /*//////////////////////////////////////////////////////////////
                            View functions
    //////////////////////////////////////////////////////////////*/

    /// @notice The tokenId assigned to the next new NFT to be lazy minted.
    function nextTokenIdToMint() public view virtual returns (uint256) {
        return nextTokenIdToLazyMint;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-1155 overrides
    //////////////////////////////////////////////////////////////*/

    /// @dev See {ERC1155-setApprovalForAll}
    function setApprovalForAll(address operator, bool approved)
        public
        virtual
        override(ERC1155)
        onlyAllowedOperatorApproval(operator)
    {
        super.setApprovalForAll(operator, approved);
    }

    /**
     * @dev See {IERC1155-safeTransferFrom}.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) public virtual override(ERC1155) onlyAllowedOperator(from) {
        super.safeTransferFrom(from, to, id, amount, data);
    }

    /**
     * @dev See {IERC1155-safeBatchTransferFrom}.
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public virtual override(ERC1155) onlyAllowedOperator(from) {
        super.safeBatchTransferFrom(from, to, ids, amounts, data);
    }

    /*//////////////////////////////////////////////////////////////
                        Internal functions
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice          Mints tokens to receiver on claim.
     *                   Any state changes related to `claim` must be applied
     *                   here by overriding this function.
     *
     *  @dev             Override this function to add logic for state updation.
     *                   When overriding, apply any state changes before `_mint`.
     */
    function _transferTokensOnClaim(
        address _receiver,
        uint256 _tokenId,
        uint256 _quantity
    ) internal virtual {
        _mint(_receiver, _tokenId, _quantity, "");
    }

    /// @dev Returns whether lazy minting can be done in the given execution context.
    function _canLazyMint() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Returns whether contract metadata can be set in the given execution context.
    function _canSetContractURI() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Returns whether owner can be set in the given execution context.
    function _canSetOwner() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }


    /// @dev Returns whether operator restriction can be set in the given execution context.
    function _canSetOperatorRestriction() internal virtual override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Runs before every token transfer / mint / burn.
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);

        if (from == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                totalSupply[ids[i]] += amounts[i];
            }
        }

        if (to == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                totalSupply[ids[i]] -= amounts[i];
            }
        }
    }
}
