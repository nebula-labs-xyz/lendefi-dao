// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Enhanced Investment Manager V2 (for testing upgrades)
 * @notice Manages investment rounds and token vesting for the ecosystem
 * @dev Implements a secure and upgradeable investment management system
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {IINVMANAGER} from "../interfaces/IInvestmentManager.sol";
import {InvestorVesting} from "../ecosystem/InvestorVesting.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @custom:oz-upgrades-from contracts/ecosystem/InvestmentManager.sol:InvestmentManager
contract InvestmentManagerV2 is
    IINVMANAGER,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using Address for address payable;
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 private constant MAX_INVESTORS_PER_ROUND = 50;
    uint256 private constant MIN_ROUND_DURATION = 5 days;
    uint256 private constant MAX_ROUND_DURATION = 90 days;
    uint256 private constant UPGRADE_TIMELOCK_DURATION = 3 days;

    // ============ Roles ============

    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 private constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 private constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 private constant DAO_ROLE = keccak256("DAO_ROLE");

    // ============ State Variables ============

    IERC20 internal ecosystemToken;
    address public timelock;
    address public treasury;
    uint256 public supply;
    uint32 public version;

    Round[] public rounds;

    mapping(uint32 => address[]) private investors;
    mapping(uint32 => mapping(address => uint256)) private investorPositions;
    mapping(uint32 => mapping(address => address)) private vestingContracts;
    mapping(uint32 => mapping(address => Allocation)) private investorAllocations;
    mapping(uint32 => uint256) private totalRoundAllocations;

    UpgradeRequest private pendingUpgrade;

    uint256[18] private __gap;

    // ============ Modifiers ============

    modifier validRound(uint32 roundId) {
        if (roundId >= rounds.length) revert InvalidRound(roundId);
        _;
    }

    modifier activeRound(uint32 roundId) {
        if (rounds[roundId].status != RoundStatus.ACTIVE) revert RoundNotActive(roundId);
        _;
    }

    modifier correctStatus(uint32 roundId, RoundStatus requiredStatus) {
        if (rounds[roundId].status != requiredStatus) {
            revert InvalidRoundStatus(roundId, requiredStatus, rounds[roundId].status);
        }
        _;
    }

    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddressDetected();
        _;
    }

    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount(amount);
        _;
    }

    // ============ Constructor & Initializer ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {
        uint32 round = getCurrentRound();
        if (round == type(uint32).max) revert NoActiveRound();
        investEther(round);
    }

    function initialize(address token, address timelock_, address treasury_, address guardian, address gnosisSafe)
        external
        initializer
    {
        if (
            token == address(0) || timelock_ == address(0) || treasury_ == address(0) || guardian == address(0)
                || gnosisSafe == address(0)
        ) {
            revert ZeroAddressDetected();
        }
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, timelock_);
        _grantRole(MANAGER_ROLE, gnosisSafe);
        _grantRole(PAUSER_ROLE, guardian);
        _grantRole(DAO_ROLE, timelock_);
        _grantRole(UPGRADER_ROLE, gnosisSafe);

        ecosystemToken = IERC20(token);
        timelock = timelock_;
        treasury = treasury_;
        version = 1;

        emit Initialized(msg.sender);
    }

    // ============ External Functions ============

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function scheduleUpgrade(address newImplementation)
        external
        onlyRole(UPGRADER_ROLE)
        nonZeroAddress(newImplementation)
    {
        uint64 currentTime = uint64(block.timestamp);
        uint64 effectiveTime = currentTime + uint64(UPGRADE_TIMELOCK_DURATION);

        pendingUpgrade = UpgradeRequest({implementation: newImplementation, scheduledTime: currentTime, exists: true});

        emit UpgradeScheduled(msg.sender, newImplementation, currentTime, effectiveTime);
    }

    /**
     * @dev Emergency function to withdraw all tokens to the timelock
     * @param token The ERC20 token to withdraw
     * @notice Only callable by addresses with MANAGER_ROLE
     * @custom:throws ZeroAddressDetected if token address is zero
     * @custom:throws ZeroBalance if contract has no token balance
     */
    function emergencyWithdrawToken(address token) external nonReentrant onlyRole(MANAGER_ROLE) nonZeroAddress(token) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroBalance();

        IERC20(token).safeTransfer(timelock, balance);
        emit EmergencyWithdrawal(token, balance);
    }

    /**
     * @dev Emergency function to withdraw all ETH to the timelock
     * @notice Only callable by addresses with MANAGER_ROLE
     * @custom:throws ZeroBalance if contract has no ETH balance
     */
    function emergencyWithdrawEther() external nonReentrant onlyRole(MANAGER_ROLE) {
        uint256 balance = address(this).balance;
        if (balance == 0) revert ZeroBalance();

        payable(timelock).sendValue(balance);
        emit EmergencyWithdrawal(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, balance);
    }

    function createRound(
        uint64 start,
        uint64 duration,
        uint256 ethTarget,
        uint256 tokenAlloc,
        uint64 vestingCliff,
        uint64 vestingDuration
    ) external onlyRole(DAO_ROLE) whenNotPaused returns (uint32) {
        if (duration < MIN_ROUND_DURATION || duration > MAX_ROUND_DURATION) {
            revert InvalidDuration(duration, MIN_ROUND_DURATION, MAX_ROUND_DURATION);
        }
        if (ethTarget == 0) revert InvalidEthTarget();
        if (tokenAlloc == 0) revert InvalidTokenAllocation();
        if (start < block.timestamp) revert InvalidStartTime(start, block.timestamp);

        supply += tokenAlloc;
        if (ecosystemToken.balanceOf(address(this)) < supply) {
            revert InsufficientSupply(supply, ecosystemToken.balanceOf(address(this)));
        }

        uint64 end = start + duration;
        Round memory newRound = Round({
            etherTarget: ethTarget,
            etherInvested: 0,
            tokenAllocation: tokenAlloc,
            tokenDistributed: 0,
            startTime: start,
            endTime: end,
            vestingCliff: vestingCliff,
            vestingDuration: vestingDuration,
            participants: 0,
            status: RoundStatus.PENDING
        });

        rounds.push(newRound);
        uint32 roundId = uint32(rounds.length - 1);
        totalRoundAllocations[roundId] = 0;

        emit CreateRound(roundId, start, duration, ethTarget, tokenAlloc);
        emit RoundStatusUpdated(roundId, RoundStatus.PENDING);
        return roundId;
    }

    function activateRound(uint32 roundId)
        external
        onlyRole(MANAGER_ROLE)
        validRound(roundId)
        correctStatus(roundId, RoundStatus.PENDING)
        whenNotPaused
    {
        Round storage currentRound = rounds[roundId];
        if (block.timestamp < currentRound.startTime) {
            revert RoundStartTimeNotReached(block.timestamp, currentRound.startTime);
        }
        if (block.timestamp >= currentRound.endTime) {
            revert RoundEndTimeReached(block.timestamp, currentRound.endTime);
        }

        _updateRoundStatus(roundId, RoundStatus.ACTIVE);
    }

    function addInvestorAllocation(uint32 roundId, address investor, uint256 ethAmount, uint256 tokenAmount)
        external
        onlyRole(MANAGER_ROLE)
        validRound(roundId)
        whenNotPaused
    {
        if (investor == address(0)) revert InvalidInvestor();
        if (ethAmount == 0) revert InvalidEthAmount();
        if (tokenAmount == 0) revert InvalidTokenAmount();

        Round storage currentRound = rounds[roundId];
        if (uint8(currentRound.status) >= uint8(RoundStatus.COMPLETED)) {
            revert InvalidRoundStatus(roundId, RoundStatus.ACTIVE, currentRound.status);
        }

        Allocation storage item = investorAllocations[roundId][investor];
        if (item.etherAmount != 0 || item.tokenAmount != 0) {
            revert AllocationExists(investor);
        }

        uint256 newTotal = totalRoundAllocations[roundId] + tokenAmount;
        if (newTotal > currentRound.tokenAllocation) {
            revert ExceedsRoundAllocation(tokenAmount, currentRound.tokenAllocation - totalRoundAllocations[roundId]);
        }

        item.etherAmount = ethAmount;
        item.tokenAmount = tokenAmount;
        totalRoundAllocations[roundId] = newTotal;

        emit InvestorAllocated(roundId, investor, ethAmount, tokenAmount);
    }

    function removeInvestorAllocation(uint32 roundId, address investor)
        external
        onlyRole(MANAGER_ROLE)
        validRound(roundId)
        whenNotPaused
    {
        if (investor == address(0)) revert InvalidInvestor();

        Round storage currentRound = rounds[roundId];

        if (currentRound.status != RoundStatus.PENDING && currentRound.status != RoundStatus.ACTIVE) {
            revert InvalidRoundStatus(roundId, RoundStatus.ACTIVE, currentRound.status);
        }

        Allocation storage item = investorAllocations[roundId][investor];
        uint256 etherAmount = item.etherAmount;
        uint256 tokenAmount = item.tokenAmount;
        if (etherAmount == 0 || tokenAmount == 0) {
            revert NoAllocationExists(investor);
        }

        if (investorPositions[roundId][investor] != 0) {
            revert InvestorHasActivePosition(investor);
        }

        totalRoundAllocations[roundId] -= tokenAmount;
        item.etherAmount = 0;
        item.tokenAmount = 0;
        emit InvestorAllocationRemoved(roundId, investor, etherAmount, tokenAmount);
    }

    function cancelInvestment(uint32 roundId) external validRound(roundId) activeRound(roundId) nonReentrant {
        Round storage currentRound = rounds[roundId];

        uint256 investedAmount = investorPositions[roundId][msg.sender];
        if (investedAmount == 0) revert NoInvestment(msg.sender);

        investorPositions[roundId][msg.sender] = 0;
        currentRound.etherInvested -= investedAmount;
        currentRound.participants--;

        _removeInvestor(roundId, msg.sender);
        emit CancelInvestment(roundId, msg.sender, investedAmount);
        payable(msg.sender).sendValue(investedAmount);
    }

    function finalizeRound(uint32 roundId)
        external
        validRound(roundId)
        correctStatus(roundId, RoundStatus.COMPLETED)
        nonReentrant
        whenNotPaused
    {
        Round storage currentRound = rounds[roundId];

        address[] storage roundInvestors = investors[roundId];
        uint256 investorCount = roundInvestors.length;

        for (uint256 i = 0; i < investorCount;) {
            address investor = roundInvestors[i];
            uint256 investedAmount = investorPositions[roundId][investor];
            if (investedAmount == 0) continue;

            Allocation storage item = investorAllocations[roundId][investor];
            uint256 tokenAmount = item.tokenAmount;

            address vestingContract = _deployVestingContract(investor, tokenAmount, roundId);
            vestingContracts[roundId][investor] = vestingContract;

            ecosystemToken.safeTransfer(vestingContract, tokenAmount);
            currentRound.tokenDistributed += tokenAmount;
            unchecked {
                ++i;
            }
        }

        _updateRoundStatus(roundId, RoundStatus.FINALIZED);

        uint256 amount = currentRound.etherInvested;
        emit RoundFinalized(msg.sender, roundId, amount, currentRound.tokenDistributed);
        payable(treasury).sendValue(amount);
    }

    function cancelRound(uint32 roundId) external validRound(roundId) onlyRole(MANAGER_ROLE) whenNotPaused {
        Round storage currentRound = rounds[roundId];

        if (currentRound.status != RoundStatus.PENDING && currentRound.status != RoundStatus.ACTIVE) {
            revert InvalidRoundStatus(roundId, RoundStatus.ACTIVE, currentRound.status);
        }

        _updateRoundStatus(roundId, RoundStatus.CANCELLED);
        supply -= currentRound.tokenAllocation;
        emit RoundCancelled(roundId);
        ecosystemToken.safeTransfer(treasury, currentRound.tokenAllocation);
    }

    function claimRefund(uint32 roundId) external validRound(roundId) nonReentrant {
        Round storage currentRound = rounds[roundId];
        if (currentRound.status != RoundStatus.CANCELLED) {
            revert RoundNotCancelled(roundId);
        }

        uint256 refundAmount = investorPositions[roundId][msg.sender];
        if (refundAmount == 0) revert NoRefundAvailable(msg.sender);

        investorPositions[roundId][msg.sender] = 0;
        currentRound.etherInvested -= refundAmount;
        if (currentRound.participants > 0) {
            currentRound.participants--;
        }

        _removeInvestor(roundId, msg.sender);
        emit RefundClaimed(roundId, msg.sender, refundAmount);
        payable(msg.sender).sendValue(refundAmount);
    }

    function investEther(uint32 roundId)
        public
        payable
        validRound(roundId)
        activeRound(roundId)
        whenNotPaused
        nonReentrant
    {
        Round storage currentRound = rounds[roundId];
        if (block.timestamp >= currentRound.endTime) revert RoundEnded(roundId);
        if (currentRound.participants >= MAX_INVESTORS_PER_ROUND) revert RoundOversubscribed(roundId);

        Allocation storage allocation = investorAllocations[roundId][msg.sender];
        if (allocation.etherAmount == 0) revert NoAllocation(msg.sender);

        uint256 remainingAllocation = allocation.etherAmount - investorPositions[roundId][msg.sender];
        if (msg.value != remainingAllocation) {
            revert AmountAllocationMismatch(msg.value, remainingAllocation);
        }

        _processInvestment(roundId, msg.sender, msg.value);
    }

    function upgradeTimelockRemaining() external view returns (uint256) {
        return pendingUpgrade.exists && block.timestamp < pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION
            ? pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION - block.timestamp
            : 0;
    }

    function getRefundAmount(uint32 roundId, address investor) external view returns (uint256) {
        if (rounds[roundId].status != RoundStatus.CANCELLED) {
            return 0;
        }
        return investorPositions[roundId][investor];
    }

    function getInvestorDetails(uint32 roundId, address investor)
        external
        view
        returns (uint256 etherAmount, uint256 tokenAmount, uint256 invested, address vestingContract)
    {
        Allocation storage allocation = investorAllocations[roundId][investor];
        return (
            allocation.etherAmount,
            allocation.tokenAmount,
            investorPositions[roundId][investor],
            vestingContracts[roundId][investor]
        );
    }

    /**
     * @dev Returns the address of the ecosystem token
     * @return The address of the token
     */
    function getEcosystemToken() external view returns (address) {
        return address(ecosystemToken);
    }

    function getRoundInfo(uint32 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    function getRoundInvestors(uint32 roundId) external view returns (address[] memory) {
        return investors[roundId];
    }

    function getCurrentRound() public view returns (uint32) {
        uint256 length = rounds.length;
        for (uint32 i = 0; i < length; i++) {
            if (rounds[i].status == RoundStatus.ACTIVE) {
                return i;
            }
        }
        return type(uint32).max;
    }

    // ============ Internal Functions ============

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        if (!pendingUpgrade.exists) {
            revert UpgradeNotScheduled();
        }

        if (pendingUpgrade.implementation != newImplementation) {
            revert ImplementationMismatch(pendingUpgrade.implementation, newImplementation);
        }

        uint256 timeElapsed = block.timestamp - pendingUpgrade.scheduledTime;
        if (timeElapsed < UPGRADE_TIMELOCK_DURATION) {
            revert UpgradeTimelockActive(UPGRADE_TIMELOCK_DURATION - timeElapsed);
        }

        delete pendingUpgrade;
        ++version;

        emit Upgraded(msg.sender, newImplementation, version);
    }

    function _updateRoundStatus(uint32 roundId, RoundStatus newStatus) internal {
        Round storage round_ = rounds[roundId];
        if (uint8(newStatus) <= uint8(round_.status)) {
            revert InvalidStatusTransition(round_.status, newStatus);
        }

        round_.status = newStatus;
        emit RoundStatusUpdated(roundId, newStatus);
    }

    // ============ Private Functions ============

    function _processInvestment(uint32 roundId, address investor, uint256 amount) private {
        Round storage currentRound = rounds[roundId];

        if (investorPositions[roundId][investor] == 0) {
            investors[roundId].push(investor);
            currentRound.participants++;
        }

        investorPositions[roundId][investor] += amount;
        currentRound.etherInvested += amount;

        emit Invest(roundId, investor, amount);

        if (currentRound.etherInvested >= currentRound.etherTarget) {
            _updateRoundStatus(roundId, RoundStatus.COMPLETED);
            emit RoundComplete(roundId);
        }
    }

    function _removeInvestor(uint32 roundId, address investor) private {
        address[] storage roundInvestors = investors[roundId];
        uint256 length = roundInvestors.length;

        for (uint256 i = 0; i < length;) {
            if (roundInvestors[i] == investor) {
                if (i != length - 1) {
                    roundInvestors[i] = roundInvestors[length - 1];
                }
                roundInvestors.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _deployVestingContract(address investor, uint256 allocation, uint32 roundId) private returns (address) {
        Round storage round = rounds[roundId];
        InvestorVesting vestingContract = new InvestorVesting(
            address(ecosystemToken),
            investor,
            uint64(block.timestamp + round.vestingCliff),
            uint64(round.vestingDuration)
        );

        emit DeployVesting(roundId, investor, address(vestingContract), allocation);
        return address(vestingContract);
    }
}
