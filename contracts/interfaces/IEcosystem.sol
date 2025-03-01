// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title Lendefi DAO Ecosystem Interface
 * @notice Interface for the Ecosystem contract that handles airdrops, rewards, burning, and partnerships
 * @dev Defines all external functions and events for the Ecosystem contract
 */
interface IECOSYSTEM {
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
     * @dev Error thrown when a function is called by an unauthorized account
     */
    error CallerNotAllowed();

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
     * @notice Initializes the ecosystem contract
     * @dev Sets up the initial state of the contract, including roles and token supplies
     * @param token Address of the governance token
     * @param timelockAddr Address of the timelock controller for partner vesting cancellation
     * @param guardian Address of the guardian (admin)
     * @param pauser Address of the pauser
     * @custom:throws ZeroAddressDetected if any address is zero
     */
    function initialize(address token, address timelockAddr, address guardian, address pauser) external;

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
     * @notice Distributes tokens to multiple recipients
     * @dev Performs an airdrop of a fixed amount of tokens to each address in the recipients array
     * @param recipients Array of addresses to receive the airdrop
     * @param amount Amount of tokens each recipient will receive
     * @custom:throws InvalidAmount if amount is less than 1 ether
     * @custom:throws AirdropSupplyLimit if total exceeds available supply
     * @custom:throws GasLimit if recipients array is too large
     */
    function airdrop(address[] calldata recipients, uint256 amount) external;

    /**
     * @notice Rewards a single address with tokens
     * @dev Transfers a specified amount of tokens to a recipient as a reward
     * @param to Recipient address
     * @param amount Amount of tokens to reward
     * @custom:throws InvalidAmount if amount is zero
     * @custom:throws RewardLimit if amount exceeds maximum reward
     * @custom:throws RewardSupplyLimit if amount exceeds available supply
     */
    function reward(address to, uint256 amount) external;

    /**
     * @notice Burns tokens from the reward supply
     * @dev Permanently removes tokens from circulation, updating supply calculations
     * @param amount Amount of tokens to burn
     * @custom:throws InvalidAmount if amount is zero
     * @custom:throws MaxBurnLimit if amount exceeds maximum burn
     * @custom:throws BurnSupplyLimit if amount exceeds available supply
     */
    function burn(uint256 amount) external;

    /**
     * @notice Creates a vesting contract for a new partner
     * @dev Deploys a new PartnerVesting contract and funds it with the specified amount
     * @param partner Address of the partner
     * @param amount Amount of tokens to vest
     * @param cliff Cliff period in seconds
     * @param duration Vesting duration in seconds
     * @custom:throws InvalidAddress if partner address is zero
     * @custom:throws PartnerExists if partner already has a vesting contract
     * @custom:throws InvalidAmount if amount is outside allowed range
     * @custom:throws AmountExceedsSupply if total exceeds partnership supply
     */
    function addPartner(address partner, uint256 amount, uint256 cliff, uint256 duration) external;

    /**
     * @notice Cancels a partner's vesting contract
     * @dev Returns unvested tokens to the timelock and updates accounting
     * @param partner Address of the partner
     * @custom:throws CallerNotAllowed if caller is not the timelock
     * @custom:throws InvalidAddress if no vesting contract exists for partner
     */
    function cancelPartnership(address partner) external;

    /**
     * @notice Updates the maximum one-time reward amount
     * @dev Sets a new limit on the maximum tokens that can be rewarded in one transaction
     * @param newMaxReward New maximum reward value
     * @custom:throws InvalidAmount if new value is zero
     * @custom:throws ExcessiveMaxValue if value exceeds allowed percentage of supply
     */
    function updateMaxReward(uint256 newMaxReward) external;

    /**
     * @notice Updates the maximum one-time burn amount
     * @dev Sets a new limit on the maximum tokens that can be burned in one transaction
     * @param newMaxBurn New maximum burn value
     * @custom:throws InvalidAmount if new value is zero
     * @custom:throws ExcessiveMaxValue if value exceeds allowed percentage of supply
     */
    function updateMaxBurn(uint256 newMaxBurn) external;

    /**
     * @notice Returns the available reward supply
     * @dev Calculates tokens available for rewards by subtracting issued rewards from total supply
     * @return Available tokens in the reward supply
     */
    function availableRewardSupply() external view returns (uint256);

    /**
     * @notice Returns the available airdrop supply
     * @dev Calculates tokens available for airdrops by subtracting issued airdrops from total supply
     * @return Available tokens in the airdrop supply
     */
    function availableAirdropSupply() external view returns (uint256);

    /**
     * @notice Returns the available partnership supply
     * @dev Calculates tokens available for partnerships by subtracting issued partnerships from total supply
     * @return Available tokens in the partnership supply
     */
    function availablePartnershipSupply() external view returns (uint256);

    /**
     * @notice Gets the total reward supply
     * @dev Returns the total amount of tokens allocated for rewards
     * @return The total reward supply
     */
    function rewardSupply() external view returns (uint256);

    /**
     * @notice Gets the maximum reward amount
     * @dev Returns the maximum tokens that can be rewarded in one transaction
     * @return The maximum reward amount
     */
    function maxReward() external view returns (uint256);

    /**
     * @notice Gets the total amount of tokens issued as rewards
     * @dev Returns the cumulative amount of tokens that have been rewarded
     * @return The total issued reward amount
     */
    function issuedReward() external view returns (uint256);

    /**
     * @notice Gets the total amount of tokens burned
     * @dev Returns the cumulative amount of tokens that have been burned
     * @return The total burned amount
     */
    function burnedAmount() external view returns (uint256);

    /**
     * @notice Gets the maximum burn amount
     * @dev Returns the maximum tokens that can be burned in one transaction
     * @return The maximum burn amount
     */
    function maxBurn() external view returns (uint256);

    /**
     * @notice Gets the total airdrop supply
     * @dev Returns the total amount of tokens allocated for airdrops
     * @return The total airdrop supply
     */
    function airdropSupply() external view returns (uint256);

    /**
     * @notice Gets the total amount of tokens issued via airdrops
     * @dev Returns the cumulative amount of tokens that have been airdropped
     * @return The total issued airdrop amount
     */
    function issuedAirDrop() external view returns (uint256);

    /**
     * @notice Gets the total partnership supply
     * @dev Returns the total amount of tokens allocated for partnerships
     * @return The total partnership supply
     */
    function partnershipSupply() external view returns (uint256);

    /**
     * @notice Gets the total amount of tokens issued to partners
     * @dev Returns the cumulative amount of tokens that have been allocated to partners
     * @return The total issued partnership amount
     */
    function issuedPartnership() external view returns (uint256);

    /**
     * @notice Gets the contract version
     * @dev Returns the version number, which is incremented with each upgrade
     * @return The current version number
     */
    function version() external view returns (uint32);

    /**
     * @notice Gets the timelock address
     * @dev Returns the address of the timelock controller used for governance actions
     * @return The timelock address
     */
    function timelock() external view returns (address);

    /**
     * @notice Gets the vesting contract address for a partner
     * @dev Returns the address of the vesting contract created for a specific partner
     * @param partner The address of the partner
     * @return The vesting contract address, or zero address if none exists
     */
    function vestingContracts(address partner) external view returns (address);
}
