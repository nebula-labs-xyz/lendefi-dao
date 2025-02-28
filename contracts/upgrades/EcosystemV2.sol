// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO EcosystemV2 Contract (for testing upgrades)
 * @notice Ecosystem contract handles airdrops, rewards, burning, and partnerships
 * @dev Implements a secure and upgradeable DAO ecosystem
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {ILENDEFI} from "../interfaces/ILendefi.sol";
import {IECOSYSTEM} from "../interfaces/IEcosystem.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20 as TH} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @custom:oz-upgrades-from contracts/ecosystem/Ecosystem.sol:Ecosystem
contract EcosystemV2 is
    IECOSYSTEM,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
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
    /// @dev Addresses of vesting contracts issued to partners
    mapping(address src => address vesting) public vestingContracts;
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor

    constructor() {
        _disableInitializers();
    }

    /// @dev Prevents receiving Ether
    receive() external payable {
        revert("NO_ETHER_ACCEPTED");
    }
    /**
     * @dev Initializes the ecosystem contract.
     * @notice Sets up the initial state of the contract, including roles and token supplies.
     * @param token The address of the governance token.
     * @param guardian The address of the guardian (admin).
     * @param pauser The address of the pauser.
     * @custom:requires All input addresses must not be zero.
     * @custom:requires-role DEFAULT_ADMIN_ROLE for the guardian.
     * @custom:requires-role PAUSER_ROLE for the pauser.
     * @custom:events-emits {Initialized} event.
     * @custom:throws CustomError("ZERO_ADDRESS_DETECTED") if any of the input addresses are zero.
     */

    function initialize(address token, address guardian, address pauser) external initializer {
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        if (token != address(0x0) && guardian != address(0x0) && pauser != address(0x0)) {
            _grantRole(DEFAULT_ADMIN_ROLE, guardian);
            _grantRole(PAUSER_ROLE, pauser);

            tokenInstance = ILENDEFI(payable(token));
            uint256 initialSupply = tokenInstance.initialSupply();
            rewardSupply = (initialSupply * 26) / 100;
            airdropSupply = (initialSupply * 10) / 100;
            partnershipSupply = (initialSupply * 8) / 100;
            maxReward = rewardSupply / 1000;
            maxBurn = rewardSupply / 50;

            ++version;
            emit Initialized(msg.sender);
        } else {
            revert CustomError("ZERO_ADDRESS_DETECTED");
        }
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
     * @dev Performs an airdrop to a list of winners.
     * @notice Distributes a specified amount of tokens to each address in the winners array.
     * @param winners An array of addresses to receive the airdrop.
     * @param amount The amount of tokens to be airdropped to each address.
     * @custom:requires-role MANAGER_ROLE
     * @custom:requires Contract must not be paused
     * @custom:requires Amount must be at least 1 ether
     * @custom:requires Total airdropped amount must not exceed the airdrop supply
     * @custom:requires Number of winners must not exceed 4000 to avoid gas limit issues
     * @custom:events-emits {AirDrop} event
     * @custom:throws CustomError("INVALID_AMOUNT") if the amount is less than 1 ether
     * @custom:throws CustomError("AIRDROP_SUPPLY_LIMIT") if the total airdropped amount exceeds the airdrop supply
     * @custom:throws CustomError("GAS_LIMIT") if the number of winners exceeds 4000
     */
    function airdrop(address[] calldata winners, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(MANAGER_ROLE)
    {
        if (amount < 1 ether) revert CustomError("INVALID_AMOUNT");
        uint256 len = winners.length;

        if (issuedAirDrop + len * amount > airdropSupply) {
            revert CustomError("AIRDROP_SUPPLY_LIMIT");
        }

        issuedAirDrop += len * amount;
        emit AirDrop(winners, amount);

        if (len <= 4000) {
            for (uint256 i; i < len; ++i) {
                TH.safeTransfer(tokenInstance, winners[i], amount);
            }
        } else {
            revert CustomError("GAS_LIMIT");
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
     * @custom:throws CustomError("INVALID_AMOUNT") if the amount is 0
     * @custom:throws CustomError("REWARD_LIMIT") if the amount exceeds the maximum reward limit
     * @custom:throws CustomError("REWARD_SUPPLY_LIMIT") if the total rewarded amount exceeds the reward supply
     */
    function reward(address to, uint256 amount) external nonReentrant whenNotPaused onlyRole(REWARDER_ROLE) {
        if (amount == 0) revert CustomError("INVALID_AMOUNT");
        if (amount > maxReward) revert CustomError("REWARD_LIMIT");
        if (issuedReward + amount > rewardSupply) {
            revert CustomError("REWARD_SUPPLY_LIMIT");
        }

        issuedReward += amount;
        emit Reward(msg.sender, to, amount);
        TH.safeTransfer(tokenInstance, to, amount);
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
     * @custom:throws CustomError("INVALID_AMOUNT") if the amount is 0
     * @custom:throws CustomError("BURN_SUPPLY_LIMIT") if the total burned amount exceeds the reward supply
     * @custom:throws CustomError("MAX_BURN_LIMIT") if the amount exceeds the maximum burn limit
     */
    function burn(uint256 amount) external nonReentrant whenNotPaused onlyRole(BURNER_ROLE) {
        if (amount == 0) revert CustomError("INVALID_AMOUNT");
        if (issuedReward + amount > rewardSupply) {
            revert CustomError("BURN_SUPPLY_LIMIT");
        }

        if (amount > maxBurn) revert CustomError("MAX_BURN_LIMIT");
        rewardSupply -= amount;
        emit Burn(msg.sender, amount);
        tokenInstance.burn(amount);
    }

    /**
     * @dev Creates and funds a new vesting contract for a new partner.
     * @notice Adds a new partner by creating a vesting contract and transferring the specified amount of tokens.
     * @param partner The address of the partner to receive the vesting contract.
     * @param amount The amount of tokens to be vested.
     * @param cliff The duration in seconds of the cliff period.
     * @param duration The duration in seconds of the vesting period.
     * @custom:requires-role MANAGER_ROLE
     * @custom:requires Contract must not be paused
     * @custom:requires Partner address must not be zero
     * @custom:requires Amount must be between 100 ether and half of the partnership supply
     * @custom:requires Total issued partnership tokens must not exceed the partnership supply
     * @custom:events-emits {AddPartner} event
     * @custom:throws CustomError("INVALID_ADDRESS") if the partner address is zero
     * @custom:throws CustomError("PARTNER_EXISTS") if the partner already has a vesting contract
     * @custom:throws CustomError("INVALID_AMOUNT") if the amount is not within the valid range
     * @custom:throws CustomError("AMOUNT_EXCEEDS_SUPPLY") if the total issued partnership tokens exceed the partnership supply
     */
    function addPartner(address partner, uint256 amount, uint256 cliff, uint256 duration)
        external
        nonReentrant
        whenNotPaused
        onlyRole(MANAGER_ROLE)
    {
        if (partner == address(0)) revert CustomError("INVALID_ADDRESS");
        if (vestingContracts[partner] != address(0)) {
            revert CustomError("PARTNER_EXISTS");
        }
        if (amount > partnershipSupply / 2 || amount < 100 ether) {
            revert CustomError("INVALID_AMOUNT");
        }
        if (issuedPartnership + amount > partnershipSupply) {
            revert CustomError("AMOUNT_EXCEEDS_SUPPLY");
        }

        issuedPartnership += amount;

        VestingWallet vestingContract =
            new VestingWallet(partner, SafeCast.toUint64(block.timestamp + cliff), SafeCast.toUint64(duration));

        vestingContracts[partner] = address(vestingContract);

        emit AddPartner(partner, address(vestingContract), amount);
        TH.safeTransfer(tokenInstance, address(vestingContract), amount);
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
     * @custom:throws CustomError("INVALID_AMOUNT") if the amount is 0
     * @custom:throws CustomError("EXCESSIVE_MAX_REWARD") if the amount exceeds 5% of remaining reward supply
     */
    function updateMaxReward(uint256 newMaxReward) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (newMaxReward == 0) revert CustomError("INVALID_AMOUNT");

        // Ensure the maximum reward isn't excessive (no more than 5% of remaining reward supply)
        uint256 remainingRewards = rewardSupply - issuedReward;
        if (newMaxReward > remainingRewards / 20) {
            revert CustomError("EXCESSIVE_MAX_REWARD");
        }

        uint256 oldMaxReward = maxReward;
        maxReward = newMaxReward;

        emit MaxRewardUpdated(msg.sender, oldMaxReward, newMaxReward);
    }

    /**
     * @dev Authorizes an upgrade to a new implementation.
     * @notice This function is called during the upgrade process to authorize the new implementation.
     * @param newImplementation The address of the new implementation contract.
     * @custom:requires-role UPGRADER_ROLE
     * @custom:events-emits {Upgrade} event
     */
    /// @inheritdoc UUPSUpgradeable

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
