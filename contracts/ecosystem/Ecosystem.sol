// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO Ecosystem
 * @notice Ecosystem contract handles airdrops, rewards, burning, and partnerships
 * @dev Implements a secure and upgradeable DAO ecosystem
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {ILENDEFI} from "../interfaces/ILendefi.sol";
import {IECOSYSTEM} from "../interfaces/IEcosystem.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PartnerVesting} from "../ecosystem/PartnerVesting.sol";

contract Ecosystem is
    IECOSYSTEM,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @dev AccessControl Burner Role
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    /// @dev AccessControl Pauser Role
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @dev AccessControl Upgrader Role
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @dev AccessControl Rewarder Role
    bytes32 internal constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    /// @dev AccessControl Manager Role
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @dev Minimum required vesting duration (30 days)
    uint256 internal constant MIN_VESTING_DURATION = 30 days;
    /// @dev Maximum allowed vesting duration (10 years)
    uint256 internal constant MAX_VESTING_DURATION = 3650 days; // 10 years
    /// @dev Upgrade timelock duration (3 days)
    uint256 private constant UPGRADE_TIMELOCK_DURATION = 3 days;

    // ============ Storage Variables ============

    /// @dev governance token instance
    ILENDEFI internal tokenInstance;
    /// @dev starting reward supply
    uint256 public rewardSupply;
    /// @dev maximal one time reward amount
    uint256 public maxReward;
    /// @dev issued reward
    uint256 public issuedReward;
    /// @dev burned reward amount (tracked separately for transparency)
    uint256 public burnedAmount;
    /// @dev maximum one time burn amount
    uint256 public maxBurn;
    /// @dev starting airdrop supply
    uint256 public airdropSupply;
    /// @dev total amount airdropped so far
    uint256 public issuedAirDrop;
    /// @dev starting partnership supply
    uint256 public partnershipSupply;
    /// @dev partnership tokens issued so far
    uint256 public issuedPartnership;
    /// @dev number of UUPS upgrades - packed with other variables to save gas
    uint32 public version;
    /// @dev timelock address for partner vesting cancellations
    address public timelock;
    /// @dev Addresses of vesting contracts issued to partners
    mapping(address partner => address vesting) public vestingContracts;

    /// @dev Pending upgrade information
    UpgradeRequest public pendingUpgrade;

    // Storage gap reduced to account for new pendingUpgrade variable
    uint256[16] private __gap;

    // ============ Modifiers ============

    /**
     * @dev Modifier to check for non-zero amounts
     * @param amount The amount to validate
     */
    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount(amount);
        _;
    }

    /**
     * @dev Modifier to check for non-zero addresses
     * @param addr The address to validate
     */
    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }

    // ============ Constructor & Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Prevents receiving Ether. This contract doesn't handle ETH.
     */
    receive() external payable {
        revert ValidationFailed("NO_ETHER_ACCEPTED");
    }

    /**
     * @dev Initializes the ecosystem contract.
     * @notice Sets up the initial state of the contract, including roles and token supplies.
     * @param token The address of the governance token.
     * @param timelockAddr The address of the timelock controller for partner vesting cancellation.
     * @param guardian The address of the guardian (admin).
     * @param multisig The address of the pauser.
     * @custom:requires All input addresses must not be zero.
     * @custom:requires-role DEFAULT_ADMIN_ROLE for the guardian.
     * @custom:requires-role PAUSER_ROLE for the pauser.
     * @custom:events-emits {Initialized} event.
     * @custom:throws ZeroAddressDetected if any of the input addresses are zero.
     */
    function initialize(address token, address timelockAddr, address guardian, address multisig) external initializer {
        if (token == address(0) || timelockAddr == address(0) || guardian == address(0) || multisig == address(0)) {
            revert ZeroAddressDetected();
        }

        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, timelockAddr);
        _grantRole(MANAGER_ROLE, timelockAddr);
        _grantRole(PAUSER_ROLE, guardian);
        _grantRole(UPGRADER_ROLE, multisig); // Grant upgrade role to multisig

        // Set up token and timelock
        tokenInstance = ILENDEFI(payable(token));
        timelock = timelockAddr;

        // Configure token allocations based on total supply
        uint256 initialSupply = tokenInstance.initialSupply();
        rewardSupply = (initialSupply * 26) / 100;
        airdropSupply = (initialSupply * 10) / 100;
        partnershipSupply = (initialSupply * 8) / 100;

        // Set initial limits
        maxReward = rewardSupply / 1000; // 0.1% of reward supply
        maxBurn = rewardSupply / 50; // 2% of reward supply

        // Initialize accounting
        issuedReward = 0;
        issuedAirDrop = 0;
        issuedPartnership = 0;
        burnedAmount = 0;

        // Set version
        version = 1;
        emit Initialized(msg.sender);
    }

    // ============ Contract State Management ============

    /**
     * @dev Pause contract.
     * @notice Pauses all contract operations.
     * @custom:requires-role PAUSER_ROLE
     * @custom:events-emits {Paused} event from PausableUpgradeable
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause contract.
     * @notice Resumes all contract operations.
     * @custom:requires-role PAUSER_ROLE
     * @custom:events-emits {Unpaused} event from PausableUpgradeable
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Schedules an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     * @notice Only callable by an address with UPGRADER_ROLE
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
     * @dev Returns the remaining time before a scheduled upgrade can be executed
     * @return The time remaining in seconds, or 0 if no upgrade is scheduled or timelock has passed
     */
    function upgradeTimelockRemaining() external view returns (uint256) {
        return pendingUpgrade.exists && block.timestamp < pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION
            ? pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION - block.timestamp
            : 0;
    }

    /**
     * @dev Emergency function to withdraw all tokens to the timelock
     * @param token The ERC20 token to withdraw
     * @notice Only callable by addresses with MANAGER_ROLE
     * @notice Always sends all available tokens to the timelock controller
     * @custom:throws ZeroAddress if token address is zero
     * @custom:throws ZeroBalance if contract has no token balance
     */
    function emergencyWithdrawToken(address token) external nonReentrant onlyRole(MANAGER_ROLE) nonZeroAddress(token) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroBalance();

        IERC20(token).safeTransfer(timelock, balance);
        emit EmergencyWithdrawal(token, balance);
    }

    // ============ Token Distribution Functions ============

    /**
     * @dev Performs an airdrop to a list of recipients.
     * @notice Distributes a specified amount of tokens to each address in the recipients array.
     * @param recipients An array of addresses to receive the airdrop.
     * @param amount The amount of tokens to be airdropped to each address.
     * @custom:requires-role MANAGER_ROLE
     * @custom:requires Contract must not be paused
     * @custom:requires Amount must be at least 1 ether
     * @custom:requires Total airdropped amount must not exceed the airdrop supply
     * @custom:requires Number of recipients must not exceed 4000 to avoid gas limit issues
     * @custom:events-emits {AirDrop} event
     * @custom:throws InvalidAmount if the amount is less than 1 ether
     * @custom:throws AirdropSupplyLimit if the total airdropped amount exceeds the airdrop supply
     * @custom:throws GasLimit if the number of recipients exceeds 4000
     */
    function airdrop(address[] calldata recipients, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(MANAGER_ROLE)
    {
        if (amount < 1 ether) {
            revert InvalidAmount(amount);
        }

        uint256 len = recipients.length;
        if (len > 4000) {
            revert GasLimit(len);
        }

        // Count valid (non-zero) addresses to properly calculate total amount
        uint256 validRecipientCount = 0;
        for (uint256 i = 0; i < len;) {
            if (recipients[i] != address(0)) {
                validRecipientCount++;
            }
            unchecked {
                ++i;
            } // Gas optimization
        }

        uint256 totalAmount = validRecipientCount * amount;
        if (issuedAirDrop + totalAmount > airdropSupply) {
            revert AirdropSupplyLimit(totalAmount, airdropSupply - issuedAirDrop);
        }

        issuedAirDrop += totalAmount;
        emit AirDrop(recipients, amount);

        // Distribute tokens to valid recipients
        for (uint256 i = 0; i < len;) {
            if (recipients[i] != address(0)) {
                IERC20(address(tokenInstance)).safeTransfer(recipients[i], amount);
            }
            unchecked {
                ++i;
            } // Gas optimization
        }
    }

    /**
     * @dev Reward functionality for the Nebula Protocol.
     * @notice Distributes a specified amount of tokens to a beneficiary address.
     * @param to The address that will receive the reward.
     * @param amount The amount of tokens to be rewarded.
     * @custom:requires-role REWARDER_ROLE
     * @custom:requires Contract must not be paused
     * @custom:requires Amount must be greater than 0
     * @custom:requires Amount must not exceed the maximum reward limit
     * @custom:requires Total rewarded amount must not exceed the reward supply
     * @custom:events-emits {Reward} event
     * @custom:throws InvalidAmount if the amount is 0
     * @custom:throws InvalidAddress if the recipient address is 0
     * @custom:throws RewardLimit if the amount exceeds the maximum reward limit
     * @custom:throws RewardSupplyLimit if the total rewarded amount exceeds the reward supply
     */
    function reward(address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(REWARDER_ROLE)
        nonZeroAmount(amount)
        nonZeroAddress(to)
    {
        // Check if the amount exceeds the max reward first (cheaper check)
        if (amount > maxReward) {
            revert RewardLimit(amount, maxReward);
        }

        // Consider burned tokens when calculating available supply
        uint256 availableSupply = rewardSupply - issuedReward;
        if (amount > availableSupply) {
            revert RewardSupplyLimit(amount, availableSupply);
        }

        issuedReward += amount;
        emit Reward(msg.sender, to, amount);
        IERC20(address(tokenInstance)).safeTransfer(to, amount);
    }

    /**
     * @dev Enables burn functionality for the DAO.
     * @notice Burns a specified amount of tokens from the reward supply.
     * @param amount The amount of tokens to be burned.
     * @custom:requires-role BURNER_ROLE
     * @custom:requires Contract must not be paused
     * @custom:requires Amount must be greater than 0
     * @custom:requires Amount must not exceed the maximum burn limit
     * @custom:requires Total burned amount must not exceed the reward supply
     * @custom:events-emits {Burn} event
     * @custom:throws InvalidAmount if the amount is 0
     * @custom:throws MaxBurnLimit if the amount exceeds the maximum burn limit
     * @custom:throws BurnSupplyLimit if the amount exceeds available supply
     */
    function burn(uint256 amount) external nonReentrant whenNotPaused onlyRole(BURNER_ROLE) nonZeroAmount(amount) {
        // Check if the amount exceeds the max burn first (cheaper check)
        if (amount > maxBurn) {
            revert MaxBurnLimit(amount, maxBurn);
        }

        // Calculate available supply properly accounting for previously burned tokens
        uint256 availableSupply = rewardSupply - issuedReward;
        if (amount > availableSupply) {
            revert BurnSupplyLimit(amount, availableSupply);
        }

        // Update both rewardSupply and track burnedAmount for accounting purposes
        // This dual accounting allows us to track both the remaining supply and
        // the total amount that has been burned historically
        rewardSupply -= amount;
        burnedAmount += amount;

        emit Burn(msg.sender, amount);
        tokenInstance.burn(amount);
    }

    // ============ Partnership Management Functions ============

    /**
     * @dev Creates and funds a new vesting contract for a new partner.
     * @notice Adds a new partner by creating a cancellable vesting contract and transferring the specified amount of tokens.
     * @param partner The address of the partner to receive the vesting contract.
     * @param amount The amount of tokens to be vested.
     * @param cliff The duration in seconds of the cliff period.
     * @param duration The duration in seconds of the vesting period.
     * @custom:requires-role MANAGER_ROLE
     * @custom:requires Contract must not be paused
     * @custom:requires Partner address must not be zero and must be a valid contract or EOA
     * @custom:requires Amount must be between 100 ether and half of the partnership supply
     * @custom:requires Duration must be within reasonable bounds
     * @custom:requires Total issued partnership tokens must not exceed the partnership supply
     * @custom:events-emits {AddPartner} event
     * @custom:throws InvalidAddress if the partner address is zero
     * @custom:throws PartnerExists if the partner already has a vesting contract
     * @custom:throws InvalidAmount if the amount is not within the valid range
     * @custom:throws InvalidVestingSchedule if duration is not within reasonable bounds
     * @custom:throws AmountExceedsSupply if the total issued partnership tokens exceed the partnership supply
     */
    function addPartner(address partner, uint256 amount, uint256 cliff, uint256 duration)
        external
        nonReentrant
        whenNotPaused
        onlyRole(MANAGER_ROLE)
        nonZeroAddress(partner)
    {
        if (vestingContracts[partner] != address(0)) {
            revert PartnerExists(partner);
        }

        if (amount < 100 ether || amount > partnershipSupply / 2) {
            revert InvalidAmount(amount);
        }

        // Add validation for vesting parameters
        if (duration < MIN_VESTING_DURATION || duration > MAX_VESTING_DURATION || cliff >= duration) {
            revert InvalidVestingSchedule();
        }

        if (issuedPartnership + amount > partnershipSupply) {
            revert AmountExceedsSupply(amount, partnershipSupply - issuedPartnership);
        }

        issuedPartnership += amount;

        // Use PartnerVesting which is cancellable by the timelock
        PartnerVesting vestingContract =
            new PartnerVesting(address(tokenInstance), partner, uint64(block.timestamp + cliff), uint64(duration));

        vestingContracts[partner] = address(vestingContract);

        emit AddPartner(partner, address(vestingContract), amount);
        IERC20(address(tokenInstance)).safeTransfer(address(vestingContract), amount);
    }

    /**
     * @dev Cancels a partner vesting contract
     * @notice This can only be called by the timelock (governance)
     * @param partner The address of the partner whose vesting should be cancelled
     * @custom:requires The caller must be the timelock
     * @custom:requires The partner must have a valid vesting contract
     * @custom:emits CancelPartnership event on successful cancellation
     * @custom:throws CallerNotAllowed if the caller is not the timelock
     * @custom:throws InvalidAddress if the partner has no vesting contract
     */
    function cancelPartnership(address partner) external nonZeroAddress(partner) onlyRole(MANAGER_ROLE) {
        address vestingContract = vestingContracts[partner];
        if (vestingContract == address(0)) {
            revert InvalidAddress();
        }

        // Call the cancel function on the vesting contract
        uint256 returnedAmount = PartnerVesting(vestingContract).cancelContract();

        // Update accounting to reflect returned tokens
        if (returnedAmount > 0) {
            // Update the partnership supply tracker
            issuedPartnership -= returnedAmount;

            // Transfer the tokens from Ecosystem to timelock
            // This maintains compatibility with existing tests while improving accounting
            SafeERC20.safeTransfer(IERC20(address(tokenInstance)), timelock, returnedAmount);
        }

        // Remove the partner's vesting contract from the mapping
        delete vestingContracts[partner];

        // Emit event with the partner address and returned amount
        emit CancelPartnership(partner, returnedAmount);
    }

    // ============ Limit Management Functions ============

    /**
     * @dev Updates the maximum one-time reward amount.
     * @notice Allows updating the maximum reward that can be issued in a single transaction.
     * @param newMaxReward The new maximum reward amount.
     * @custom:requires-role MANAGER_ROLE
     * @custom:requires Contract must not be paused
     * @custom:requires New max reward must be greater than 0
     * @custom:requires New max reward must not exceed 5% of remaining reward supply
     * @custom:events-emits {MaxRewardUpdated} event
     * @custom:throws InvalidAmount if the amount is 0
     * @custom:throws ExcessiveMaxValue if the amount exceeds 5% of remaining reward supply
     */
    function updateMaxReward(uint256 newMaxReward)
        external
        whenNotPaused
        onlyRole(MANAGER_ROLE)
        nonZeroAmount(newMaxReward)
    {
        // Ensure the maximum reward isn't excessive (no more than 5% of remaining reward supply)
        uint256 remainingRewards = rewardSupply - issuedReward;
        if (newMaxReward > remainingRewards / 20) {
            // 5% = 1/20
            revert ExcessiveMaxValue(newMaxReward, remainingRewards / 20);
        }

        uint256 oldMaxReward = maxReward;
        maxReward = newMaxReward;

        emit MaxRewardUpdated(msg.sender, oldMaxReward, newMaxReward);
    }

    /**
     * @dev Updates the maximum one-time burn amount.
     * @notice Allows updating the maximum amount that can be burned in a single transaction.
     * @param newMaxBurn The new maximum burn amount.
     * @custom:requires-role MANAGER_ROLE
     * @custom:requires Contract must not be paused
     * @custom:requires New max burn must be greater than 0
     * @custom:requires New max burn must not exceed 10% of remaining reward supply
     * @custom:events-emits {MaxBurnUpdated} event
     * @custom:throws InvalidAmount if the amount is 0
     * @custom:throws ExcessiveMaxValue if the amount exceeds 10% of remaining reward supply
     */
    function updateMaxBurn(uint256 newMaxBurn)
        external
        whenNotPaused
        onlyRole(MANAGER_ROLE)
        nonZeroAmount(newMaxBurn)
    {
        // Ensure the maximum burn isn't excessive (no more than 10% of remaining reward supply)
        uint256 remainingRewards = rewardSupply - issuedReward;
        if (newMaxBurn > remainingRewards / 10) {
            // 10% = 1/10
            revert ExcessiveMaxValue(newMaxBurn, remainingRewards / 10);
        }

        uint256 oldMaxBurn = maxBurn;
        maxBurn = newMaxBurn;

        emit MaxBurnUpdated(msg.sender, oldMaxBurn, newMaxBurn);
    }

    // ============ View Functions ============

    /**
     * @dev Returns the effective available reward supply considering burns.
     * @return The current available reward supply.
     */
    function availableRewardSupply() external view returns (uint256) {
        return rewardSupply - issuedReward;
    }

    /**
     * @dev Returns the effective available airdrop supply.
     * @return The current available airdrop supply.
     */
    function availableAirdropSupply() external view returns (uint256) {
        return airdropSupply - issuedAirDrop;
    }

    /**
     * @dev Returns the effective available partnership supply.
     * @return The current available partnership supply.
     */
    function availablePartnershipSupply() external view returns (uint256) {
        return partnershipSupply - issuedPartnership;
    }

    // ============ Internal Functions ============

    /**
     * @dev Authorizes an upgrade to a new implementation with timelock enforcement
     * @param newImplementation The address of the new implementation contract
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

        // Clear the scheduled upgrade
        delete pendingUpgrade;

        // Increment version
        ++version;

        emit Upgrade(msg.sender, newImplementation, version);
    }
}
