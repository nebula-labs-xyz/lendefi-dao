// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO Ecosystem Contract
 * @notice Ecosystem contract handles airdrops, rewards, burning, and partnerships
 * @dev Implements a secure and upgradeable DAO ecosystem with improved accounting
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {ILENDEFI} from "../interfaces/ILendefi.sol";
import {IECOSYSTEM} from "../interfaces/IEcosystem.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PartnerVesting} from "./PartnerVesting.sol"; // Cancellable vesting contract for partners
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @custom:oz-upgrades
contract Ecosystem is
    IECOSYSTEM,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

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

    /// @dev governance token instance
    ILENDEFI internal tokenInstance;
    /// @dev starting reward supply
    uint256 public rewardSupply;
    /// @dev maximal one time reward amount
    uint256 public maxReward;
    /// @dev issued reward
    uint256 public issuedReward;
    /// @dev burned reward amount
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
    /// @dev number of UUPS upgrades
    uint32 public version;
    /// @dev timelock address for partner vesting cancellations
    address public timelock;
    /// @dev Addresses of vesting contracts issued to partners
    mapping(address partner => address vesting) public vestingContracts;
    uint256[49] private __gap;

    /**
     * @dev Custom error types
     */
    // error ZeroAddressDetected();
    // error InvalidAmount(uint256 amount);
    // error AirdropSupplyLimit(uint256 requested, uint256 available);
    // error GasLimit(uint256 recipients);
    // error RewardLimit(uint256 amount, uint256 maxAllowed);
    // error RewardSupplyLimit(uint256 requested, uint256 available);
    // error BurnSupplyLimit(uint256 requested, uint256 available);
    // error MaxBurnLimit(uint256 amount, uint256 maxAllowed);
    // error InvalidAddress();
    // error PartnerExists(address partner);
    // error AmountExceedsSupply(uint256 requested, uint256 available);
    // error ExcessiveMaxValue(uint256 amount, uint256 maxAllowed);
    // error CallerNotAllowed();

    /**
     * @dev Events
     */
    // event Initialized(address indexed initializer);
    // event AirDrop(address[] indexed winners, uint256 amount);
    // event Reward(address indexed sender, address indexed recipient, uint256 amount);
    // event Burn(address indexed burner, uint256 amount);
    // event AddPartner(address indexed partner, address indexed vestingContract, uint256 amount);
    // event CancelPartnership(address indexed partner, uint256 remainingAmount);
    // event MaxRewardUpdated(address indexed updater, uint256 oldValue, uint256 newValue);
    // event MaxBurnUpdated(address indexed updater, uint256 oldValue, uint256 newValue);
    // event Upgrade(address indexed upgrader, address indexed newImplementation, uint32 version);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Prevents receiving Ether. This contract doesn't handle ETH.
     */
    receive() external payable {
        revert("NO_ETHER_ACCEPTED");
    }

    /**
     * @dev Initializes the ecosystem contract.
     * @notice Sets up the initial state of the contract, including roles and token supplies.
     * @param token The address of the governance token.
     * @param timelockAddr The address of the timelock controller for partner vesting cancellation.
     * @param guardian The address of the guardian (admin).
     * @param pauser The address of the pauser.
     * @custom:requires All input addresses must not be zero.
     * @custom:requires-role DEFAULT_ADMIN_ROLE for the guardian.
     * @custom:requires-role PAUSER_ROLE for the pauser.
     * @custom:events-emits {Initialized} event.
     * @custom:throws ZeroAddressDetected if any of the input addresses are zero.
     */
    function initialize(address token, address timelockAddr, address guardian, address pauser) external initializer {
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (token == address(0) || timelockAddr == address(0) || guardian == address(0) || pauser == address(0)) {
            revert ZeroAddressDetected();
        }

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(MANAGER_ROLE, timelockAddr);

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
        ++version;
        emit Initialized(msg.sender);
    }

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

        uint256 totalAmount = len * amount;
        if (issuedAirDrop + totalAmount > airdropSupply) {
            revert AirdropSupplyLimit(totalAmount, airdropSupply - issuedAirDrop);
        }

        issuedAirDrop += totalAmount;
        emit AirDrop(recipients, amount);

        for (uint256 i; i < len; ++i) {
            if (recipients[i] != address(0)) {
                IERC20(address(tokenInstance)).safeTransfer(recipients[i], amount);
            }
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
     * @custom:throws RewardLimit if the amount exceeds the maximum reward limit
     * @custom:throws RewardSupplyLimit if the total rewarded amount exceeds the reward supply
     */
    function reward(address to, uint256 amount) external nonReentrant whenNotPaused onlyRole(REWARDER_ROLE) {
        if (amount == 0) {
            revert InvalidAmount(amount);
        }

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
    function burn(uint256 amount) external nonReentrant whenNotPaused onlyRole(BURNER_ROLE) {
        if (amount == 0) {
            revert InvalidAmount(amount);
        }

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
        rewardSupply -= amount;
        burnedAmount += amount;

        emit Burn(msg.sender, amount);
        tokenInstance.burn(amount);
    }

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
     * @custom:requires Total issued partnership tokens must not exceed the partnership supply
     * @custom:events-emits {AddPartner} event
     * @custom:throws InvalidAddress if the partner address is zero
     * @custom:throws PartnerExists if the partner already has a vesting contract
     * @custom:throws InvalidAmount if the amount is not within the valid range
     * @custom:throws AmountExceedsSupply if the total issued partnership tokens exceed the partnership supply
     */
    function addPartner(address partner, uint256 amount, uint256 cliff, uint256 duration)
        external
        nonReentrant
        whenNotPaused
        onlyRole(MANAGER_ROLE)
    {
        if (partner == address(0)) {
            revert InvalidAddress();
        }

        if (vestingContracts[partner] != address(0)) {
            revert PartnerExists(partner);
        }

        if (amount < 100 ether || amount > partnershipSupply / 2) {
            revert InvalidAmount(amount);
        }

        if (issuedPartnership + amount > partnershipSupply) {
            revert AmountExceedsSupply(amount, partnershipSupply - issuedPartnership);
        }

        issuedPartnership += amount;

        // Use PartnerVesting which is cancellable by the timelock
        PartnerVesting vestingContract = new PartnerVesting(
            address(tokenInstance),
            timelock,
            partner,
            SafeCast.toUint64(block.timestamp + cliff),
            SafeCast.toUint64(duration)
        );

        vestingContracts[partner] = address(vestingContract);

        emit AddPartner(partner, address(vestingContract), amount);
        IERC20(address(tokenInstance)).safeTransfer(address(vestingContract), amount);
    }

    /**
     * @dev Cancels a partner vesting contract
     * @notice This can only be called by the timelock (governance)
     * @param partner The address of the partner whose vesting should be cancelled
     * @custom:requires The caller must be the timelock
     * @custom:emits CancelPartnership event on successful cancellation
     */
    /**
     * @dev Cancels a partner vesting contract
     * @notice This can only be called by the timelock (governance)
     * @param partner The address of the partner whose vesting should be cancelled
     */
    function cancelPartnership(address partner) external {
        if (msg.sender != timelock) {
            revert CallerNotAllowed();
        }

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

        // Emit event with the partner address and returned amount
        emit CancelPartnership(partner, returnedAmount);
    }

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
    function updateMaxReward(uint256 newMaxReward) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (newMaxReward == 0) {
            revert InvalidAmount(newMaxReward);
        }

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
    function updateMaxBurn(uint256 newMaxBurn) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (newMaxBurn == 0) {
            revert InvalidAmount(newMaxBurn);
        }

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

    /**
     * @dev Authorizes an upgrade to a new implementation.
     * @notice This function is called during the upgrade process to authorize the new implementation.
     * @param newImplementation The address of the new implementation contract.
     * @custom:requires-role UPGRADER_ROLE
     * @custom:events-emits {Upgrade} event with upgrader, implementation and version
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation, version);
    }
}
