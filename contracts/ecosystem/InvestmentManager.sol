// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Enhanced Investment Manager
 * @notice Manages investment rounds and token vesting for the ecosystem
 * @dev Implements a secure and upgradeable investment management system
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {ILENDEFI} from "../interfaces/ILendefi.sol";
import {IINVMANAGER} from "../interfaces/IInvestmentManager.sol";
import {InvestorVesting} from "./InvestorVesting.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @custom:oz-upgrades
contract InvestmentManager is
    IINVMANAGER,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using Address for address payable;
    using SafeERC20 for ILENDEFI;
    using SafeCast for uint256;

    // ============ Constants ============

    uint256 private constant MAX_INVESTORS_PER_ROUND = 50;
    uint256 private constant MIN_ROUND_DURATION = 5 days;
    uint256 private constant MAX_ROUND_DURATION = 90 days;

    // ============ Roles ============

    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 private constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 private constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 private constant DAO_ROLE = keccak256("DAO_ROLE");

    // ============ State Variables ============

    ILENDEFI public ecosystemToken;
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

    uint256[45] private __gap;

    // ============ Modifiers ============

    modifier validRound(uint32 roundId) {
        require(roundId < rounds.length, "INVALID_ROUND");
        _;
    }

    modifier activeRound(uint32 roundId) {
        require(rounds[roundId].status == RoundStatus.ACTIVE, "ROUND_NOT_ACTIVE");
        _;
    }

    modifier correctStatus(uint32 roundId, RoundStatus requiredStatus) {
        require(rounds[roundId].status == requiredStatus, "INVALID_ROUND_STATUS");
        _;
    }

    // ============ Constructor & Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Fallback function to handle direct ETH transfers
     * @dev Automatically invests in the current active round
     * @dev Process:
     *      1. Gets current active round number
     *      2. Validates active round exists
     *      3. Forwards ETH to investEther function
     * @dev Requirements:
     *      - At least one round must be active
     *      - Sent ETH must match remaining allocation
     *      - Sender must have valid allocation
     * @custom:throws NO_ACTIVE_ROUND if no round is currently active
     * @custom:throws AMOUNT_ALLOCATION_MISMATCH if sent amount doesn't match allocation
     * @custom:throws NO_ALLOCATION if sender has no allocation
     * @custom:emits Invest when investment is processed
     * @custom:security Forwards to investEther which has reentrancy protection
     * @custom:security Validates round status before processing
     */
    receive() external payable {
        uint32 round = getCurrentRound();
        require(round < type(uint32).max, "NO_ACTIVE_ROUND");
        investEther(round);
    }

    /**
     * @notice Initializes the Investment Manager contract with core dependencies
     * @dev Sets up initial roles and contract references
     * @dev Initialization sequence:
     *      1. Initializes security modules:
     *         - Pausable functionality
     *         - Access control system
     *         - UUPS upgrade mechanism
     *         - Reentrancy protection
     *      2. Validates addresses
     *      3. Sets up roles and permissions
     *      4. Initializes contract references
     *      5. Sets initial version
     * @param token Address of the ecosystem token contract
     * @param timelock_ Address of the timelock contract for governance
     * @param treasury_ Address of the treasury contract
     * @param guardian Address of the initial guardian who receives admin roles
     * @custom:throws ZERO_ADDRESS_DETECTED if any parameter is zero address
     * @custom:security Can only be called once due to initializer modifier
     * @custom:security Sets up critical security features first
     * @custom:security Validates all addresses before use
     * @custom:emits Initialized when setup is complete
     */
    function initialize(address token, address timelock_, address treasury_, address guardian) external initializer {
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(
            token != address(0) && timelock_ != address(0) && treasury_ != address(0) && guardian != address(0),
            "ZERO_ADDRESS_DETECTED"
        );

        _setupRoles(guardian, timelock_);
        _initializeContracts(token, timelock_, treasury_);

        version = 1;
        emit Initialized(msg.sender);
    }

    /**
     * @notice Pauses all contract operations
     * @dev Only callable by accounts with PAUSER_ROLE
     * @dev When paused:
     *      - No new rounds can be created
     *      - No investments can be made
     *      - No rounds can be activated
     *      - No rounds can be finalized
     *      - Cancellations and refunds remain active for security
     * @custom:throws Unauthorized if caller lacks PAUSER_ROLE
     * @custom:emits Paused event with caller's address
     * @custom:security Inherits OpenZeppelin's Pausable implementation
     * @custom:security Role-based access control via PAUSER_ROLE
     * @custom:security Emergency stop mechanism for contract operations
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpauses all contract operations
     * @dev Only callable by accounts with PAUSER_ROLE
     * @dev After unpausing:
     *      - Round creation becomes available
     *      - Investments can be processed
     *      - Round activation allowed
     *      - Round finalization enabled
     *      - Normal contract operations resume
     * @custom:throws Unauthorized if caller lacks PAUSER_ROLE
     * @custom:emits Unpaused event with caller's address
     * @custom:security Inherits OpenZeppelin's Pausable implementation
     * @custom:security Role-based access control via PAUSER_ROLE
     * @custom:security Restores normal contract functionality
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Creates a new investment round with custom vesting parameters
     * @dev Only callable by accounts with DAO_ROLE when contract is not paused
     * @param start The timestamp when the round starts
     * @param duration The duration of the round in seconds
     * @param ethTarget The target amount of ETH to raise
     * @param tokenAlloc The amount of tokens allocated for the round
     * @param vestingCliff The cliff period in seconds before vesting begins
     * @param vestingDuration The total duration of the vesting period in seconds
     * @return roundId The identifier of the newly created round
     * @custom:throws INVALID_DURATION if round duration is outside allowed range
     * @custom:throws INVALID_ETH_TARGET if ethTarget is 0
     * @custom:throws INVALID_TOKEN_ALLOCATION if tokenAlloc is 0
     * @custom:throws INVALID_START_TIME if start is in the past
     * @custom:throws INVALID_VESTING_PARAMETERS if vesting parameters are outside allowed range
     * @custom:throws INSUFFICIENT_SUPPLY if contract doesn't have enough tokens
     * @custom:emits CreateRound when round is created
     * @custom:emits RoundStatusUpdated when round status is set to PENDING
     */
    function createRound(
        uint64 start,
        uint64 duration,
        uint256 ethTarget,
        uint256 tokenAlloc,
        uint64 vestingCliff,
        uint64 vestingDuration
    ) external onlyRole(DAO_ROLE) whenNotPaused returns (uint32) {
        require(duration >= MIN_ROUND_DURATION, "INVALID_DURATION");
        require(duration <= MAX_ROUND_DURATION, "INVALID_DURATION");
        require(ethTarget > 0, "INVALID_ETH_TARGET");
        require(tokenAlloc > 0, "INVALID_TOKEN_ALLOCATION");
        require(start >= block.timestamp, "INVALID_START_TIME");

        supply += tokenAlloc;
        require(ecosystemToken.balanceOf(address(this)) >= supply, "INSUFFICIENT_SUPPLY");

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
     * @dev Only callable by accounts with MANAGER_ROLE
     * @dev Requires:
     *      - Round exists (validRound modifier)
     *      - Round is in PENDING status (correctStatus modifier)
     *      - Contract is not paused (whenNotPaused modifier)
     *      - Current time is within round's time window
     * @param roundId The identifier of the round to activate
     * @custom:throws ROUND_START_TIME_NOT_REACHED if current time is before round start
     * @custom:throws ROUND_END_TIME_REACHED if current time is after round end
     * @custom:throws INVALID_ROUND if roundId is invalid
     * @custom:throws INVALID_ROUND_STATUS if round is not in PENDING status
     * @custom:emits RoundStatusUpdated when round status changes to ACTIVE
     */
    function activateRound(uint32 roundId)
        external
        onlyRole(MANAGER_ROLE)
        validRound(roundId)
        correctStatus(roundId, RoundStatus.PENDING)
        whenNotPaused
    {
        Round storage currentRound = rounds[roundId];
        require(block.timestamp >= currentRound.startTime, "ROUND_START_TIME_NOT_REACHED");
        require(block.timestamp < currentRound.endTime, "ROUND_END_TIME_REACHED");

        _updateRoundStatus(roundId, RoundStatus.ACTIVE);
    }

    /**
     * @notice Adds or updates token allocation for an investor in a specific round
     * @dev Only callable by accounts with MANAGER_ROLE when contract is not paused
     * @dev Requires:
     *      - Round exists (validRound modifier)
     *      - Round is not completed
     *      - Valid investor address
     *      - Non-zero amounts
     *      - Total allocation within round limits
     * @param roundId The identifier of the investment round
     * @param investor The address of the investor receiving the allocation
     * @param ethAmount The amount of ETH being allocated
     * @param tokenAmount The amount of tokens being allocated
     * @custom:throws INVALID_INVESTOR if investor address is zero
     * @custom:throws INVALID_ETH_AMOUNT if ethAmount is zero
     * @custom:throws INVALID_TOKEN_AMOUNT if tokenAmount is zero
     * @custom:throws INVALID_ROUND_STATUS if round is completed or cancelled
     * @custom:throws EXCEEDS_ROUND_ALLOCATION if new total exceeds round allocation
     * @custom:emits InvestorAllocated when allocation is successfully added/updated
     */
    function addInvestorAllocation(uint32 roundId, address investor, uint256 ethAmount, uint256 tokenAmount)
        external
        onlyRole(MANAGER_ROLE)
        validRound(roundId)
        whenNotPaused
    {
        require(investor != address(0), "INVALID_INVESTOR");
        require(ethAmount > 0, "INVALID_ETH_AMOUNT");
        require(tokenAmount > 0, "INVALID_TOKEN_AMOUNT");

        Round storage currentRound = rounds[roundId];
        require(uint8(currentRound.status) < uint8(RoundStatus.COMPLETED), "INVALID_ROUND_STATUS");

        Allocation storage item = investorAllocations[roundId][investor];
        require(item.etherAmount == 0 && item.tokenAmount == 0, "ALLOCATION_EXISTS");

        uint256 newTotal = totalRoundAllocations[roundId] + tokenAmount;
        require(newTotal <= currentRound.tokenAllocation, "EXCEEDS_ROUND_ALLOCATION");

        item.etherAmount = ethAmount;
        item.tokenAmount = tokenAmount;
        totalRoundAllocations[roundId] = newTotal;

        emit InvestorAllocated(roundId, investor, ethAmount, tokenAmount);
    }

    /**
     * @notice Removes an investor's allocation from a specific investment round
     * @dev Only callable by accounts with MANAGER_ROLE when contract is not paused
     * @dev Requirements:
     *      - Round exists (validRound modifier)
     *      - Round is not completed
     *      - Valid investor address
     *      - Allocation exists for investor
     *      - Investor has not made any investments yet
     * @dev State Changes:
     *      - Zeros out investor's allocation
     *      - Decrements total round allocation
     * @param roundId The identifier of the investment round
     * @param investor The address of the investor whose allocation to remove
     * @custom:throws INVALID_INVESTOR if investor address is zero
     * @custom:throws INVALID_ROUND_STATUS if round is completed or cancelled
     * @custom:throws NO_ALLOCATION_EXISTS if investor has no allocation
     * @custom:throws INVESTOR_HAS_ACTIVE_POSITION if investor has already invested
     * @custom:emits InvestorAllocationRemoved when allocation is successfully removed
     * @custom:security Uses validRound modifier to prevent invalid round access
     * @custom:security Updates state before event emission
     * @custom:security Maintains accurate total allocation tracking
     */
    function removeInvestorAllocation(uint32 roundId, address investor)
        external
        onlyRole(MANAGER_ROLE)
        validRound(roundId)
        whenNotPaused
    {
        require(investor != address(0), "INVALID_INVESTOR");

        Round storage currentRound = rounds[roundId];

        require(
            currentRound.status == RoundStatus.PENDING || currentRound.status == RoundStatus.ACTIVE,
            "INVALID_ROUND_STATUS"
        );

        Allocation storage item = investorAllocations[roundId][investor];
        uint256 etherAmount = item.etherAmount;
        uint256 tokenAmount = item.tokenAmount;
        require(etherAmount > 0 && tokenAmount > 0, "NO_ALLOCATION_EXISTS");
        require(investorPositions[roundId][investor] == 0, "INVESTOR_HAS_ACTIVE_POSITION");

        totalRoundAllocations[roundId] -= tokenAmount;
        item.etherAmount = 0;
        item.tokenAmount = 0;
        emit InvestorAllocationRemoved(roundId, investor, etherAmount, tokenAmount);
    }

    /**
     * @notice Allows investors to cancel their investment and receive a refund
     * @dev Processes investment cancellation and ETH refund
     * @dev Requirements:
     *      - Round exists (validRound modifier)
     *      - Round is active (activeRound modifier)
     *      - Protected against reentrancy (nonReentrant modifier)
     *      - Caller must have an active investment
     * @dev State Changes:
     *      - Sets investor's position to 0
     *      - Decrements round's total ETH invested
     *      - Decrements round's participant count
     *      - Removes investor from round's investor list
     * @param roundId The identifier of the round to cancel investment from
     * @custom:throws NO_INVESTMENT if caller has no active investment
     * @custom:emits CancelInvestment when investment is successfully cancelled
     * @custom:security Uses nonReentrant modifier to prevent reentrancy attacks
     * @custom:security Uses Address.sendValue for safe ETH transfer
     * @custom:security Updates state before external calls
     */
    function cancelInvestment(uint32 roundId) external validRound(roundId) activeRound(roundId) nonReentrant {
        Round storage currentRound = rounds[roundId];

        uint256 investedAmount = investorPositions[roundId][msg.sender];
        require(investedAmount > 0, "NO_INVESTMENT");

        investorPositions[roundId][msg.sender] = 0;
        currentRound.etherInvested -= investedAmount;
        currentRound.participants--;

        _removeInvestor(roundId, msg.sender);
        emit CancelInvestment(roundId, msg.sender, investedAmount);
        payable(msg.sender).sendValue(investedAmount);
    }

    /**
     * @notice Finalizes an investment round and deploys vesting contracts for investors
     * @dev Processes token distribution and transfers ETH to treasury
     * @dev Requirements:
     *      - Round exists (validRound modifier)
     *      - Protected against reentrancy (nonReentrant modifier)
     *      - Contract not paused (whenNotPaused modifier)
     *      - Round must be in COMPLETED status
     * @dev Process:
     *      1. Validates round status
     *      2. Iterates through all round investors
     *      3. For each valid investment:
     *         - Calculates token allocation
     *         - Deploys vesting contract
     *         - Transfers tokens to vesting contract
     *         - Updates round token distribution
     *      4. Updates round status to FINALIZED
     *      5. Transfers accumulated ETH to treasury
     * @param roundId The identifier of the round to finalize
     * @custom:throws INVALID_ROUND_STATUS if round is not in COMPLETED status
     * @custom:throws Address: insufficient balance if ETH transfer to treasury fails
     * @custom:emits RoundFinalized with final round statistics
     * @custom:security Uses nonReentrant modifier to prevent reentrancy
     * @custom:security Uses SafeERC20 for token transfers
     * @custom:security Uses unchecked block for gas optimization in loop counter
     */
    function finalizeRound(uint32 roundId) external validRound(roundId) nonReentrant whenNotPaused {
        Round storage currentRound = rounds[roundId];
        require(currentRound.status == RoundStatus.COMPLETED, "INVALID_ROUND_STATUS");

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

        uint256 amount = currentRound.etherInvested; // Cache the value
        emit RoundFinalized(msg.sender, roundId, amount, currentRound.tokenDistributed);
        payable(treasury).sendValue(amount);
    }

    /**
     * @notice Cancels an investment round and returns tokens to treasury
     * @dev Only callable by accounts with MANAGER_ROLE when contract is not paused
     * @dev Requirements:
     *      - Round exists (validRound modifier)
     *      - Round is in PENDING or ACTIVE status
     *      - Caller has MANAGER_ROLE
     *      - Contract is not paused
     * @dev State Changes:
     *      - Updates round status to CANCELLED
     *      - Decrements total token supply
     *      - Transfers round's token allocation back to treasury
     * @param roundId The identifier of the round to cancel
     * @custom:throws INVALID_STATUS_TRANSITION if round is not in PENDING or ACTIVE status
     * @custom:throws INVALID_ROUND if roundId is invalid
     * @custom:emits RoundCancelled when round is successfully cancelled
     * @custom:security Uses SafeERC20 for token transfers
     */
    function cancelRound(uint32 roundId) external validRound(roundId) onlyRole(MANAGER_ROLE) whenNotPaused {
        Round storage currentRound = rounds[roundId];

        require(
            currentRound.status == RoundStatus.PENDING || currentRound.status == RoundStatus.ACTIVE,
            "INVALID_STATUS_TRANSITION"
        );

        // Update round state
        _updateRoundStatus(roundId, RoundStatus.CANCELLED);
        supply -= currentRound.tokenAllocation;
        emit RoundCancelled(roundId);
        ecosystemToken.safeTransfer(treasury, currentRound.tokenAllocation);
    }

    /**
     * @notice Allows investors to claim their refund after round cancellation
     * @dev Processes refund claims and updates round state
     * @dev Requirements:
     *      - Round exists (validRound modifier)
     *      - Protected against reentrancy (nonReentrant modifier)
     *      - Round must be in CANCELLED status
     *      - Caller must have refund available
     * @dev State Changes:
     *      - Sets investor's position to 0
     *      - Decrements round's total ETH invested
     *      - Decrements round's participant count if > 0
     *      - Removes investor from round's investor list
     * @param roundId The identifier of the round to claim refund from
     * @custom:throws ROUND_NOT_CANCELLED if round is not in CANCELLED status
     * @custom:throws NO_REFUND_AVAILABLE if caller has no refund to claim
     * @custom:throws INVALID_ROUND if roundId is invalid
     * @custom:emits RefundClaimed when refund is successfully processed
     * @custom:security Uses nonReentrant modifier to prevent reentrancy attacks
     * @custom:security Uses Address.sendValue for safe ETH transfer
     * @custom:security Updates state before external calls
     */
    function claimRefund(uint32 roundId) external validRound(roundId) nonReentrant {
        Round storage currentRound = rounds[roundId];
        require(currentRound.status == RoundStatus.CANCELLED, "ROUND_NOT_CANCELLED");

        uint256 refundAmount = investorPositions[roundId][msg.sender];
        require(refundAmount > 0, "NO_REFUND_AVAILABLE");

        // Update state before transfer
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
     * @notice Gets the refund amount available for an investor in a cancelled round
     * @dev Returns 0 if round is not cancelled, otherwise returns investor's position
     * @param roundId The identifier of the investment round
     * @param investor The address of the investor to check
     * @return amount The amount of ETH available for refund
     * @custom:security No state modifications
     * @custom:security Safe to call by anyone
     * @custom:security Returns 0 for non-cancelled rounds or non-existent positions
     */
    function getRefundAmount(uint32 roundId, address investor) external view returns (uint256) {
        if (rounds[roundId].status != RoundStatus.CANCELLED) {
            return 0;
        }
        return investorPositions[roundId][investor];
    }

    // ============ View Functions ============

    /**
     * @notice Gets the investment details for an investor in a specific round
     * @param roundId The round identifier
     * @param investor The investor address
     * @return etherAmount The amount of ETH allocated
     * @return tokenAmount The amount of tokens allocated
     * @return invested The amount already invested
     * @return vestingContract The address of the vesting contract (if deployed)
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
     * @notice Retrieves detailed information about a specific investment round
     * @dev Returns complete Round struct with all round parameters and current state
     * @dev Round struct contains:
     *      - etherTarget: Target ETH amount for the round
     *      - etherInvested: Current ETH amount invested
     *      - tokenAllocation: Total tokens allocated for round
     *      - tokenDistributed: Amount of tokens distributed
     *      - startTime: Round start timestamp
     *      - endTime: Round end timestamp
     *      - vestingCliff: Vesting cliff period
     *      - vestingDuration: Total vesting duration
     *      - participants: Current number of investors
     *      - status: Current round status
     * @param roundId The identifier of the round to query
     * @return Round struct containing all round details
     * @custom:security View function - no state modifications
     * @custom:security Safe to call by anyone
     * @custom:security Returns full struct copy - higher gas cost for large data
     */
    function getRoundInfo(uint32 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    /**
     * @notice Gets the complete list of investors for a specific investment round
     * @dev Returns array of all investor addresses that participated in the round
     * @dev Important considerations:
     *      - Returns full array copy - gas cost scales with number of investors
     *      - Array includes all historical investors, even those who cancelled
     *      - Maximum size limited by MAX_INVESTORS_PER_ROUND (50)
     *      - Order of addresses matches investment chronology
     * @param roundId The identifier of the investment round to query
     * @return Array of investor addresses for the specified round
     * @custom:security View function - no state modifications
     * @custom:security Safe to call by anyone
     * @custom:security Returns empty array for invalid roundId
     * @custom:security Memory array bounded by MAX_INVESTORS_PER_ROUND
     */
    function getRoundInvestors(uint32 roundId) external view returns (address[] memory) {
        return investors[roundId];
    }

    /**
     * @notice Allows investors to participate in the current round using ETH
     * @dev Processes ETH investments for allocated participants
     * @dev Requirements:
     *      - Round exists (validRound modifier)
     *      - Round is active (activeRound modifier)
     *      - Contract not paused (whenNotPaused modifier)
     *      - Protected against reentrancy (nonReentrant modifier)
     *      - Round not ended
     *      - Round not oversubscribed
     *      - Investor has allocation
     *      - Exact remaining allocation amount sent
     * @param roundId The identifier of the round to invest in
     * @custom:throws ROUND_ENDED if round end time has passed
     * @custom:throws ROUND_OVERSUBSCRIBED if participant limit reached
     * @custom:throws NO_ALLOCATION if sender has no allocation
     * @custom:throws AMOUNT_ALLOCATION_MISMATCH if sent amount doesn't match remaining allocation
     * @custom:emits Invest when investment is processed successfully
     * @custom:emits RoundComplete when round reaches target after investment
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
        require(block.timestamp < currentRound.endTime, "ROUND_ENDED");
        require(currentRound.participants < MAX_INVESTORS_PER_ROUND, "ROUND_OVERSUBSCRIBED");

        Allocation storage allocation = investorAllocations[roundId][msg.sender];
        require(allocation.etherAmount > 0, "NO_ALLOCATION");

        uint256 remainingAllocation = allocation.etherAmount - investorPositions[roundId][msg.sender];
        require(msg.value == remainingAllocation, "AMOUNT_ALLOCATION_MISMATCH");

        _processInvestment(roundId, msg.sender, msg.value);
    }
    /**
     * @notice Gets the first active round number
     * @dev Iterates through rounds array to find first ACTIVE round
     * @dev Returns type(uint32).max if no active round exists
     * @dev Gas usage increases linearly with number of rounds
     * @dev No state modifications - pure view function
     * @return roundId The first active round number, or type(uint32).max if none found
     * @custom:security Safe to call by anyone
     * @custom:security No state modifications
     * @custom:security Returns max uint32 instead of reverting when no active round
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

    /**
     * @notice Updates the status of an investment round
     * @dev Internal function to manage round status transitions
     * @dev Requirements:
     *      - New status must be higher than current status
     *      - Status transitions are one-way only
     *      - Valid status progression:
     *        PENDING -> ACTIVE -> COMPLETED -> FINALIZED
     *        PENDING/ACTIVE -> CANCELLED
     * @param roundId The identifier of the round to update
     * @param newStatus The new status to set for the round
     * @custom:throws INVALID_STATUS_TRANSITION if attempting invalid status change
     * @custom:emits RoundStatusUpdated when status is successfully changed
     * @custom:security Enforces unidirectional status transitions
     * @custom:security Uses uint8 casting for safe status comparisons
     */
    function _updateRoundStatus(uint32 roundId, RoundStatus newStatus) internal {
        Round storage round_ = rounds[roundId];
        require(uint8(newStatus) > uint8(round_.status), "INVALID_STATUS_TRANSITION");

        round_.status = newStatus;
        emit RoundStatusUpdated(roundId, newStatus);
    }

    // ============ Internal Functions ============
    /**
     * @notice Authorizes and processes contract upgrades
     * @dev Internal override for UUPS upgrade authorization
     * @dev Performs:
     *      1. Validates caller has UPGRADER_ROLE
     *      2. Increments contract version
     *      3. Emits upgrade event with details
     * @param newImplementation Address of the new implementation contract
     * @custom:throws Unauthorized if caller lacks UPGRADER_ROLE
     * @custom:emits Upgrade event with upgrader address and new implementation
     * @custom:security Role-based access control via UPGRADER_ROLE
     * @custom:security Version tracking for upgrade management
     * @custom:security Inherits OpenZeppelin's UUPSUpgradeable pattern
     * @inheritdoc UUPSUpgradeable
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }

    // ============ Private Helper Functions ============
    /**
     * @notice Processes an investment from either ETH or WETH
     * @dev Internal function to handle investment processing and state updates
     * @dev State Changes:
     *      - Adds investor to round's investor list if first investment
     *      - Increments round's participant count for new investors
     *      - Updates investor's position with investment amount
     *      - Updates round's total ETH invested
     *      - Updates round status if target reached
     * @param roundId The identifier of the investment round
     * @param investor The address of the investor making the investment
     * @param amount The amount of ETH/WETH being invested
     * @custom:emits Invest when investment is processed
     * @custom:emits RoundComplete if investment reaches round target
     * @custom:security Updates all state before emitting events
     * @custom:security Handles first-time investor tracking
     * @custom:security Safe arithmetic operations via Solidity 0.8+
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
     * @notice Removes an investor from a round's investor list
     * @dev Internal function using gas-optimized array manipulation
     * @dev Algorithm:
     *      1. Locates investor in round's investor array
     *      2. If found and not last element:
     *         - Moves last element to found position
     *         - Pops last element
     *      3. If found and last element:
     *         - Simply pops last element
     * @dev Gas Optimizations:
     *      - Uses unchecked increment for loop counter
     *      - Minimizes storage reads with length caching
     *      - Uses efficient array pop over delete
     * @param roundId The identifier of the investment round
     * @param investor The address of the investor to remove
     * @custom:security No return value - silently completes if investor not found
     * @custom:security Storage array modification only - no external calls
     * @custom:security Safe array operations via Solidity 0.8+ bounds checking
     */
    function _removeInvestor(uint32 roundId, address investor) private {
        // Get the array of investors for this round
        address[] storage roundInvestors = investors[roundId];
        uint256 length = roundInvestors.length;

        // Find and remove the investor
        for (uint256 i = 0; i < length;) {
            if (roundInvestors[i] == investor) {
                // Move the last element to this position (unless we're already at the last element)
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
     * @notice Sets up initial roles and permissions for contract operation
     * @dev Internal function called during initialization
     * @dev Role assignments:
     *      - Guardian receives:
     *          - DEFAULT_ADMIN_ROLE
     *          - MANAGER_ROLE
     *          - PAUSER_ROLE
     *          - UPGRADER_ROLE
     *      - Timelock receives:
     *          - DAO_ROLE
     * @param guardian Address receiving admin and operational roles
     * @param timelock_ Address receiving governance role
     * @custom:security Uses OpenZeppelin AccessControl
     * @custom:security Critical for establishing permission hierarchy
     * @custom:security Only called once during initialization
     */
    function _setupRoles(address guardian, address timelock_) private {
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(MANAGER_ROLE, guardian);
        _grantRole(PAUSER_ROLE, guardian);
        _grantRole(DAO_ROLE, timelock_);
        _grantRole(UPGRADER_ROLE, guardian);
    }

    /**
     * @notice Initializes core contract references and dependencies
     * @dev Internal function called during contract initialization
     * @dev Sets up:
     *      - Ecosystem token interface
     *      - Timelock contract reference
     *      - Treasury contract reference
     * @param token Address of the ecosystem token contract
     * @param timelock_ Address of the timelock contract for governance
     * @param treasury_ Address of the treasury contract
     * @custom:security Called only once during initialization
     * @custom:security Addresses already validated before call
     * @custom:security Critical for contract functionality
     */
    function _initializeContracts(address token, address timelock_, address treasury_) private {
        ecosystemToken = ILENDEFI(token);
        timelock = timelock_;
        treasury = treasury_;
    }

    /**
     * @notice Deploys vesting contract for an investor with round-specific parameters
     * @dev Internal function to create and configure vesting contracts
     * @dev Process:
     *      1. Retrieves round parameters from storage
     *      2. Creates new InvestorVesting contract instance
     *      3. Configures with:
     *         - Ecosystem token address
     *         - Investor address as beneficiary
     *         - Cliff start time (current time + round cliff)
     *         - Round-specific vesting duration
     *      4. Emits deployment event
     * @param investor The address of the beneficiary for the vesting contract
     * @param allocation The amount of tokens to be vested
     * @param roundId The identifier of the investment round
     * @return address The address of the newly deployed vesting contract
     * @custom:security Uses safe type casting for timestamps
     * @custom:security Emits event before returning for complete audit trail
     * @custom:emits DeployVesting with contract details and allocation
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
