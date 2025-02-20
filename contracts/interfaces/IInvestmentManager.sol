// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title Investment Manager Interface
 * @notice Defines the interface for managing investment rounds and token distribution
 * @dev Implements events and data structures for investment lifecycle management
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */
interface IINVMANAGER {
    /**
     * @notice Defines the possible states of an investment round
     * @dev Used to control round lifecycle and permissions
     */
    enum RoundStatus {
        PENDING, // Initial state when round is created
        ACTIVE, // Round is accepting investments
        COMPLETED, // Investment target reached
        CANCELLED, // Round cancelled by admin
        FINALIZED // Tokens distributed to investors

    }

    /**
     * @title Investment Round Structure
     * @notice Represents an investment round's configuration and state
     * @dev All monetary values stored with 18 decimals precision
     * @dev Time values stored as uint64 for gas optimization
     * @param etherTarget Target amount of ETH to raise in round (18 decimals)
     * @param etherInvested Current amount of ETH invested in round (18 decimals)
     * @param tokenAllocation Total tokens allocated for distribution in round (18 decimals)
     * @param tokenDistributed Amount of tokens already distributed to investors (18 decimals)
     * @param startTime Unix timestamp when round begins accepting investments
     * @param endTime Unix timestamp when round stops accepting investments
     * @param vestingCliff Duration in seconds before vesting begins
     * @param vestingDuration Total duration in seconds for complete token vesting
     * @param participants Number of unique investors in round
     * @param status Current state of round (PENDING/ACTIVE/COMPLETED/CANCELLED/FINALIZED)
     * @custom:security Uses uint64 for timestamps to support dates until year 2554
     * @custom:security Packs smaller uints together for gas optimization
     * @custom:security Status transitions are unidirectional and sequential
     */
    struct Round {
        uint256 etherTarget;
        uint256 etherInvested;
        uint256 tokenAllocation;
        uint256 tokenDistributed;
        uint64 startTime;
        uint64 endTime;
        uint64 vestingCliff; // New field
        uint64 vestingDuration; // New field
        uint32 participants;
        RoundStatus status;
    }

    /**
     * @title Investor Allocation Structure
     * @notice Tracks an investor's ETH and token allocations in a round
     * @dev All monetary values stored with 18 decimals precision
     * @dev Used to manage individual investor positions
     * @param etherAmount The amount of ETH allocated to the investor (18 decimals)
     * @param tokenAmount The amount of tokens allocated to the investor (18 decimals)
     * @custom:security Values use uint256 to prevent overflow
     * @custom:security Struct packing not used due to 256-bit values
     * @custom:security Used in mapping for O(1) investor position lookups
     */
    struct Allocation {
        uint256 etherAmount; // Amount of ETH allocated
        uint256 tokenAmount; // Amount of tokens allocated
    }

    /**
     * @notice Emitted when contract is initialized
     * @param caller Address that initialized the contract
     */
    event Initialized(address indexed caller);

    /**
     * @notice Emitted when a new investment round is created
     * @param roundId Unique identifier for the round
     * @param start Start timestamp
     * @param duration Duration in seconds
     * @param ethTarget ETH investment target
     * @param tokenAlloc Token allocation for the round
     */
    event CreateRound(uint32 indexed roundId, uint64 start, uint64 duration, uint256 ethTarget, uint256 tokenAlloc);

    /**
     * @notice Emitted when a round's status changes
     * @param roundId Round identifier
     * @param status New status
     */
    event RoundStatusUpdated(uint32 indexed roundId, RoundStatus status);

    /**
     * @notice Emitted when an investment is made
     * @param roundId Round identifier
     * @param investor Investor address
     * @param amount ETH amount invested
     */
    event Invest(uint32 indexed roundId, address indexed investor, uint256 amount);

    /**
     * @notice Emitted when a round reaches its target
     * @param roundId Round identifier
     */
    event RoundComplete(uint32 indexed roundId);

    /**
     * @notice Emitted when an investment is cancelled
     * @param roundId Round identifier
     * @param investor Investor address
     * @param amount ETH amount refunded
     */
    event CancelInvestment(uint32 indexed roundId, address indexed investor, uint256 amount);

    /**
     * @notice Emitted when a round is closed
     * @param caller Address that closed the round
     * @param roundId Round identifier
     * @param totalEthRaised ETH raised
     * @param totalTokensDistributed Tokens
     */
    event RoundFinalized(
        address indexed caller, uint32 indexed roundId, uint256 totalEthRaised, uint256 totalTokensDistributed
    );
    /**
     * @notice Emitted when a round is cancelled
     * @param roundId Round identifier
     */
    event RoundCancelled(uint32 indexed roundId);

    /**
     * @notice Emitted when a vesting contract is deployed
     * @param roundId Round identifier
     * @param investor Investor address
     * @param vestingContract Address of deployed vesting contract
     * @param amount Token amount vested
     */
    event DeployVesting(uint32 indexed roundId, address indexed investor, address vestingContract, uint256 amount);

    /**
     * @notice Emitted when tokens are withdrawn
     * @param roundId Round identifier
     * @param caller Address that initiated withdrawal
     * @param amount Token amount withdrawn
     */
    event WithdrawTokens(uint32 indexed roundId, address indexed caller, uint256 amount);

    /**
     * @notice Emitted when contract is upgraded
     * @param caller Address that initiated upgrade
     * @param implementation New implementation address
     */
    event Upgrade(address indexed caller, address indexed implementation);

    /**
     * @notice Emitted when an investor is allocated to a round
     * @param roundId Round identifier
     * @param investor Investor address
     * @param ethAmount ETH allocation
     * @param tokenAmount Token allocation
     */
    event InvestorAllocated(uint32 indexed roundId, address indexed investor, uint256 ethAmount, uint256 tokenAmount);

    /**
     * @notice Emitted when an investor's allocation is removed from a round
     * @dev Triggered by removeInvestorAllocation function
     * @param roundId The identifier of the investment round
     * @param investor Address of the investor whose allocation was removed
     * @param ethAmount The ETH amount that was allocated
     * @param tokenAmount The token amount that was allocated
     * @custom:security Event includes both ETH and token amounts for complete tracking
     * @custom:security Uses indexed parameters for efficient filtering
     */
    event InvestorAllocationRemoved(
        uint32 indexed roundId, address indexed investor, uint256 ethAmount, uint256 tokenAmount
    );
    /**
     * @notice Emitted when an investor is allocated to a round
     * @param roundId Round identifier
     * @param investor Investor address
     * @param amount ETH allocation
     */
    event RefundClaimed(uint32 indexed roundId, address indexed investor, uint256 amount);
}
