// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO GovernanceTokenV2 (for testing upgrades)
 * @notice Burnable contract that votes and has BnM-Bridge functionality
 * @dev Implements a secure and upgradeable DAO governance token
 * @custom:security-contact security@nebula-labs.xyz
 */

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20BurnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {ERC20VotesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {
    ERC20PermitUpgradeable,
    NoncesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/// @custom:oz-upgrades-from contracts/ecosystem/GovernanceToken.sol:GovernanceToken
contract GovernanceTokenV2 is
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    UUPSUpgradeable
{
    /// @dev Upgrade timelock storage
    struct UpgradeRequest {
        address implementation;
        uint64 scheduledTime;
        bool exists;
    }
    // ============ Constants ============

    /// @notice Token supply and distribution constants
    uint256 private constant INITIAL_SUPPLY = 50_000_000 ether;
    uint256 private constant DEFAULT_MAX_BRIDGE_AMOUNT = 5_000 ether; // Reduced from 20,000
    uint256 private constant TREASURY_SHARE = 27_400_000 ether;
    uint256 private constant ECOSYSTEM_SHARE = 22_000_000 ether;
    uint256 private constant DEPLOYER_SHARE = 600_000 ether; // 1.2% of initial supply to satisfy the Governor quorum

    /// @notice Upgrade timelock duration (in seconds)
    uint256 private constant UPGRADE_TIMELOCK_DURATION = 3 days;

    /// @dev AccessControl Role Constants
    bytes32 internal constant TGE_ROLE = keccak256("TGE_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // ============ Storage Variables ============

    /// @dev Initial token supply
    uint256 public initialSupply;
    /// @dev max bridge passthrough amount
    uint256 public maxBridge;
    /// @dev number of UUPS upgrades
    uint32 public version;
    /// @dev tge initialized variable
    uint32 public tge;

    UpgradeRequest public pendingUpgrade;

    /// @dev Storage gap for future upgrades
    uint256[48] private __gap;

    // ============ Events ============

    /**
     * @dev Initialized Event.
     * @param src sender address
     */
    event Initialized(address indexed src);

    /// @dev event emitted at TGE
    /// @param amount token amount
    event TGE(uint256 amount);

    /**
     * @dev event emitted when bridge triggers a mint
     * @param src sender
     * @param to beneficiary address
     * @param amount token amount
     */
    event BridgeMint(address indexed src, address indexed to, uint256 amount);

    /**
     * @dev Emitted when the maximum bridge amount is updated
     * @param admin The address that updated the value
     * @param oldMaxBridge Previous maximum bridge amount
     * @param newMaxBridge New maximum bridge amount
     */
    event MaxBridgeUpdated(address indexed admin, uint256 oldMaxBridge, uint256 newMaxBridge);

    /**
     * @dev Emitted when a bridge role is assigned
     * @param admin The admin who set the role
     * @param bridgeAddress The bridge address receiving the role
     */
    event BridgeRoleAssigned(address indexed admin, address indexed bridgeAddress);

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
     * @dev Upgrade Event.
     * @param src sender address
     * @param implementation address
     */
    event Upgrade(address indexed src, address indexed implementation);

    // ============ Errors ============

    /// @dev Error thrown when an address parameter is zero
    error ZeroAddress();

    /// @dev Error thrown when an amount parameter is zero
    error ZeroAmount();

    /// @dev Error thrown when a mint would exceed the max supply
    error MaxSupplyExceeded(uint256 requested, uint256 maxAllowed);

    /// @dev Error thrown when bridge amount exceeds allowed limit
    error BridgeAmountExceeded(uint256 requested, uint256 maxAllowed);

    /// @dev Error thrown when TGE is already initialized
    error TGEAlreadyInitialized();

    /// @dev Error thrown when addresses don't match expected values
    error InvalidAddress(address provided, string reason);

    /// @dev Error thrown when trying to execute an upgrade too soon
    error UpgradeTimelockActive(uint256 remainingTime);

    /// @dev Error thrown when trying to execute an upgrade that wasn't scheduled
    error UpgradeNotScheduled();

    /// @dev Error thrown when trying to execute an upgrade with wrong implementation
    error ImplementationMismatch(address expected, address provided);

    /// @dev Error thrown for general validation failures
    error ValidationFailed(string reason);

    /**
     * @dev Modifier to check for non-zero amounts
     * @param amount The amount to validate
     */
    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    /**
     * @dev Modifier to check for non-zero addresses
     * @param addr The address to validate
     */
    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {
        revert ValidationFailed("NO_ETHER_ACCEPTED");
    }

    /**
     * @dev Initializes the UUPS contract.
     * @notice Sets up the initial state of the contract, including roles and token supplies.
     * @param guardian The address of the guardian (admin).
     * @param timelock The address of the timelock controller.
     * @custom:requires The addresses must not be zero.
     * @custom:events-emits {Initialized} event.
     * @custom:throws ZeroAddress if any address is zero.
     */
    function initializeUUPS(address guardian, address timelock) external initializer {
        if (guardian == address(0) || timelock == address(0)) revert ZeroAddress();

        __ERC20_init("Lendefi DAO", "LEND");
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __AccessControl_init();
        __ERC20Permit_init("Lendefi DAO");
        __ERC20Votes_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(MANAGER_ROLE, timelock);
        _grantRole(PAUSER_ROLE, timelock);
        _grantRole(UPGRADER_ROLE, timelock);
        _grantRole(TGE_ROLE, guardian);

        initialSupply = INITIAL_SUPPLY;
        maxBridge = DEFAULT_MAX_BRIDGE_AMOUNT;

        version = 1;
        emit Initialized(msg.sender);
    }

    /**
     * @dev Sets the bridge address with BRIDGE_ROLE
     * @param bridgeAddress The address of the bridge contract
     * @custom:requires-role MANAGER_ROLE
     * @custom:throws ZeroAddress if bridgeAddress is zero
     */
    function setBridgeAddress(address bridgeAddress) external onlyRole(MANAGER_ROLE) {
        if (bridgeAddress == address(0)) revert ZeroAddress();

        _grantRole(BRIDGE_ROLE, bridgeAddress);

        emit BridgeRoleAssigned(msg.sender, bridgeAddress);
    }

    /**
     * @dev Initializes the Token Generation Event (TGE).
     * @notice Sets up the initial token distribution between the ecosystem and treasury contracts.
     * @param ecosystem The address of the ecosystem contract.
     * @param treasury The address of the treasury contract.
     * @custom:requires The ecosystem and treasury addresses must not be zero.
     * @custom:requires TGE must not be already initialized.
     * @custom:events-emits {TGE} event.
     * @custom:throws ZeroAddress if any address is zero.
     * @custom:throws TGEAlreadyInitialized if TGE was already initialized.
     */
    function initializeTGE(address ecosystem, address treasury) external onlyRole(TGE_ROLE) {
        if (ecosystem == address(0)) revert InvalidAddress(ecosystem, "Ecosystem address cannot be zero");
        if (treasury == address(0)) revert InvalidAddress(treasury, "Treasury address cannot be zero");
        if (tge > 0) revert TGEAlreadyInitialized();

        ++tge;

        // Directly mint to target addresses instead of minting to this contract first
        _mint(treasury, TREASURY_SHARE);
        _mint(ecosystem, ECOSYSTEM_SHARE);
        _mint(msg.sender, DEPLOYER_SHARE);

        emit TGE(initialSupply);
    }

    /**
     * @dev Pauses all token transfers and operations.
     * @notice This function can be called by an account with the PAUSER_ROLE to pause the contract.
     * @custom:requires-role PAUSER_ROLE
     * @custom:events-emits {Paused} event from PausableUpgradeable
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses all token transfers and operations.
     * @notice This function can be called by an account with the PAUSER_ROLE to unpause the contract.
     * @custom:requires-role PAUSER_ROLE
     * @custom:events-emits {Unpaused} event from PausableUpgradeable
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Mints tokens for cross-chain bridge transfers
     * @param to Address receiving the tokens
     * @param amount Amount to mint
     * @notice Can only be called by the official Bridge contract
     * @custom:requires-role BRIDGE_ROLE
     * @custom:requires Total supply must not exceed initialSupply
     * @custom:requires to address must not be zero
     * @custom:requires amount must not be zero or exceed maxBridge limit
     * @custom:events-emits {BridgeMint} event
     * @custom:throws ZeroAddress if recipient address is zero
     * @custom:throws ZeroAmount if amount is zero
     * @custom:throws BridgeAmountExceeded if amount exceeds maxBridge
     * @custom:throws MaxSupplyExceeded if the mint would exceed initialSupply
     */
    function bridgeMint(address to, uint256 amount)
        external
        nonZeroAddress(to)
        nonZeroAmount(amount)
        whenNotPaused
        onlyRole(BRIDGE_ROLE)
    {
        if (amount > maxBridge) revert BridgeAmountExceeded(amount, maxBridge);

        // Supply constraint validation
        uint256 newSupply = totalSupply() + amount;
        if (newSupply > initialSupply) {
            revert MaxSupplyExceeded(newSupply, initialSupply);
        }

        // Mint tokens
        _mint(to, amount);

        // Emit event
        emit BridgeMint(msg.sender, to, amount);
    }

    /**
     * @dev Updates the maximum allowed bridge amount per transaction
     * @param newMaxBridge New maximum bridge amount
     * @notice Only callable by manager role
     * @custom:requires-role MANAGER_ROLE
     * @custom:requires New amount must be greater than zero and less than 1% of total supply
     * @custom:events-emits {MaxBridgeUpdated} event
     * @custom:throws ZeroAmount if newMaxBridge is zero
     * @custom:throws ValidationFailed if bridge amount is too high
     */
    function updateMaxBridgeAmount(uint256 newMaxBridge) external nonZeroAmount(newMaxBridge) onlyRole(MANAGER_ROLE) {
        // Add a reasonable cap, e.g., 1% of initial supply
        if (newMaxBridge > initialSupply / 100) revert ValidationFailed("Bridge amount too high");

        uint256 oldMaxBridge = maxBridge;
        maxBridge = newMaxBridge;

        emit MaxBridgeUpdated(msg.sender, oldMaxBridge, newMaxBridge);
    }

    /**
     * @dev Schedules an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     * @notice Only callable by an address with UPGRADER_ROLE
     * @custom:requires-role UPGRADER_ROLE
     * @custom:events-emits {UpgradeScheduled} event
     * @custom:throws ZeroAddress if newImplementation is zero
     */
    function scheduleUpgrade(address newImplementation)
        external
        nonZeroAddress(newImplementation)
        onlyRole(UPGRADER_ROLE)
    {
        uint64 currentTime = uint64(block.timestamp);
        uint64 effectiveTime = currentTime + uint64(UPGRADE_TIMELOCK_DURATION);

        pendingUpgrade = UpgradeRequest({implementation: newImplementation, scheduledTime: currentTime, exists: true});

        emit UpgradeScheduled(msg.sender, newImplementation, currentTime, effectiveTime);
    }

    /**
     * @notice Cancels a previously scheduled upgrade
     * @dev Only callable by addresses with UPGRADER_ROLE
     */
    function cancelUpgrade() external onlyRole(UPGRADER_ROLE) {
        if (!pendingUpgrade.exists) {
            revert UpgradeNotScheduled();
        }
        address implementation = pendingUpgrade.implementation;
        delete pendingUpgrade;
        emit UpgradeCancelled(msg.sender, implementation);
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

    // The following functions are overrides required by Solidity.
    /// @inheritdoc ERC20PermitUpgradeable
    function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }

    /// @inheritdoc ERC20Upgradeable
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, value);
    }

    /**
     * @dev Internal authorization for contract upgrades with timelock enforcement
     * @param newImplementation Address of the new implementation contract
     * @custom:requires-role UPGRADER_ROLE (enforced by the function modifier)
     * @custom:requires Upgrade must be scheduled and timelock must be expired
     * @custom:throws UpgradeNotScheduled if no upgrade was scheduled
     * @custom:throws UpgradeTimelockActive if timelock period hasn't passed
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

        // Emit the upgrade event
        emit Upgrade(msg.sender, newImplementation);
    }
}
