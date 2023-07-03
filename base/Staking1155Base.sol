// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;



import "../extension/ContractMetadata.sol";
import "../extension/Multicall.sol";
import "../extension/Ownable.sol";
import "../extension/Staking1155.sol";

import "../eip/ERC165.sol";
import "../eip/interface/IERC20.sol";
import "../eip/interface/IERC1155Receiver.sol";

import { CurrencyTransferLib } from "../lib/CurrencyTransferLib.sol";

/**
 *
 *  EXTENSION: Staking1155
 *
 *  The `Staking1155Base` smart contract implements NFT staking mechanism.
 *  Allows users to stake their ERC-1155 NFTs and earn rewards in form of ERC-20 tokens.
 *
 *  Following features and implementation setup must be noted:
 *
 *      - ERC-1155 NFTs from only one collection can be staked.
 *
 *      - Contract admin can choose to give out rewards by either transferring or minting the rewardToken,
 *        which is an ERC20 token. See {_mintRewards}.
 *
 *      - To implement custom logic for staking, reward calculation, etc. corresponding functions can be
 *        overridden from the extension `Staking1155`.
 *
 *      - Ownership of the contract, with the ability to restrict certain functions to
 *        only be called by the contract's owner.
 *
 *      - Multicall capability to perform multiple actions atomically.
 *
 */

/// note: This contract is provided as a base contract.
//        This is to support a variety of use-cases that can be build on top of this base.
//
//        Additional functionality such as deposit functions, reward-minting, etc.
//        must be implemented by the deployer of this contract, as needed for their use-case.

contract Staking1155Base is ContractMetadata, Multicall, Ownable, Staking1155, ERC165, IERC1155Receiver {
    /// @dev ERC20 Reward Token address. See {_mintRewards} below.
    address public rewardToken;

    /// @dev The address of the native token wrapper contract.
    address internal immutable nativeTokenWrapper;

    /// @dev Total amount of reward tokens in the contract.
    uint256 private rewardTokenBalance;
    uint256 _defaultTimeUnit = 60;
    uint256 _defaultRewardsPerUnitTime = 60;

    constructor(address _stakingToken, address _reward, address _nativeTokenWrapper ) Staking1155(_stakingToken) {
        _setupOwner(msg.sender);
        _setDefaultStakingCondition(_defaultTimeUnit, _defaultRewardsPerUnitTime);
        rewardToken = _reward;
        nativeTokenWrapper = _nativeTokenWrapper;
        for (uint256 i = 0; i<= 4; ++i) {
        uint256 x = 10+i;
        setRewardsPerUnitTime(i, x);
        }
    }

    /// @dev Lets the contract receive ether to unwrap native tokens.
    receive() external payable virtual {
        require(msg.sender == nativeTokenWrapper, "caller not native token wrapper.");
    }

    /// @dev Admin deposits reward tokens.
    function depositRewardTokens(uint256 _amount) external payable virtual nonReentrant {
        _depositRewardTokens(_amount); // override this for custom logic.
    }
    function setsRewardsPerUnitTime(uint256 tok, uint256 rew) external {
        setRewardsPerUnitTime(tok, rew); // override this for custom logic.
    }
    function setStakingToken(address _tokenStaking) external {
        stakingToken = _tokenStaking;
    }
    function setRewardToken(address _reward) external {
        rewardToken = _reward;
    }

    /// @dev Admin can withdraw excess reward tokens.
    function withdrawRewardTokens(uint256 _amount) external virtual nonReentrant {
        _withdrawRewardTokens(_amount); // override this for custom logic.
    }

    /// @notice View total rewards available in the staking contract.
    function getRewardTokenBalance() external view virtual override returns (uint256) {
        return rewardTokenBalance;
    }

    /*///////////////////////////////////////////////////////////////
                        ERC 165 / 721 logic
    //////////////////////////////////////////////////////////////*/

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external view returns (bytes4) {
        require(isStaking == 2, "Direct transfer");
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external virtual returns (bytes4) {}

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                        Minting logic
    //////////////////////////////////////////////////////////////*/

    /**
     *  @dev    Mint ERC20 rewards to the staker. Override for custom logic.
     *
     *  @param _staker    Address for which to calculated rewards.
     *  @param _rewards   Amount of tokens to be given out as reward.
     *
     */
    function _mintRewards(address _staker, uint256 _rewards) internal virtual override {
        require(_rewards <= rewardTokenBalance, "Not enough reward tokens");
        rewardTokenBalance -= _rewards;
        CurrencyTransferLib.transferCurrencyWithWrapper(
            rewardToken,
            address(this),
            _staker,
            _rewards,
            nativeTokenWrapper
        );
    }

    /*//////////////////////////////////////////////////////////////
                        Other Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Admin deposits reward tokens -- override for custom logic.
    function _depositRewardTokens(uint256 _amount) internal virtual {
        require(msg.sender == owner(), "Not authorized");

        address _rewardToken = rewardToken == CurrencyTransferLib.NATIVE_TOKEN ? nativeTokenWrapper : rewardToken;

        uint256 balanceBefore = IERC20(_rewardToken).balanceOf(address(this));
        CurrencyTransferLib.transferCurrencyWithWrapper(
            rewardToken,
            msg.sender,
            address(this),
            _amount,
            nativeTokenWrapper
        );
        uint256 actualAmount = IERC20(_rewardToken).balanceOf(address(this)) - balanceBefore;

        rewardTokenBalance += actualAmount;
    }

    /// @dev Admin can withdraw excess reward tokens -- override for custom logic.
    function _withdrawRewardTokens(uint256 _amount) internal virtual {
        require(msg.sender == owner(), "Not authorized");

        // to prevent locking of direct-transferred tokens
        rewardTokenBalance = _amount > rewardTokenBalance ? 0 : rewardTokenBalance - _amount;

        CurrencyTransferLib.transferCurrencyWithWrapper(
            rewardToken,
            address(this),
            msg.sender,
            _amount,
            nativeTokenWrapper
        );
    }

    /// @dev Returns whether staking restrictions can be set in given execution context.
    function _canSetStakeConditions() internal view virtual override returns (bool) {
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
}