// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

/// @author thirdweb

import "../openzeppelin-presets/security/ReentrancyGuard.sol";
import "../openzeppelin-presets/utils/math/SafeMath.sol";
import "../eip/interface/IERC1155.sol";

import "./interface/IStaking1155.sol";

abstract contract Staking1155 is ReentrancyGuard, IStaking1155 {
    address public stakingToken;
    uint8 internal isStaking = 1;
    uint256 private nextDefaultConditionId;
    uint256[] public indexedTokens;
    mapping(uint256 => bool) public isIndexed;
    mapping(uint256 => StakingCondition) private defaultCondition;
    mapping(uint256 => uint256) private nextConditionId;
    mapping(uint256 => mapping(address => Staker)) private stakers;
    mapping(uint256 => mapping(address => StakerTiers)) public stakerTiers;
    mapping(uint256 => mapping(uint256 => StakingCondition))
        private stakingConditions;
    mapping(uint256 => address[]) public stakersArray;

    constructor(address _stakingToken) ReentrancyGuard() {
        require(address(_stakingToken) != address(0), "address 0");
        stakingToken = _stakingToken;
    }

    function stake(uint256 _tokenId, uint256 _amount) external nonReentrant {
        _stake(_tokenId, _amount);
    }

    function withdraw(uint256 _tokenId, uint256 _amount) external nonReentrant {
        _withdraw(_tokenId, _amount);
    }

    function claimRewards(uint256 _tokenId) external nonReentrant {
        _claimRewards(_tokenId);
    }

    function setTimeUnit(uint256 _tokenId, uint256 _timeUnit) external virtual {
        if (!_canSetStakeConditions()) {
            revert("Not authorized");
        }

        uint256 _nextConditionId = nextConditionId[_tokenId];
        StakingCondition memory condition = _nextConditionId == 0
            ? defaultCondition[nextDefaultConditionId - 1]
            : stakingConditions[_tokenId][_nextConditionId - 1];
        require(_timeUnit != condition.timeUnit, "Time-unit unchanged.");

        _setStakingCondition(_tokenId, _timeUnit, condition.rewardsPerUnitTime);

        emit UpdatedTimeUnit(_tokenId, condition.timeUnit, _timeUnit);
    }

    function setRewardsPerUnitTime(
        uint256 _tokenId,
        uint256 _rewardsPerUnitTime
    ) internal virtual {
        if (!_canSetStakeConditions()) {
            revert("Not authorized");
        }

        uint256 _nextConditionId = nextConditionId[_tokenId];
        StakingCondition memory condition = _nextConditionId == 0
            ? defaultCondition[nextDefaultConditionId - 1]
            : stakingConditions[_tokenId][_nextConditionId - 1];
        require(
            _rewardsPerUnitTime != condition.rewardsPerUnitTime,
            "Reward unchanged."
        );

        _setStakingCondition(_tokenId, condition.timeUnit, _rewardsPerUnitTime);

        emit UpdatedRewardsPerUnitTime(
            _tokenId,
            condition.rewardsPerUnitTime,
            _rewardsPerUnitTime
        );
    }

    function setDefaultTimeUnit(uint256 _defaultTimeUnit) external virtual {
        if (!_canSetStakeConditions()) {
            revert("Not authorized");
        }

        StakingCondition memory _defaultCondition = defaultCondition[
            nextDefaultConditionId - 1
        ];
        require(
            _defaultTimeUnit != _defaultCondition.timeUnit,
            "Default time-unit unchanged."
        );

        _setDefaultStakingCondition(
            _defaultTimeUnit,
            _defaultCondition.rewardsPerUnitTime
        );

        emit UpdatedDefaultTimeUnit(
            _defaultCondition.timeUnit,
            _defaultTimeUnit
        );
    }

    function setDefaultRewardsPerUnitTime(uint256 _defaultRewardsPerUnitTime)
        external
        virtual
    {
        if (!_canSetStakeConditions()) {
            revert("Not authorized");
        }

        StakingCondition memory _defaultCondition = defaultCondition[
            nextDefaultConditionId - 1
        ];
        require(
            _defaultRewardsPerUnitTime != _defaultCondition.rewardsPerUnitTime,
            "Default reward unchanged."
        );

        _setDefaultStakingCondition(
            _defaultCondition.timeUnit,
            _defaultRewardsPerUnitTime
        );

        emit UpdatedDefaultRewardsPerUnitTime(
            _defaultCondition.rewardsPerUnitTime,
            _defaultRewardsPerUnitTime
        );
    }

    function getStakeInfoForToken(uint256 _tokenId, address _staker)
        external
        view
        virtual
        returns (uint256 _tokensStaked, uint256 _rewards)
    {
        _tokensStaked = stakers[_tokenId][_staker].amountStaked;
        _rewards = _availableRewards(_tokenId, _staker);
    }

    function getUserInfo(address _staker)
        external
        view
        virtual
        returns (
            uint256[] memory _tokensStaked,
            uint256[] memory _tokenAmounts,
            uint256[] memory _stakeTime,
            uint256[] memory _stakeEndTime,
            uint256[] memory _maxRewards,
            uint256[] memory _currentRewards,
            uint256 _totalRewards
        )
    {
        uint256[] memory _indexedTokens = indexedTokens;
        uint256[] memory _stakedAmounts = new uint256[](_indexedTokens.length);
        uint256 indexedTokenCount = _indexedTokens.length;
        uint256 stakerTokenCount = 0;

        for (uint256 i = 0; i < indexedTokenCount; i++) {
            _stakedAmounts[i] = stakers[_indexedTokens[i]][_staker]
                .amountStaked;
            if (_stakedAmounts[i] > 0) stakerTokenCount += 1;
        }

        _currentRewards = new uint256[](stakerTokenCount);
        _tokensStaked = new uint256[](stakerTokenCount);
        _tokenAmounts = new uint256[](stakerTokenCount);
        _stakeTime = new uint256[](stakerTokenCount);
        _stakeEndTime = new uint256[](stakerTokenCount);
        _maxRewards = new uint256[](stakerTokenCount);

        uint256 count = 0;
        for (uint256 i = 0; i < indexedTokenCount; i++) {
            if (_stakedAmounts[i] > 0) {
                _tokensStaked[count] = _indexedTokens[i];
                _tokenAmounts[count] = _stakedAmounts[i];
                _currentRewards[count] = _availableRewards(_indexedTokens[i], _staker);
                _totalRewards += _availableRewards(_indexedTokens[i], _staker);
                _stakeTime[count] = stakerTiers[_indexedTokens[i]][_staker].stakeTime;
                _stakeEndTime[count] = stakerTiers[_indexedTokens[i]][_staker].stakeEndTime;
                _maxRewards[count] = stakerTiers[_indexedTokens[i]][_staker].maxRewards;
                count += 1;
            }
        }
    }

    function getTimeUnit(uint256 _tokenId)
        public
        view
        returns (uint256 _timeUnit)
    {
        uint256 _nextConditionId = nextConditionId[_tokenId];
        require(
            _nextConditionId != 0,
            "Time unit not set. Check default time unit."
        );
        _timeUnit = stakingConditions[_tokenId][_nextConditionId - 1].timeUnit;
    }

    function getRewardsPerUnitTime(uint256 _tokenId)
        public
        view
        returns (uint256 _rewardsPerUnitTime)
    {
        uint256 _nextConditionId = nextConditionId[_tokenId];
        require(
            _nextConditionId != 0,
            "Rewards not set. Check default rewards."
        );
        _rewardsPerUnitTime = stakingConditions[_tokenId][_nextConditionId - 1]
            .rewardsPerUnitTime;
    }

    function getDefaultTimeUnit() public view returns (uint256 _timeUnit) {
        _timeUnit = defaultCondition[nextDefaultConditionId - 1].timeUnit;
    }

    function getDefaultRewardsPerUnitTime()
        public
        view
        returns (uint256 _rewardsPerUnitTime)
    {
        _rewardsPerUnitTime = defaultCondition[nextDefaultConditionId - 1]
            .rewardsPerUnitTime;
    }

    function _stake(uint256 _tokenId, uint256 _amount) internal virtual {
        require(_amount == 1, "Only allowed 1 tokens per stake");
        require(
            stakerTiers[_tokenId][_stakeMsgSender()].amountStaked < 1,
            "Staking more than 1 is not allowed"
        );
        address _stakingToken = stakingToken;
        uint256 defaultEndTime = block.timestamp + (5 minutes);
        stakersArray[_tokenId].push(_stakeMsgSender());
        stakers[_tokenId][_stakeMsgSender()].timeOfLastUpdate = block.timestamp;
        uint256 _conditionId = nextConditionId[_tokenId];
        stakers[_tokenId][_stakeMsgSender()]
            .conditionIdOflastUpdate = _conditionId == 0
            ? nextDefaultConditionId - 1
            : _conditionId - 1;
        require(
            IERC1155(_stakingToken).balanceOf(_stakeMsgSender(), _tokenId) >=
                _amount &&
                IERC1155(_stakingToken).isApprovedForAll(
                    _stakeMsgSender(),
                    address(this)
                ),
            "No balance or approved"
        );
        isStaking = 2;
        IERC1155(_stakingToken).burn(_stakeMsgSender(), _tokenId, _amount);
        isStaking = 1;
        stakers[_tokenId][_stakeMsgSender()].amountStaked += _amount;
        for (uint256 i = 0; i <= 4; i++) {
            if (_tokenId == i) {
                StakerTiers storage staker = stakerTiers[i][msg.sender];

                staker.amountStaked += _amount;
                staker.stakeTime = block.timestamp;
                staker.stakeEndTime = defaultEndTime;
                staker.maxRewards =
                    getRewardsPerUnitTime(_tokenId) *
                    5 *
                    staker.amountStaked;

                break;
            }
        }
        if (!isIndexed[_tokenId]) {
            isIndexed[_tokenId] = true;
            indexedTokens.push(_tokenId);
        }

        emit TokensStaked(_stakeMsgSender(), _tokenId, _amount);
    }

    /// @dev Withdraw logic. Override to add custom logic.
    function _withdraw(uint256 _tokenId, uint256 _amount) internal virtual {
        uint256 _amountStaked = stakers[_tokenId][_stakeMsgSender()].amountStaked;
        require(_amount != 0, "Withdrawing 0 tokens");
        require(_amountStaked >= _amount, "Withdrawing more than staked");
        StakerTiers storage staker = stakerTiers[_tokenId][_stakeMsgSender()];
        // _updateUnclaimedRewardsForStaker(_tokenId, _stakeMsgSender());

        if (_amountStaked == _amount) {
            address[] memory _stakersArray = stakersArray[_tokenId];
            for (uint256 i = 0; i < _stakersArray.length; ++i) {
                if (_stakersArray[i] == _stakeMsgSender()) {
                    stakersArray[_tokenId][i] = _stakersArray[
                        _stakersArray.length - 1
                    ];
                    stakersArray[_tokenId].pop();
                    break;
                }
            }
        }
        stakers[_tokenId][_stakeMsgSender()].amountStaked -= _amount;
        staker.amountStaked -= _amount;
        staker.maxRewards = 0;
        staker.stakeTime = 0;
        staker.stakeEndTime = 0;

        // IERC1155(stakingToken).safeTransferFrom(address(this), _stakeMsgSender(), _tokenId, _amount, "");

        emit TokensWithdrawn(_stakeMsgSender(), _tokenId, _amount);
    }

    /// @dev Logic for claiming rewards. Override to add custom logic.
    function _claimRewards(uint256 _tokenId) internal virtual {
        uint256 rewards = _availableRewards(_tokenId, _stakeMsgSender());
        require(rewards != 0, "No rewards");

        stakers[_tokenId][_stakeMsgSender()].timeOfLastUpdate = block.timestamp;
        stakers[_tokenId][_stakeMsgSender()].unclaimedRewards = 0;

        uint256 _conditionId = nextConditionId[_tokenId];
        stakers[_tokenId][_stakeMsgSender()]
            .conditionIdOflastUpdate = _conditionId == 0
            ? nextDefaultConditionId - 1
            : _conditionId - 1;

        if (rewards < stakerTiers[_tokenId][_stakeMsgSender()].maxRewards) {
            stakerTiers[_tokenId][_stakeMsgSender()].maxRewards -= rewards;
            _mintRewards(_stakeMsgSender(), rewards);
        } else {
            _withdraw(_tokenId, stakers[_tokenId][_stakeMsgSender()].amountStaked);
            _mintRewards(_stakeMsgSender(), rewards);
        }

        emit RewardsClaimed(_stakeMsgSender(), rewards);
    }

    /// @dev View available rewards for a user.
    function _availableRewards(uint256 _tokenId, address _user)
        internal
        view
        virtual
        returns (uint256 _rewards)
    {
        if (stakers[_tokenId][_user].amountStaked == 0) {
            _rewards = stakers[_tokenId][_user].unclaimedRewards;
        }

        uint256 reward = stakers[_tokenId][_user].unclaimedRewards +
            _calculateRewards(_tokenId, _user);
        if (reward < stakerTiers[_tokenId][_user].maxRewards) {
            _rewards = reward;
        } else {
            _rewards = stakerTiers[_tokenId][_user].maxRewards;
        }
    }

    function _calculateRewards(uint256 _tokenId, address _staker)
        internal
        view
        virtual
        returns (uint256 _rewards)
    {
        Staker memory staker = stakers[_tokenId][_staker];
        uint256 _stakerConditionId = staker.conditionIdOflastUpdate;
        uint256 _nextConditionId = nextConditionId[_tokenId];

        if (_nextConditionId == 0) {
            _nextConditionId = nextDefaultConditionId;

            for (uint256 i = _stakerConditionId; i < _nextConditionId; i += 1) {
                StakingCondition memory condition = defaultCondition[i];

                uint256 startTime = i != _stakerConditionId
                    ? condition.startTimestamp
                    : staker.timeOfLastUpdate;
                uint256 endTime = condition.endTimestamp != 0
                    ? condition.endTimestamp
                    : block.timestamp;

                (bool noOverflowProduct, uint256 rewardsProduct) = SafeMath
                    .tryMul(
                        (endTime - startTime) * staker.amountStaked,
                        condition.rewardsPerUnitTime
                    );
                (bool noOverflowSum, uint256 rewardsSum) = SafeMath.tryAdd(
                    _rewards,
                    rewardsProduct / condition.timeUnit
                );

                _rewards = noOverflowProduct && noOverflowSum
                    ? rewardsSum
                    : _rewards;
            }
        } else {
            for (uint256 i = _stakerConditionId; i < _nextConditionId; i += 1) {
                StakingCondition memory condition = stakingConditions[_tokenId][
                    i
                ];

                uint256 startTime = i != _stakerConditionId
                    ? condition.startTimestamp
                    : staker.timeOfLastUpdate;
                uint256 endTime = condition.endTimestamp != 0
                    ? condition.endTimestamp
                    : block.timestamp;

                (bool noOverflowProduct, uint256 rewardsProduct) = SafeMath
                    .tryMul(
                        (endTime - startTime) * staker.amountStaked,
                        condition.rewardsPerUnitTime
                    );
                (bool noOverflowSum, uint256 rewardsSum) = SafeMath.tryAdd(
                    _rewards,
                    rewardsProduct / condition.timeUnit
                );

                _rewards = noOverflowProduct && noOverflowSum
                    ? rewardsSum
                    : _rewards;
            }
        }
    }

    /// @dev Set staking conditions, for a token-Id.
    function _setStakingCondition(
        uint256 _tokenId,
        uint256 _timeUnit,
        uint256 _rewardsPerUnitTime
    ) internal virtual {
        require(_timeUnit != 0, "time-unit can't be 0");
        uint256 conditionId = nextConditionId[_tokenId];

        if (conditionId == 0) {
            uint256 _nextDefaultConditionId = nextDefaultConditionId;
            for (; conditionId < _nextDefaultConditionId; conditionId += 1) {
                StakingCondition memory _defaultCondition = defaultCondition[
                    conditionId
                ];

                stakingConditions[_tokenId][conditionId] = StakingCondition({
                    timeUnit: _defaultCondition.timeUnit,
                    rewardsPerUnitTime: _defaultCondition.rewardsPerUnitTime,
                    startTimestamp: _defaultCondition.startTimestamp,
                    endTimestamp: _defaultCondition.endTimestamp
                });
            }
        }

        stakingConditions[_tokenId][conditionId - 1].endTimestamp = block
            .timestamp;

        stakingConditions[_tokenId][conditionId] = StakingCondition({
            timeUnit: _timeUnit,
            rewardsPerUnitTime: _rewardsPerUnitTime,
            startTimestamp: block.timestamp,
            endTimestamp: 0
        });

        nextConditionId[_tokenId] = conditionId + 1;
    }

    /// @dev Set default staking conditions.
    function _setDefaultStakingCondition(
        uint256 _timeUnit,
        uint256 _rewardsPerUnitTime
    ) internal virtual {
        require(_timeUnit != 0, "time-unit can't be 0");
        uint256 conditionId = nextDefaultConditionId;
        nextDefaultConditionId += 1;

        defaultCondition[conditionId] = StakingCondition({
            timeUnit: _timeUnit,
            rewardsPerUnitTime: _rewardsPerUnitTime,
            startTimestamp: block.timestamp,
            endTimestamp: 0
        });

        if (conditionId > 0) {
            defaultCondition[conditionId - 1].endTimestamp = block.timestamp;
        }
    }

    function _stakeMsgSender() internal virtual returns (address) {
        return msg.sender;
    }

    function getRewardTokenBalance()
        external
        view
        virtual
        returns (uint256 _rewardsAvailableInContract);

    function _mintRewards(address _staker, uint256 _rewards) internal virtual;

    function _canSetStakeConditions() internal view virtual returns (bool);
}
