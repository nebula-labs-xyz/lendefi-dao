// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title Lendefi DAO Treasury Interface
 * @notice Interface for the Treasury contract with linear vesting, timelock upgrades and multisig support
 * @dev Defines all external functions and events for the Treasury contract
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */
interface ITREASURY {
    /* ========== STRUCTS ========== */

    /**
     * @dev Structure to track pending upgrades with timelock
     */
    struct UpgradeRequest {
        address implementation;
        uint64 scheduledTime;
        bool exists;
    }

    /* ========== CUSTOM ERRORS ========== */

    /**
     * @dev Thrown when an operation receives the zero address where a non-zero address is required
     */
    error ZeroAddress();

    /**
     * @dev Thrown when an operation receives a zero amount where a non-zero amount is required
     */
    error ZeroAmount();

    /**
     * @dev Thrown when trying to release more funds than what's currently vested
     * @param requested The amount requested for release
     * @param available The actual amount available for release
     */
    error InsufficientVestedAmount(uint256 requested, uint256 available);

    /**
     * @dev Thrown when attempting to set an invalid vesting duration
     * @param minimum The minimum allowed duration
     */
    error InvalidDuration(uint256 minimum);

    /**
     * @dev Error thrown when trying to execute an upgrade too soon
     * @param remainingTime The time remaining until upgrade can be executed
     */
    error UpgradeTimelockActive(uint256 remainingTime);

    /**
     * @dev Error thrown when trying to execute an upgrade that wasn't scheduled
     */
    error UpgradeNotScheduled();

    /**
     * @dev Error thrown when trying to execute an upgrade with wrong implementation
     * @param expected The expected implementation address
     * @param provided The provided implementation address
     */
    error ImplementationMismatch(address expected, address provided);

    /**
     * @dev Error thrown when attempting operations with zero balance
     */
    error ZeroBalance();
    /* ========== EVENTS ========== */

    /**
     * @dev Emitted when the contract is initialized
     * @param initializer Address that called the initialize function
     * @param startTime Start timestamp of the vesting schedule
     * @param duration Duration of the vesting period in seconds
     */
    event Initialized(address indexed initializer, uint256 startTime, uint256 duration);

    /**
     * @dev Emitted when ETH is released from the treasury
     * @param to Address receiving the ETH
     * @param amount Amount of ETH released
     * @param remainingReleasable Amount of ETH still available for release
     */
    event EthReleased(address indexed to, uint256 amount, uint256 remainingReleasable);

    /**
     * @dev Emitted when ERC20 tokens are released from the treasury
     * @param token Address of the ERC20 token being released
     * @param to Address receiving the tokens
     * @param amount Amount of tokens released
     */
    event TokenReleased(address indexed token, address indexed to, uint256 amount);

    /**
     * @dev Emitted when the vesting schedule parameters are updated
     * @param updater Address that updated the vesting schedule
     * @param newStart New start timestamp of the vesting schedule
     * @param newDuration New duration of the vesting period in seconds
     */
    event VestingScheduleUpdated(address indexed updater, uint256 newStart, uint256 newDuration);

    /**
     * @dev Emitted when funds are withdrawn via the emergency withdrawal function
     * @param token Address of the token withdrawn (address(0) for ETH)
     * @param to Address receiving the funds
     * @param amount Amount withdrawn
     */
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);

    /**
     * @dev Emitted when the contract implementation is upgraded
     * @param upgrader Address that performed the upgrade
     * @param implementation Address of the new implementation
     * @param version New version number after the upgrade
     */
    event Upgraded(address indexed upgrader, address indexed implementation, uint32 version);

    /**
     * @dev Emitted when ETH is received by the contract
     * @param src Address that sent ETH to the contract
     * @param amount Amount of ETH received
     */
    event Received(address indexed src, uint256 amount);

    /**
     * @dev Emitted when an upgrade is scheduled
     * @param sender The address that scheduled the upgrade
     * @param implementation The new implementation address
     * @param scheduledTime The time when the upgrade was scheduled
     * @param effectiveTime The time when the upgrade can be executed
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
    /* ========== FUNCTIONS ========== */

    /**
     * @notice Pauses all token transfers and releases
     * @dev Can only be called by accounts with the PAUSER_ROLE
     */
    function pause() external;

    /**
     * @notice Unpauses token transfers and releases
     * @dev Can only be called by accounts with the PAUSER_ROLE
     */
    function unpause() external;

    /**
     * @notice Returns the amount of ETH that can be released now
     * @return Amount of releasable ETH
     */
    function releasable() external view returns (uint256);

    /**
     * @notice Returns the amount of a specific token that can be released now
     * @param token The ERC20 token to check
     * @return Amount of releasable tokens
     */
    function releasable(address token) external view returns (uint256);

    /**
     * @notice Releases a specific amount of vested ETH
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @param to The address that will receive the ETH
     * @param amount The amount of ETH to release
     */
    function release(address to, uint256 amount) external;

    /**
     * @notice Releases a specific amount of vested tokens
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @param token The ERC20 token to release
     * @param to The address that will receive the tokens
     * @param amount The amount of tokens to release
     */
    function release(address token, address to, uint256 amount) external;

    /**
     * @notice Updates the vesting schedule parameters
     * @dev Can only be called by accounts with the DEFAULT_ADMIN_ROLE
     * @param newStart The new start timestamp
     * @param newDuration The new duration in seconds
     */
    function updateVestingSchedule(uint256 newStart, uint256 newDuration) external;

    /**
     * @notice Withdraws funds in case of emergency
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @dev Always sends funds to the timelock controller
     * @param token Address of the token to withdraw
     */
    function emergencyWithdrawToken(address token) external;
    /**
     * @notice Withdraws funds in case of emergency
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @dev Always sends funds to the timelock controller
     */
    function emergencyWithdrawEther() external;
    /**
     * @notice Schedules an upgrade to a new implementation
     * @dev Can only be called by accounts with the UPGRADER_ROLE
     * @param newImplementation Address of the new implementation
     */
    function scheduleUpgrade(address newImplementation) external;

    /**
     * @notice Returns the remaining time before a scheduled upgrade can be executed
     * @return The time remaining in seconds, or 0 if no upgrade is scheduled or timelock has passed
     */
    function upgradeTimelockRemaining() external view returns (uint256);

    /**
     * @notice Get the timelock controller address
     * @return The timelock controller address
     */
    function timelockAddress() external view returns (address);

    /**
     * @notice Returns the pending upgrade information
     * @return Information about the pending upgrade
     */
    // function pendingUpgrade() external view returns (UpgradeRequest memory);

    /**
     * @notice Calculates the amount of ETH vested at a specific timestamp
     * @param timestamp The timestamp to check
     * @return The vested amount of ETH
     */
    function vestedAmount(uint256 timestamp) external view returns (uint256);

    /**
     * @notice Calculates the amount of tokens vested at a specific timestamp
     * @param token The ERC20 token to check
     * @param timestamp The timestamp to check
     * @return The vested amount of tokens
     */
    function vestedAmount(address token, uint256 timestamp) external view returns (uint256);

    /**
     * @notice Returns the current contract version
     * @return Current version number
     */
    function version() external view returns (uint32);

    /**
     * @notice Returns the start timestamp of the vesting period
     * @return Start timestamp
     */
    function start() external view returns (uint256);

    /**
     * @notice Returns the duration of the vesting period
     * @return Duration in seconds
     */
    function duration() external view returns (uint256);

    /**
     * @notice Returns the end timestamp of the vesting period
     * @return End timestamp (start + duration)
     */
    function end() external view returns (uint256);

    /**
     * @notice Returns the amount of ETH already released
     * @return Amount of ETH released so far
     */
    function released() external view returns (uint256);

    /**
     * @notice Returns the amount of a specific token already released
     * @param token The ERC20 token to check
     * @return Amount of tokens released so far
     */
    function released(address token) external view returns (uint256);

    /**
     * @notice Returns the MANAGER_ROLE identifier used for access control
     * @return The keccak256 hash of "MANAGER_ROLE"
     */
    function MANAGER_ROLE() external view returns (bytes32);

    /**
     * @notice Returns the PAUSER_ROLE identifier used for access control
     * @return The keccak256 hash of "PAUSER_ROLE"
     */
    function PAUSER_ROLE() external view returns (bytes32);

    /**
     * @notice Returns the UPGRADER_ROLE identifier used for access control
     * @return The keccak256 hash of "UPGRADER_ROLE"
     */
    function UPGRADER_ROLE() external view returns (bytes32);
}
