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

    /**
     * @dev Maximum number of investors allowed per investment round
     * @notice Protects against gas limits when processing all investors during finalization
     */
    uint256 private constant MAX_INVESTORS_PER_ROUND = 50;

    /**
     * @dev Minimum duration for an investment round in seconds
     * @notice Ensures rounds are long enough for investor participation (5 days)
     */
    uint256 private constant MIN_ROUND_DURATION = 5 days;

    /**
     * @dev Maximum duration for an investment round in seconds
     * @notice Prevents overly long rounds that might block capital (90 days)
     */
    uint256 private constant MAX_ROUND_DURATION = 90 days;

    /**
     * @dev Duration of the timelock period for contract upgrades in seconds
     * @notice Provides a security delay before implementation changes can be executed (3 days)
     */
    uint256 private constant UPGRADE_TIMELOCK_DURATION = 3 days;

    // ============ Roles ============

    /**
     * @dev Role identifier for addresses authorized to pause contract functions
     * @notice Typically granted to guardian addresses for emergency security actions
     */
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /**
     * @dev Role identifier for addresses authorized to manage investment operations
     * @notice Can perform administrative functions like emergency withdrawals
     */
    bytes32 private constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /**
     * @dev Role identifier for addresses authorized to upgrade the contract
     * @notice Controls the ability to schedule and execute contract upgrades
     */
    bytes32 private constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @dev Role identifier for addresses representing the DAO's governance
     * @notice Has control over creating investment rounds and major decisions
     */
    bytes32 private constant DAO_ROLE = keccak256("DAO_ROLE");

    // ============ State Variables ============

    /**
     * @dev Reference to the ecosystem's ERC20 token
     * @notice Used for token transfers and vesting distributions
     */
    IERC20 internal ecosystemToken;

    /**
     * @dev Address of the timelock controller
     * @notice Destination for emergency withdrawals and holds elevated permissions
     */
    address public timelock;

    /**
     * @dev Address of the treasury contract
     * @notice Receives ETH from finalized investment rounds
     */
    address public treasury;

    /**
     * @dev Total amount of tokens allocated for investment rounds
     * @notice Tracks the supply commitment for all created rounds
     */
    uint256 public supply;

    /**
     * @dev Implementation version of this contract
     * @notice Incremented on each upgrade to track contract versions
     */
    uint32 public version;

    /**
     * @dev Array of all investment rounds
     * @notice Core data structure that stores round configurations and status
     */
    Round[] public rounds;

    /**
     * @dev Maps round IDs to arrays of investor addresses
     * @notice Used to track all participants in each round
     */
    mapping(uint32 => address[]) private investors;

    /**
     * @dev Maps round IDs and investors to their invested ETH amount
     * @notice Tracks how much each investor has contributed to a round
     */
    mapping(uint32 => mapping(address => uint256)) private investorPositions;

    /**
     * @dev Maps round IDs and investors to their vesting contract addresses
     * @notice Used to track deployed vesting contracts for each investor
     */
    mapping(uint32 => mapping(address => address)) private vestingContracts;

    /**
     * @dev Maps round IDs and investors to their token allocations
     * @notice Stores maximum ETH and token amounts for each investor in a round
     */
    mapping(uint32 => mapping(address => Allocation)) private investorAllocations;

    /**
     * @dev Maps round IDs to the total token allocation for that round
     * @notice Used to ensure round allocations don't exceed limits
     */
    mapping(uint32 => uint256) private totalRoundAllocations;

    /**
     * @dev Holds information about a pending contract upgrade
     * @notice Implements the timelock upgrade security pattern
     */
    UpgradeRequest public pendingUpgrade;

    /**
     * @dev Reserved storage slots for future upgrades
     * @notice Prevents storage collision when adding new variables in upgrades
     */
    uint256[18] private __gap;

    // ============ Modifiers ============

    /**
     * @dev Ensures the provided round ID exists
     * @param roundId The ID of the investment round to check
     * @custom:throws InvalidRound if roundId is out of bounds
     */
    modifier validRound(uint32 roundId) {
        if (roundId >= rounds.length) revert InvalidRound(roundId);
        _;
    }

    /**
     * @dev Ensures the round is in active status
     * @param roundId The ID of the investment round to check
     * @custom:throws RoundNotActive if the round is not active
     */
    modifier activeRound(uint32 roundId) {
        if (rounds[roundId].status != RoundStatus.ACTIVE) revert RoundNotActive(roundId);
        _;
    }

    /**
     * @dev Ensures the round has a specific status
     * @param roundId The ID of the investment round to check
     * @param requiredStatus The status that the round should have
     * @custom:throws InvalidRoundStatus if the round doesn't have the required status
     */
    modifier correctStatus(uint32 roundId, RoundStatus requiredStatus) {
        if (rounds[roundId].status != requiredStatus) {
            revert InvalidRoundStatus(roundId, requiredStatus, rounds[roundId].status);
        }
        _;
    }

    /**
     * @dev Ensures the provided address is not zero
     * @param addr The address to check
     * @custom:throws ZeroAddressDetected if the address is zero
     */
    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddressDetected();
        _;
    }

    /**
     * @dev Ensures the provided amount is not zero
     * @param amount The amount to check
     * @custom:throws InvalidAmount if the amount is zero
     */

    // ============ Constructor & Initializer ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Fallback function that handles direct ETH transfers
     * @notice Automatically invests in the current active round
     * @custom:throws NoActiveRound if no rounds are currently active
     */
    receive() external payable {
        uint32 round = getCurrentRound();
        if (round == type(uint32).max) revert NoActiveRound();
        investEther(round);
    }

    /**
     * @dev Initializes the contract with essential parameters
     * @param token Address of the ecosystem token
     * @param timelock_ Address of the timelock controller
     * @param treasury_ Address of the treasury contract
     * @notice Sets up roles, connects to ecosystem contracts, and initializes version
     * @custom:throws ZeroAddressDetected if any parameter is the zero address
     */
    function initialize(address token, address timelock_, address treasury_) external initializer {
        if (token == address(0) || timelock_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddressDetected();
        }

        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, timelock_);
        _grantRole(MANAGER_ROLE, timelock_);
        _grantRole(PAUSER_ROLE, timelock_);
        _grantRole(UPGRADER_ROLE, timelock_);
        _grantRole(DAO_ROLE, timelock_);

        ecosystemToken = IERC20(token);
        timelock = timelock_;
        treasury = treasury_;
        version = 1;

        emit Initialized(msg.sender);
    }

    // ============ External Functions ============

    /**
     * @notice Pauses the contract's core functionality
     * @dev Only callable by addresses with PAUSER_ROLE
     * @notice When paused, most state-changing functions will revert
     * @notice Emergency functions like withdrawals remain active while paused
     * @custom:requires-role PAUSER_ROLE
     * @custom:events-emits {Paused} event from PausableUpgradeable
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract, resuming normal operations
     * @dev Only callable by addresses with PAUSER_ROLE
     * @notice Re-enables all functionality that was blocked during pause
     * @custom:requires-role PAUSER_ROLE
     * @custom:events-emits {Unpaused} event from PausableUpgradeable
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Schedules an upgrade to a new implementation contract
     * @dev Initiates the timelock period before an upgrade can be executed
     * @param newImplementation Address of the new implementation contract
     * @notice The upgrade cannot be executed until the timelock period has passed
     * @custom:requires-role UPGRADER_ROLE
     * @custom:security Implements a timelock delay for added security
     * @custom:events-emits {UpgradeScheduled} when upgrade is scheduled
     * @custom:throws ZeroAddressDetected if newImplementation is zero address
     * @custom:throws If called by address without UPGRADER_ROLE
     */
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
     * @notice Cancels a previously scheduled upgrade
     * @dev Only callable by addresses with UPGRADER_ROLE
     */
    function cancelUpgrade() external onlyRole(UPGRADER_ROLE) {
        if (!pendingUpgrade.exists) {
            revert UpgradeNotScheduled();
        }
        address implementation = pendingUpgrade.implementation;
        delete pendingUpgrade;
        emit UpgradeCancelled(msg.sender, implementation);
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

    /**
     * @notice Creates a new investment round with specified parameters
     * @dev Only callable by DAO_ROLE when contract is not paused
     * @param start Timestamp when the round should start
     * @param duration Length of the round in seconds
     * @param ethTarget Target amount of ETH to raise in the round
     * @param tokenAlloc Total number of tokens allocated for this round
     * @param vestingCliff Duration in seconds before vesting begins
     * @param vestingDuration Total duration of the vesting period in seconds
     * @return roundId The ID of the newly created round
     * @custom:requires-role DAO_ROLE
     * @custom:security Validates all parameters and checks token supply
     * @custom:events-emits {CreateRound} when round is created
     * @custom:events-emits {RoundStatusUpdated} when round status is set to PENDING
     * @custom:throws InvalidDuration if duration is outside allowed range
     * @custom:throws InvalidEthTarget if ethTarget is zero
     * @custom:throws InvalidTokenAllocation if tokenAlloc is zero
     * @custom:throws InvalidStartTime if start is in the past
     * @custom:throws InsufficientSupply if contract lacks required tokens
     */
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

    /**
     * @notice Activates a pending investment round
     * @dev Only callable by MANAGER_ROLE when contract is not paused
     * @param roundId The ID of the round to activate
     * @custom:requires-role MANAGER_ROLE
     * @custom:security Ensures round exists and is in PENDING status
     * @custom:security Validates round timing constraints
     * @custom:events-emits {RoundStatusUpdated} when round status is set to ACTIVE
     * @custom:modifiers validRound, correctStatus(PENDING), whenNotPaused
     * @custom:throws RoundStartTimeNotReached if current time is before start time
     * @custom:throws RoundEndTimeReached if current time is after end time
     * @custom:throws InvalidRound if roundId doesn't exist
     * @custom:throws InvalidRoundStatus if round is not in PENDING status
     */
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

    /**
     * @notice Adds a new investor allocation to a specific investment round
     * @dev Only callable by MANAGER_ROLE when contract is not paused
     * @param roundId The ID of the investment round
     * @param investor The address of the investor to allocate
     * @param ethAmount Amount of ETH the investor is allowed to invest
     * @param tokenAmount Amount of tokens the investor will receive
     * @custom:requires-role MANAGER_ROLE
     * @custom:security Validates round status and allocation limits
     * @custom:events-emits {InvestorAllocated} when allocation is added
     * @custom:modifiers validRound, whenNotPaused
     * @custom:throws InvalidInvestor if investor address is zero
     * @custom:throws InvalidEthAmount if ethAmount is zero
     * @custom:throws InvalidTokenAmount if tokenAmount is zero
     * @custom:throws InvalidRoundStatus if round is completed or finalized
     * @custom:throws AllocationExists if investor already has an allocation
     * @custom:throws ExceedsRoundAllocation if allocation exceeds round limit
     */
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

    /**
     * @notice Removes an investor's allocation from a specific investment round
     * @dev Only callable by MANAGER_ROLE when contract is not paused
     * @param roundId The ID of the investment round
     * @param investor The address of the investor whose allocation to remove
     * @custom:requires-role MANAGER_ROLE
     * @custom:security Ensures investor has no active position before removal
     * @custom:events-emits {InvestorAllocationRemoved} when allocation is removed
     * @custom:modifiers validRound, whenNotPaused
     * @custom:throws InvalidInvestor if investor address is zero
     * @custom:throws InvalidRoundStatus if round is not in PENDING or ACTIVE status
     * @custom:throws NoAllocationExists if investor has no allocation
     * @custom:throws InvestorHasActivePosition if investor has already invested
     */
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

    /**
     * @notice Allows an investor to cancel their investment in an active round
     * @dev Returns the invested ETH to the investor and updates round state
     * @param roundId The ID of the investment round
     * @custom:security Uses nonReentrant guard for ETH transfers
     * @custom:security Only allows cancellation during active round status
     * @custom:events-emits {CancelInvestment} when investment is cancelled
     * @custom:modifiers validRound, activeRound, nonReentrant
     * @custom:throws NoInvestment if caller has no active investment
     * @custom:throws InvalidRound if roundId doesn't exist
     * @custom:throws RoundNotActive if round is not in active status
     */
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

    /**
     * @notice Finalizes a completed investment round
     * @dev Deploys vesting contracts and distributes tokens to investors
     * @param roundId The ID of the investment round to finalize
     * @custom:security Uses nonReentrant guard for token transfers
     * @custom:security Only callable when contract is not paused
     * @custom:security Processes all investors in the round
     * @custom:events-emits {RoundFinalized} when round is finalized
     * @custom:events-emits {DeployVesting} for each vesting contract created
     * @custom:events-emits {RoundStatusUpdated} when status changes to FINALIZED
     * @custom:modifiers validRound, correctStatus(COMPLETED), nonReentrant, whenNotPaused
     * @custom:throws InvalidRound if roundId doesn't exist
     * @custom:throws InvalidRoundStatus if round is not in COMPLETED status
     */
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

    /**
     * @notice Cancels an investment round and returns tokens to treasury
     * @dev Only callable by MANAGER_ROLE when contract is not paused
     * @param roundId The ID of the investment round to cancel
     * @custom:requires-role MANAGER_ROLE
     * @custom:security Ensures round can only be cancelled in PENDING or ACTIVE status
     * @custom:security Automatically returns allocated tokens to treasury
     * @custom:events-emits {RoundStatusUpdated} when status changes to CANCELLED
     * @custom:events-emits {RoundCancelled} when round is cancelled
     * @custom:modifiers validRound, whenNotPaused
     * @custom:throws InvalidRound if roundId doesn't exist
     * @custom:throws InvalidRoundStatus if round is not in PENDING or ACTIVE status
     */
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

    /**
     * @notice Allows investors to claim ETH refunds from cancelled rounds
     * @dev Refunds the full invested amount and updates round state
     * @param roundId The ID of the investment round
     * @custom:security Uses nonReentrant guard for ETH transfers
     * @custom:security Ensures round is in CANCELLED status
     * @custom:security Updates investor position and round state atomically
     * @custom:events-emits {RefundClaimed} when refund is processed
     * @custom:modifiers validRound, nonReentrant
     * @custom:throws InvalidRound if roundId doesn't exist
     * @custom:throws RoundNotCancelled if round is not in CANCELLED status
     * @custom:throws NoRefundAvailable if caller has no refund to claim
     */
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

    /**
     * @notice Calculates remaining time in the upgrade timelock period
     * @dev Returns 0 if no upgrade is pending or timelock has expired
     * @return uint256 Remaining time in seconds before upgrade can be executed
     * @custom:security Helps track upgrade timelock status
     */
    function upgradeTimelockRemaining() external view returns (uint256) {
        return pendingUpgrade.exists && block.timestamp < pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION
            ? pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION - block.timestamp
            : 0;
    }

    /**
     * @notice Gets the refundable amount for an investor in a cancelled round
     * @dev Returns 0 if round is not cancelled or investor has no position
     * @param roundId The ID of the investment round
     * @param investor The address of the investor to check
     * @return uint256 Amount of ETH available for refund
     * @custom:security Only returns values for cancelled rounds
     */
    function getRefundAmount(uint32 roundId, address investor) external view returns (uint256) {
        return rounds[roundId].status != RoundStatus.CANCELLED ? 0 : investorPositions[roundId][investor];
    }

    /**
     * @notice Retrieves investment details for a specific investor in a round
     * @dev Returns allocation amounts, invested amount, and vesting contract address
     * @param roundId The ID of the investment round to query
     * @param investor The address of the investor to query
     * @return etherAmount The maximum amount of ETH the investor can invest
     * @return tokenAmount The amount of tokens allocated to the investor
     * @return invested The amount of ETH already invested by the investor
     * @return vestingContract The address of the investor's vesting contract
     */
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
     * @notice Gets the address of the ecosystem token
     * @dev Provides access to the token contract address
     * @return address The address of the ecosystem token contract
     */
    function getEcosystemToken() external view returns (address) {
        return address(ecosystemToken);
    }

    /**
     * @notice Retrieves all information about a specific investment round
     * @dev Returns the full Round struct with all round parameters
     * @param roundId The ID of the investment round to query
     * @return Round Complete round information including status and allocations
     */
    function getRoundInfo(uint32 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    /**
     * @notice Gets the list of investors in a specific round
     * @dev Returns array of all investor addresses that participated
     * @param roundId The ID of the investment round to query
     * @return address[] Array of investor addresses in the round
     */
    function getRoundInvestors(uint32 roundId) external view returns (address[] memory) {
        return investors[roundId];
    }

    /**
     * @notice Processes ETH investment in a specific investment round
     * @dev Handles direct investment and fallback function investments
     * @param roundId The ID of the investment round
     * @custom:security Uses nonReentrant guard for ETH transfers
     * @custom:security Validates round status and investor allocation
     * @custom:security Enforces investment limits and round constraints
     * @custom:events-emits {Invest} when investment is processed
     * @custom:events-emits {RoundComplete} if round target is reached
     * @custom:modifiers validRound, activeRound, whenNotPaused, nonReentrant
     * @custom:throws RoundEnded if round end time has passed
     * @custom:throws RoundOversubscribed if maximum investor count reached
     * @custom:throws NoAllocation if sender has no allocation
     * @custom:throws AmountAllocationMismatch if sent ETH doesn't match remaining allocation
     */
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

    /**
     * @notice Gets the ID of the currently active investment round
     * @dev Iterates through all rounds to find one with ACTIVE status
     * @return uint32 The ID of the active round, or type(uint32).max if no active round exists
     * @custom:security Returns max uint32 value as sentinel when no active round is found
     * @custom:view-stability Does not modify state
     */
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

    /**
     * @notice Authorizes and executes a contract upgrade after timelock period
     * @dev Internal function called by the UUPS upgrade mechanism
     * @param newImplementation Address of the new implementation contract
     * @custom:requires-role UPGRADER_ROLE
     * @custom:security Enforces timelock period before upgrade execution
     * @custom:security Verifies upgrade was properly scheduled
     * @custom:security Checks implementation address matches scheduled upgrade
     * @custom:events-emits {Upgraded} when upgrade is executed
     * @custom:throws UpgradeNotScheduled if no upgrade was scheduled
     * @custom:throws ImplementationMismatch if implementation doesn't match scheduled
     * @custom:throws UpgradeTimelockActive if timelock period hasn't elapsed
     */
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

    /**
     * @notice Updates the status of an investment round
     * @dev Internal function to manage round state transitions
     * @param roundId The ID of the investment round to update
     * @param newStatus The new status to set for the round
     * @custom:security Ensures status transitions are only forward-moving
     * @custom:events-emits {RoundStatusUpdated} when status is changed
     * @custom:throws InvalidStatusTransition if attempting to move to a previous status
     */
    function _updateRoundStatus(uint32 roundId, RoundStatus newStatus) internal {
        Round storage round_ = rounds[roundId];
        // Failsafe: This condition should never be true due to validation in calling functions
        if (uint8(newStatus) <= uint8(round_.status)) {
            revert InvalidStatusTransition(round_.status, newStatus);
        }

        round_.status = newStatus;
        emit RoundStatusUpdated(roundId, newStatus);
    }

    // ============ Private Functions ============

    /**
     * @notice Processes an investment into a round
     * @dev Handles investment accounting and status updates
     * @param roundId The ID of the investment round
     * @param investor The address of the investor
     * @param amount The amount of ETH being invested
     * @custom:security Updates investor tracking and round state atomically
     * @custom:events-emits {Invest} when investment is processed
     * @custom:events-emits {RoundComplete} if round target is reached
     */
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

    /**
     * @notice Removes an investor from a round's tracking array
     * @dev Uses optimized removal pattern to maintain array integrity
     * @param roundId The ID of the investment round
     * @param investor The address of the investor to remove
     * @custom:security Maintains array consistency with gas-efficient removal
     */
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

    /**
     * @notice Deploys a new vesting contract for an investor
     * @dev Creates and configures a vesting schedule for allocated tokens
     * @param investor The address of the investor who will receive the tokens
     * @param allocation The amount of tokens to be vested
     * @param roundId The ID of the investment round
     * @return address The address of the newly deployed vesting contract
     * @custom:security Sets up vesting parameters based on round configuration
     * @custom:events-emits {DeployVesting} when vesting contract is created
     */
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
