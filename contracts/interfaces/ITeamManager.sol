// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Team Manager Interface
 * @notice Interface for the Lendefi DAO Team Manager
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

interface ITEAMMANAGER {
    /// @dev Upgrade timelock storage
    struct UpgradeRequest {
        address implementation;
        uint64 scheduledTime;
        bool exists;
    }
    /**
     * @dev Initialized Event.
     * @param src sender address
     */

    event Initialized(address indexed src);

    /**
     * @dev Upgrade Event.
     * @param src sender address
     * @param implementation address
     */
    event Upgrade(address indexed src, address indexed implementation);

    /**
     * @dev AddTeamMember Event.
     * @param account member address
     * @param vesting contract address
     * @param amount of tokens allocated to vesting
     */
    event AddTeamMember(address indexed account, address indexed vesting, uint256 amount);

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

    /**
     * @dev Error thrown when an address parameter is zero
     */
    error ZeroAddress();

    /**
     * @dev Error thrown when an amount parameter is zero
     */
    error ZeroAmount();

    /**
     * @dev Error thrown when a beneficiary already has an allocation
     * @param beneficiary The address that already has an allocation
     */
    error BeneficiaryAlreadyExists(address beneficiary);

    /**
     * @dev Error thrown when cliff is outside allowed range
     * @param provided The provided cliff duration
     * @param minAllowed The minimum allowed cliff duration
     * @param maxAllowed The maximum allowed cliff duration
     */
    error InvalidCliff(uint256 provided, uint256 minAllowed, uint256 maxAllowed);

    /**
     * @dev Error thrown when duration is outside allowed range
     * @param provided The provided vesting duration
     * @param minAllowed The minimum allowed vesting duration
     * @param maxAllowed The maximum allowed vesting duration
     */
    error InvalidDuration(uint256 provided, uint256 minAllowed, uint256 maxAllowed);

    /**
     * @dev Error thrown when allocation exceeds remaining supply
     * @param requested The requested allocation amount
     * @param available The available supply
     */
    error SupplyExceeded(uint256 requested, uint256 available);

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
     * @dev Error thrown for general validation failures
     * @param reason Description of the validation failure
     */
    error ValidationFailed(string reason);

    /**
     * @dev Pause contract.
     */
    function pause() external;

    /**
     * @dev Unpause contract.
     */
    function unpause() external;

    /**
     * @dev Create and fund a vesting contract for a new team member
     * @param beneficiary beneficiary address
     * @param amount token amount
     * @param cliff cliff period in seconds
     * @param duration vesting duration in seconds after cliff  (e.g. 24 months)
     */
    function addTeamMember(address beneficiary, uint256 amount, uint256 cliff, uint256 duration) external;

    /**
     * @dev Schedules an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function scheduleUpgrade(address newImplementation) external;

    /**
     * @dev Returns the remaining time before a scheduled upgrade can be executed
     * @return The time remaining in seconds, or 0 if no upgrade is scheduled or timelock has passed
     */
    function upgradeTimelockRemaining() external view returns (uint256);

    /**
     * @dev Getter for the UUPS version, incremented each time an upgrade occurs.
     * @return version number (1,2,3)
     */
    function version() external view returns (uint32);

    /**
     * @dev Getter for the amount of tokens allocated to team member.
     * @param account address
     * @return amount of tokens allocated to member
     */
    function allocations(address account) external view returns (uint256);

    /**
     * @dev Getter for the address of vesting contract created for team member.
     * @param account address
     * @return vesting contract address
     */
    function vestingContracts(address account) external view returns (address);

    /**
     * @dev Starting supply allocated to team.
     * @return amount
     */
    function supply() external view returns (uint256);

    /**
     * @dev Total amount of token allocated so far.
     * @return amount
     */
    function totalAllocation() external view returns (uint256);

    /**
     * @dev Access the pending upgrade information
     * @return implementation The address of the pending implementation
     * @return scheduledTime The timestamp when the upgrade was scheduled
     * @return exists Whether a pending upgrade exists
     */
    function pendingUpgrade() external view returns (address implementation, uint64 scheduledTime, bool exists);

    /**
     * @dev Get the timelock address.
     * @return Address of the timelock controller
     */
    function timelock() external view returns (address);

    /**
     * @notice Cancels a previously scheduled upgrade
     * @dev Removes a pending upgrade from the schedule
     * @custom:access Restricted to UPGRADER_ROLE
     * @custom:state-changes
     *      - Clears the pendingUpgrade data
     *      - Emits an UpgradeCancelled event
     */
    function cancelUpgrade() external;
}
