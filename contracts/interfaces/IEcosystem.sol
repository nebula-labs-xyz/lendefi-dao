// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title Lendefi DAO Ecosystem Interface
 * @notice Interface for the Ecosystem contract that handles airdrops, rewards, burning, partnerships, and secure upgrades
 * @dev Defines all external functions and events for the Ecosystem contract
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */
interface IECOSYSTEM {
    // ============ Structs ============

    /**
     * @dev Structure to track pending upgrades with timelock
     * @param implementation The address of the new implementation contract
     * @param scheduledTime The timestamp when the upgrade was scheduled
     * @param exists Boolean flag indicating if an upgrade is currently scheduled
     */
    struct UpgradeRequest {
        address implementation;
        uint64 scheduledTime;
        bool exists;
    }

    // ============ Events ============

    /**
     * @dev Emitted when the contract is initialized
     * @param initializer The address that initialized the contract
     */
    event Initialized(address indexed initializer);

    /**
     * @dev Emitted when an airdrop is executed
     * @param winners Array of addresses that received the airdrop
     * @param amount Amount of tokens each address received
     */
    event AirDrop(address[] indexed winners, uint256 amount);

    /**
     * @dev Emitted when a reward is distributed
     * @param sender The address that initiated the reward
     * @param recipient The address that received the reward
     * @param amount The amount of tokens awarded
     */
    event Reward(address indexed sender, address indexed recipient, uint256 amount);

    /**
     * @dev Emitted when tokens are burned
     * @param burner The address that initiated the burn
     * @param amount The amount of tokens burned
     */
    event Burn(address indexed burner, uint256 amount);

    /**
     * @dev Emitted when a new partner is added
     * @param partner The address of the partner
     * @param vestingContract The address of the partner's vesting contract
     * @param amount The amount of tokens allocated to the partner
     */
    event AddPartner(address indexed partner, address indexed vestingContract, uint256 amount);

    /**
     * @dev Emitted when a partnership is cancelled
     * @param partner The address of the partner whose contract was cancelled
     * @param remainingAmount The amount of tokens returned to the timelock
     */
    event CancelPartnership(address indexed partner, uint256 remainingAmount);

    /**
     * @dev Emitted when the maximum reward amount is updated
     * @param updater The address that updated the maximum reward
     * @param oldValue The previous maximum reward value
     * @param newValue The new maximum reward value
     */
    event MaxRewardUpdated(address indexed updater, uint256 oldValue, uint256 newValue);

    /**
     * @dev Emitted when the maximum burn amount is updated
     * @param updater The address that updated the maximum burn
     * @param oldValue The previous maximum burn value
     * @param newValue The new maximum burn value
     */
    event MaxBurnUpdated(address indexed updater, uint256 oldValue, uint256 newValue);

    /**
     * @dev Emitted when the contract is upgraded
     * @param upgrader The address that performed the upgrade
     * @param newImplementation The address of the new implementation
     * @param version The new version number
     */
    event Upgrade(address indexed upgrader, address indexed newImplementation, uint32 version);

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
     * @dev Emitted when a scheduled upgrade is cancelled
     * @param canceller The address that cancelled the upgrade
     * @param implementation The implementation address that was cancelled
     */
    event UpgradeCancelled(address indexed canceller, address indexed implementation);

    /**
     * @dev Emitted when an emergency withdrawal is executed
     * @param token Address of the token withdrawn
     * @param amount Amount withdrawn
     */
    event EmergencyWithdrawal(address indexed token, uint256 amount);

    // ============ Errors ============

    /**
     * @dev Error thrown for general validation failures
     * @param reason Description of the validation failure
     */
    error ValidationFailed(string reason);

    /**
     * @dev Error thrown if you try to upgrade while the timelock is active
     * @param remainingTime Time remaining in the timelock period
     */
    error UpgradeTimelockActive(uint256 remainingTime);

    /**
     * @dev Thrown when trying to execute an upgrade that wasn't scheduled
     */
    error UpgradeNotScheduled();

    /**
     * @dev Thrown when trying to execute an upgrade with wrong implementation
     * @param expected The implementation address that was scheduled
     * @param provided The implementation address that was attempted
     */
    error ImplementationMismatch(address expected, address provided);

    /**
     * @dev Error thrown when a zero address is provided where a non-zero address is required
     */
    error ZeroAddressDetected();

    /**
     * @dev Error thrown when an invalid amount is provided
     * @param amount The invalid amount that was provided
     */
    error InvalidAmount(uint256 amount);

    /**
     * @dev Error thrown when an airdrop exceeds the available supply
     * @param requested The amount of tokens requested for the airdrop
     * @param available The amount of tokens actually available
     */
    error AirdropSupplyLimit(uint256 requested, uint256 available);

    /**
     * @dev Error thrown when too many recipients are provided for an airdrop
     * @param recipients The number of recipients that would exceed gas limits
     */
    error GasLimit(uint256 recipients);

    /**
     * @dev Error thrown when a reward exceeds the maximum allowed amount
     * @param amount The requested reward amount
     * @param maxAllowed The maximum allowed reward amount
     */
    error RewardLimit(uint256 amount, uint256 maxAllowed);

    /**
     * @dev Error thrown when a reward exceeds the available supply
     * @param requested The requested reward amount
     * @param available The amount of tokens actually available
     */
    error RewardSupplyLimit(uint256 requested, uint256 available);

    /**
     * @dev Error thrown when a burn exceeds the available supply
     * @param requested The requested burn amount
     * @param available The amount of tokens actually available
     */
    error BurnSupplyLimit(uint256 requested, uint256 available);

    /**
     * @dev Error thrown when a burn exceeds the maximum allowed amount
     * @param amount The requested burn amount
     * @param maxAllowed The maximum allowed burn amount
     */
    error MaxBurnLimit(uint256 amount, uint256 maxAllowed);

    /**
     * @dev Error thrown when an invalid address is provided
     */
    error InvalidAddress();

    /**
     * @dev Error thrown when attempting to create a vesting contract for an existing partner
     * @param partner The address of the partner that already exists
     */
    error PartnerExists(address partner);

    /**
     * @dev Error thrown when an amount exceeds the available supply
     * @param requested The requested amount
     * @param available The amount actually available
     */
    error AmountExceedsSupply(uint256 requested, uint256 available);

    /**
     * @dev Error thrown when a maximum value update exceeds allowed limits
     * @param amount The requested new maximum value
     * @param maxAllowed The maximum allowed value
     */
    error ExcessiveMaxValue(uint256 amount, uint256 maxAllowed);

    /**
     * @dev Thrown when attempting to set an invalid vesting duration
     */
    error InvalidVestingSchedule();

    /**
     * @dev Error thrown when attempting operations with zero balance
     */
    error ZeroBalance();

    // ============ Functions ============

    /**
     * @notice Initializes the ecosystem contract
     * @dev Sets up the initial state of the contract, including roles and token supplies
     * @param token Address of the governance token
     * @param timelockAddr Address of the timelock controller
     * @param multisig Address of the multisig wallet
     */
    function initialize(address token, address timelockAddr, address multisig) external;

    /**
     * @notice Pauses all contract operations
     * @dev Can only be called by accounts with the PAUSER_ROLE
     */
    function pause() external;

    /**
     * @notice Resumes all contract operations
     * @dev Can only be called by accounts with the PAUSER_ROLE
     */
    function unpause() external;

    /**
     * @notice Schedules an upgrade to a new implementation
     * @dev Can only be called by accounts with the UPGRADER_ROLE
     * @param newImplementation Address of the new implementation
     */
    function scheduleUpgrade(address newImplementation) external;

    /**
     * @notice Cancels a previously scheduled upgrade
     * @dev Can only be called by accounts with the UPGRADER_ROLE
     */
    function cancelUpgrade() external;

    /**
     * @notice Returns the remaining time before a scheduled upgrade can be executed
     * @dev Returns 0 if no upgrade is scheduled or timelock has passed
     * @return The time remaining in seconds
     */
    function upgradeTimelockRemaining() external view returns (uint256);

    /**
     * @notice Emergency function to withdraw tokens to the timelock
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @param token The token to withdraw
     */
    function emergencyWithdrawToken(address token) external;

    /**
     * @notice Distributes tokens to multiple recipients
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @param recipients Array of addresses to receive the airdrop
     * @param amount Amount of tokens each recipient will receive
     */
    function airdrop(address[] calldata recipients, uint256 amount) external;

    /**
     * @notice Rewards a single address with tokens
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @param to Recipient address
     * @param amount Amount of tokens to reward
     */
    function reward(address to, uint256 amount) external;

    /**
     * @notice Burns tokens from the reward supply
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external;

    /**
     * @notice Creates a vesting contract for a new partner
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @param partner Address of the partner
     * @param amount Amount of tokens to vest
     * @param cliff Cliff period in seconds
     * @param duration Vesting duration in seconds
     */
    function addPartner(address partner, uint256 amount, uint256 cliff, uint256 duration) external;

    /**
     * @notice Cancels a partner's vesting contract
     * @dev Can only be called by the timelock
     * @param partner Address of the partner
     */
    function cancelPartnership(address partner) external;

    /**
     * @notice Updates the maximum one-time reward amount
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @param newMaxReward New maximum reward value
     */
    function updateMaxReward(uint256 newMaxReward) external;

    /**
     * @notice Updates the maximum one-time burn amount
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @param newMaxBurn New maximum burn value
     */
    function updateMaxBurn(uint256 newMaxBurn) external;

    /**
     * @notice Returns the available reward supply
     * @dev Calculates remaining reward tokens
     * @return Available tokens in the reward supply
     */
    function availableRewardSupply() external view returns (uint256);

    /**
     * @notice Returns the available airdrop supply
     * @dev Calculates remaining airdrop tokens
     * @return Available tokens in the airdrop supply
     */
    function availableAirdropSupply() external view returns (uint256);

    /**
     * @notice Returns the available partnership supply
     * @dev Calculates remaining partnership tokens
     * @return Available tokens in the partnership supply
     */
    function availablePartnershipSupply() external view returns (uint256);

    /**
     * @notice Gets the total reward supply
     * @return The total reward supply
     */
    function rewardSupply() external view returns (uint256);

    /**
     * @notice Gets the maximum reward amount
     * @return The maximum reward amount
     */
    function maxReward() external view returns (uint256);

    /**
     * @notice Gets the total amount of tokens issued as rewards
     * @return The total issued reward amount
     */
    function issuedReward() external view returns (uint256);

    /**
     * @notice Gets the total amount of tokens burned
     * @return The total burned amount
     */
    function burnedAmount() external view returns (uint256);

    /**
     * @notice Gets the maximum burn amount
     * @return The maximum burn amount
     */
    function maxBurn() external view returns (uint256);

    /**
     * @notice Gets the total airdrop supply
     * @return The total airdrop supply
     */
    function airdropSupply() external view returns (uint256);

    /**
     * @notice Gets the total amount of tokens issued via airdrops
     * @return The total issued airdrop amount
     */
    function issuedAirDrop() external view returns (uint256);

    /**
     * @notice Gets the total partnership supply
     * @return The total partnership supply
     */
    function partnershipSupply() external view returns (uint256);

    /**
     * @notice Gets the total amount of tokens issued to partners
     * @return The total issued partnership amount
     */
    function issuedPartnership() external view returns (uint256);

    /**
     * @notice Gets the contract version
     * @return The current version number
     */
    function version() external view returns (uint32);

    /**
     * @notice Gets the timelock address
     * @return The timelock address
     */
    function timelock() external view returns (address);

    /**
     * @notice Gets the vesting contract address for a partner
     * @param partner The address of the partner
     * @return The vesting contract address
     */
    function vestingContracts(address partner) external view returns (address);
}
