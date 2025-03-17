// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title Investment Manager Interface
 * @notice Interface for the contract that manages investment rounds and token vesting
 * @dev Defines external functions and events for the InvestmentManager contract
 */
interface IINVMANAGER {
    // ============ Enums ============

    /**
     * @dev Enum representing the status of an investment round
     */
    enum RoundStatus {
        PENDING, // Round has been created but not activated
        ACTIVE, // Round is active and accepting investments
        COMPLETED, // Round's funding target has been reached
        CANCELLED, // Round has been cancelled by managers
        FINALIZED // Round is complete and tokens have been distributed

    }

    // ============ Structs ============

    /**
     * @dev Structure containing allocation details for an investor
     */
    struct Allocation {
        uint256 etherAmount; // Amount of ETH allocated
        uint256 tokenAmount; // Amount of tokens allocated
    }

    /**
     * @dev Structure containing details of an investment round
     */
    struct Round {
        uint256 etherTarget; // Target ETH to raise
        uint256 etherInvested; // Current ETH raised
        uint256 tokenAllocation; // Total token allocation for the round
        uint256 tokenDistributed; // Tokens distributed so far
        uint64 startTime; // Start timestamp
        uint64 endTime; // End timestamp
        uint64 vestingCliff; // Vesting cliff period in seconds
        uint64 vestingDuration; // Vesting duration in seconds
        uint32 participants; // Number of participants
        RoundStatus status; // Current status of the round
    }

    /**
     * @dev Structure to track pending upgrades with timelock
     */
    struct UpgradeRequest {
        address implementation; // New implementation address
        uint64 scheduledTime; // When upgrade was scheduled
        bool exists; // Whether an upgrade is scheduled
    }

    // ============ Events ============

    /**
     * @dev Emitted when the contract is initialized
     * @param initializer Address that called initialize
     */
    event Initialized(address indexed initializer);

    /**
     * @dev Emitted when an upgrade is scheduled
     * @param sender Address that scheduled the upgrade
     * @param implementation New implementation address
     * @param scheduledTime Time when upgrade was scheduled
     * @param effectiveTime Time when upgrade can be executed
     */
    event UpgradeScheduled(
        address indexed sender, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );

    /**
     * @notice Emitted when a scheduled upgrade is cancelled
     * @param canceller The address that cancelled the upgrade
     * @param implementation The implementation address that was cancelled
     */
    event UpgradeCancelled(address indexed canceller, address indexed implementation);

    /**
     * @dev Emitted when contract implementation is upgraded
     * @param upgrader Address that performed the upgrade
     * @param implementation New implementation address
     * @param version New version number
     */
    event Upgraded(address indexed upgrader, address indexed implementation, uint32 version);

    /**
     * @dev Emitted when an emergency withdrawal is executed
     * @param token Address of the token withdrawn (ethereum constant for ETH)
     * @param amount Amount withdrawn
     */
    event EmergencyWithdrawal(address indexed token, uint256 amount);

    /**
     * @dev Emitted when a new investment round is created
     * @param roundId ID of the created round
     * @param startTime Start timestamp of the round
     * @param duration Duration in seconds
     * @param etherTarget Target ETH amount
     * @param tokenAllocation Total token allocation
     */
    event CreateRound(
        uint32 indexed roundId, uint64 startTime, uint64 duration, uint256 etherTarget, uint256 tokenAllocation
    );

    /**
     * @dev Emitted when a round's status is updated
     * @param roundId ID of the round
     * @param status New status
     */
    event RoundStatusUpdated(uint32 indexed roundId, RoundStatus status);

    /**
     * @dev Emitted when an investor is allocated in a round
     * @param roundId ID of the round
     * @param investor Address of the investor
     * @param etherAmount ETH allocation amount
     * @param tokenAmount Token allocation amount
     */
    event InvestorAllocated(uint32 indexed roundId, address indexed investor, uint256 etherAmount, uint256 tokenAmount);

    /**
     * @dev Emitted when an investor's allocation is removed
     * @param roundId ID of the round
     * @param investor Address of the investor
     * @param etherAmount ETH allocation amount removed
     * @param tokenAmount Token allocation amount removed
     */
    event InvestorAllocationRemoved(
        uint32 indexed roundId, address indexed investor, uint256 etherAmount, uint256 tokenAmount
    );

    /**
     * @dev Emitted when an investment is cancelled
     * @param roundId ID of the round
     * @param investor Address of the investor
     * @param amount ETH amount returned
     */
    event CancelInvestment(uint32 indexed roundId, address indexed investor, uint256 amount);

    /**
     * @dev Emitted when a round is finalized
     * @param finalizer Address that finalized the round
     * @param roundId ID of the round
     * @param ethAmount Total ETH raised
     * @param tokenAmount Total tokens distributed
     */
    event RoundFinalized(address indexed finalizer, uint32 indexed roundId, uint256 ethAmount, uint256 tokenAmount);

    /**
     * @dev Emitted when a round is cancelled
     * @param roundId ID of the cancelled round
     */
    event RoundCancelled(uint32 indexed roundId);

    /**
     * @dev Emitted when a refund is claimed
     * @param roundId ID of the round
     * @param investor Address of the investor
     * @param amount ETH amount refunded
     */
    event RefundClaimed(uint32 indexed roundId, address indexed investor, uint256 amount);

    /**
     * @dev Emitted when an investment is made
     * @param roundId ID of the round
     * @param investor Address of the investor
     * @param amount ETH amount invested
     */
    event Invest(uint32 indexed roundId, address indexed investor, uint256 amount);

    /**
     * @dev Emitted when a round is completed
     * @param roundId ID of the completed round
     */
    event RoundComplete(uint32 indexed roundId);

    /**
     * @dev Emitted when a vesting contract is deployed
     * @param roundId ID of the round
     * @param investor Address of the investor
     * @param vestingContract Address of the vesting contract
     * @param allocation Token allocation amount
     */
    event DeployVesting(
        uint32 indexed roundId, address indexed investor, address indexed vestingContract, uint256 allocation
    );

    // ============ Errors ============

    /**
     * @dev Error thrown when trying to execute an upgrade before timelock expires
     * @param remainingTime Time remaining until upgrade can be executed
     */
    error UpgradeTimelockActive(uint256 remainingTime);

    /**
     * @dev Error thrown when trying to execute an upgrade that wasn't scheduled
     */
    error UpgradeNotScheduled();

    /**
     * @dev Error thrown when trying to execute an upgrade with wrong implementation
     * @param expected Expected implementation address
     * @param provided Provided implementation address
     */
    error ImplementationMismatch(address expected, address provided);

    /**
     * @dev Error thrown when an invalid round ID is provided
     * @param roundId The invalid round ID
     */
    error InvalidRound(uint32 roundId);

    /**
     * @dev Error thrown when a round is not in active status
     * @param roundId The round ID
     */
    error RoundNotActive(uint32 roundId);

    /**
     * @dev Error thrown when a round is in the wrong status
     * @param roundId The round ID
     * @param requiredStatus Required status
     * @param currentStatus Current status
     */
    error InvalidRoundStatus(uint32 roundId, RoundStatus requiredStatus, RoundStatus currentStatus);

    /**
     * @dev Error thrown when a zero address is provided
     */
    error ZeroAddressDetected();

    /**
     * @dev Error thrown when an invalid amount is provided
     * @param amount The invalid amount
     */
    error InvalidAmount(uint256 amount);

    /**
     * @dev Error thrown when a duration is outside allowed range
     * @param provided Provided duration
     * @param minimum Minimum allowed duration
     * @param maximum Maximum allowed duration
     */
    error InvalidDuration(uint256 provided, uint256 minimum, uint256 maximum);

    /**
     * @dev Error thrown when ETH target is invalid
     */
    error InvalidEthTarget();

    /**
     * @dev Error thrown when token allocation is invalid
     */
    error InvalidTokenAllocation();

    /**
     * @dev Error thrown when start time is in the past
     * @param provided Provided start time
     * @param current Current time
     */
    error InvalidStartTime(uint64 provided, uint256 current);

    /**
     * @dev Error thrown when token supply is insufficient
     * @param required Required amount
     * @param available Available amount
     */
    error InsufficientSupply(uint256 required, uint256 available);

    /**
     * @dev Error thrown when round start time hasn't been reached
     * @param currentTime Current time
     * @param startTime Start time of the round
     */
    error RoundStartTimeNotReached(uint256 currentTime, uint256 startTime);

    /**
     * @dev Error thrown when round end time has been reached
     * @param currentTime Current time
     * @param endTime End time of the round
     */
    error RoundEndTimeReached(uint256 currentTime, uint256 endTime);

    /**
     * @dev Error thrown when an invalid investor address is provided
     */
    error InvalidInvestor();

    /**
     * @dev Error thrown when ETH amount is invalid
     */
    error InvalidEthAmount();

    /**
     * @dev Error thrown when token amount is invalid
     */
    error InvalidTokenAmount();

    /**
     * @dev Error thrown when allocation already exists for an investor
     * @param investor Address of the investor
     */
    error AllocationExists(address investor);

    /**
     * @dev Error thrown when allocation exceeds round allocation
     * @param requested Requested allocation
     * @param available Available allocation
     */
    error ExceedsRoundAllocation(uint256 requested, uint256 available);

    /**
     * @dev Error thrown when no allocation exists for an investor
     * @param investor Address of the investor
     */
    error NoAllocationExists(address investor);

    /**
     * @dev Error thrown when investor already has an active position
     * @param investor Address of the investor
     */
    error InvestorHasActivePosition(address investor);

    /**
     * @dev Error thrown when investor has no investment
     * @param investor Address of the investor
     */
    error NoInvestment(address investor);

    /**
     * @dev Error thrown when a round is not cancelled
     * @param roundId ID of the round
     */
    error RoundNotCancelled(uint32 roundId);

    /**
     * @dev Error thrown when no refund is available
     * @param investor Address of the investor
     */
    error NoRefundAvailable(address investor);

    /**
     * @dev Error thrown when status transition is invalid
     * @param current Current status
     * @param new_ New status
     */
    error InvalidStatusTransition(RoundStatus current, RoundStatus new_);

    /**
     * @dev Error thrown when no active round exists
     */
    error NoActiveRound();

    /**
     * @dev Error thrown when a round has ended
     * @param roundId ID of the round
     */
    error RoundEnded(uint32 roundId);

    /**
     * @dev Error thrown when a round is oversubscribed
     * @param roundId ID of the round
     */
    error RoundOversubscribed(uint32 roundId);

    /**
     * @dev Error thrown when investor has no allocation
     * @param investor Address of the investor
     */
    error NoAllocation(address investor);

    /**
     * @dev Error thrown when amount doesn't match allocation
     * @param provided Provided amount
     * @param required Required amount
     */
    error AmountAllocationMismatch(uint256 provided, uint256 required);

    /**
     * @dev Error thrown when attempting operations with zero balance
     */
    error ZeroBalance();

    // ============ Function Declarations ============

    /**
     * @dev Initializes the contract
     * @param token Address of the ecosystem token
     * @param timelock_ Address of the timelock controller
     * @param treasury_ Address of the treasury
     * @param guardian Address of the guardian (receives PAUSER_ROLE)
     * @param gnosisSafe Address of the multisig (receives UPGRADER_ROLE)
     */
    function initialize(address token, address timelock_, address treasury_, address guardian, address gnosisSafe)
        external;

    /**
     * @dev Pauses the contract
     */
    function pause() external;

    /**
     * @dev Unpauses the contract
     */
    function unpause() external;

    /**
     * @dev Schedules an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function scheduleUpgrade(address newImplementation) external;

    /**
     * @dev Executes an emergency withdrawal
     * @param token Address of the token to withdraw (0xEeee... for ETH)
     */
    function emergencyWithdrawToken(address token) external;

    /**
     * @dev Executes an emergency withdrawal
     */
    function emergencyWithdrawEther() external;

    /**
     * @dev Creates a new investment round
     * @param start Start timestamp of the round
     * @param duration Duration in seconds
     * @param ethTarget Target ETH amount
     * @param tokenAlloc Total token allocation
     * @param vestingCliff Cliff period for vesting in seconds
     * @param vestingDuration Duration for vesting in seconds
     * @return ID of the created round
     */
    function createRound(
        uint64 start,
        uint64 duration,
        uint256 ethTarget,
        uint256 tokenAlloc,
        uint64 vestingCliff,
        uint64 vestingDuration
    ) external returns (uint32);

    /**
     * @dev Activates a pending round
     * @param roundId ID of the round to activate
     */
    function activateRound(uint32 roundId) external;

    /**
     * @dev Adds an investor allocation to a round
     * @param roundId ID of the round
     * @param investor Address of the investor
     * @param ethAmount ETH allocation amount
     * @param tokenAmount Token allocation amount
     */
    function addInvestorAllocation(uint32 roundId, address investor, uint256 ethAmount, uint256 tokenAmount) external;

    /**
     * @dev Removes an investor allocation from a round
     * @param roundId ID of the round
     * @param investor Address of the investor
     */
    function removeInvestorAllocation(uint32 roundId, address investor) external;

    /**
     * @dev Cancels an investment in a round
     * @param roundId ID of the round
     */
    function cancelInvestment(uint32 roundId) external;

    /**
     * @dev Finalizes a completed round
     * @param roundId ID of the round
     */
    function finalizeRound(uint32 roundId) external;

    /**
     * @dev Cancels a round
     * @param roundId ID of the round
     */
    function cancelRound(uint32 roundId) external;

    /**
     * @dev Claims a refund for a cancelled round
     * @param roundId ID of the round
     */
    function claimRefund(uint32 roundId) external;

    /**
     * @dev Invests ETH in a round
     * @param roundId ID of the round
     */
    function investEther(uint32 roundId) external payable;

    /**
     * @dev Returns the remaining time before a scheduled upgrade can be executed
     * @return Time remaining in seconds
     */
    function upgradeTimelockRemaining() external view returns (uint256);

    /**
     * @dev Gets the refund amount for an investor in a round
     * @param roundId ID of the round
     * @param investor Address of the investor
     * @return Refund amount
     */
    function getRefundAmount(uint32 roundId, address investor) external view returns (uint256);

    /**
     * @dev Gets investor details for a round
     * @param roundId ID of the round
     * @param investor Address of the investor
     * @return etherAmount ETH allocation amount
     * @return tokenAmount Token allocation amount
     * @return invested Amount invested
     * @return vestingContract Address of the vesting contract
     */
    function getInvestorDetails(uint32 roundId, address investor)
        external
        view
        returns (uint256 etherAmount, uint256 tokenAmount, uint256 invested, address vestingContract);

    /**
     * @dev Gets the address of the ecosystem token
     * @return Address of the ecosystem token
     */
    function getEcosystemToken() external view returns (address);

    /**
     * @dev Gets information about a round
     * @param roundId ID of the round
     * @return Round information
     */
    function getRoundInfo(uint32 roundId) external view returns (Round memory);

    /**
     * @dev Gets list of investors in a round
     * @param roundId ID of the round
     * @return Array of investor addresses
     */
    function getRoundInvestors(uint32 roundId) external view returns (address[] memory);

    /**
     * @dev Gets the current active round
     * @return ID of the current active round, or type(uint32).max if none
     */
    function getCurrentRound() external view returns (uint32);

    /**
     * @dev Gets the timelock controller address
     * @return Address of the timelock controller
     */
    function timelock() external view returns (address);

    /**
     * @dev Gets the treasury address
     * @return Address of the treasury
     */
    function treasury() external view returns (address);

    /**
     * @dev Gets the total token supply managed by this contract
     * @return Total supply
     */
    function supply() external view returns (uint256);

    /**
     * @dev Gets the contract version
     * @return Contract version
     */
    function version() external view returns (uint32);

    /**
     * @dev Gets round information by index
     * @param roundId ID of the round
     */
    // function rounds(uint32 roundId) external view returns (Round memory);
}
