// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO Governor
 * @notice Standard OZUpgradeable governor with UUPS and AccessControl
 * @dev Implements a secure and upgradeable DAO governor with consistent role patterns
 * @custom:security-contact security@nebula-labs.xyz
 */

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {GovernorUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {GovernorSettingsUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import {GovernorCountingSimpleUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import {
    GovernorVotesUpgradeable,
    IVotes
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import {GovernorVotesQuorumFractionUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import {
    GovernorTimelockControlUpgradeable,
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";

/// @custom:oz-upgrades
contract LendefiGovernor is
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    /**
     * @notice Structure to store pending upgrade details
     * @param implementation Address of the new implementation contract
     * @param scheduledTime Timestamp when the upgrade was scheduled
     * @param exists Boolean flag indicating if an upgrade is currently scheduled
     */
    struct UpgradeRequest {
        address implementation;
        uint64 scheduledTime;
        bool exists;
    }

    /**
     * @dev Role identifier for addresses that can upgrade the contract
     * @custom:security Should be granted carefully as this is a critical permission
     */
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @notice Default voting delay in blocks (approximately 1 day)
     * @dev The period after a proposal is created during which voting cannot start
     */
    uint48 public constant DEFAULT_VOTING_DELAY = 7200; // ~1 day

    /**
     * @notice Default voting period in blocks (approximately 1 week)
     * @dev The period during which voting can occur
     */
    uint32 public constant DEFAULT_VOTING_PERIOD = 50400; // ~1 week

    /**
     * @notice Default proposal threshold (20,000 tokens)
     * @dev The minimum number of votes needed to submit a proposal
     */
    uint256 public constant DEFAULT_PROPOSAL_THRESHOLD = 20_000 ether; // 20,000 tokens

    /**
     * @notice Duration of the timelock for upgrade operations (3 days)
     * @dev Time that must elapse between scheduling and executing an upgrade
     * @custom:security Provides time for users to respond to potentially malicious upgrades
     */
    uint256 public constant UPGRADE_TIMELOCK_DURATION = 3 days;

    /**
     * @notice UUPS upgrade version tracker
     * @dev Incremented with each upgrade to track contract versions
     */
    uint32 public uupsVersion;

    /**
     * @notice Information about the currently pending upgrade
     * @dev Will have exists=false if no upgrade is pending
     */
    UpgradeRequest public pendingUpgrade;

    /**
     * @dev Reserved storage space for future upgrades
     * @custom:oz-upgrades-unsafe-allow state-variable-immutable
     */
    uint256[21] private __gap;

    /**
     * @notice Emitted when the contract is initialized
     * @param src The address that initialized the contract
     */
    event Initialized(address indexed src);

    /**
     * @notice Emitted when the contract is upgraded
     * @param src The address that executed the upgrade
     * @param implementation The address of the new implementation
     */
    event Upgrade(address indexed src, address indexed implementation);

    /**
     * @notice Emitted when an upgrade is scheduled
     * @param scheduler The address scheduling the upgrade
     * @param implementation The new implementation contract address
     * @param scheduledTime The timestamp when the upgrade was scheduled
     * @param effectiveTime The timestamp when the upgrade can be executed
     */
    event UpgradeScheduled(
        address indexed scheduler, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );

    /**
     * @notice Emitted when a scheduled upgrade is cancelled
     * @param canceller The address that cancelled the upgrade
     * @param implementation The implementation address that was cancelled
     */
    event UpgradeCancelled(address indexed canceller, address indexed implementation);

    /**
     * @notice Error thrown when a zero address is provided
     */
    error ZeroAddress();

    /**
     * @notice Error thrown when attempting to execute an upgrade before timelock expires
     * @param timeRemaining The time remaining until the upgrade can be executed
     */
    error UpgradeTimelockActive(uint256 timeRemaining);

    /**
     * @notice Error thrown when attempting to execute an upgrade that wasn't scheduled
     */
    error UpgradeNotScheduled();

    /**
     * @notice Error thrown when implementation address doesn't match scheduled upgrade
     * @param scheduledImpl The address that was scheduled for upgrade
     * @param attemptedImpl The address that was attempted to be used
     */
    error ImplementationMismatch(address scheduledImpl, address attemptedImpl);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the UUPS contract
     * @param _token IVotes token instance
     * @param _timelock timelock instance
     * @param _gnosisSafe multisig address for emergency functions and upgrades
     */
    function initialize(IVotes _token, TimelockControllerUpgradeable _timelock, address _gnosisSafe)
        external
        initializer
    {
        if (_gnosisSafe == address(0) || address(_timelock) == address(0) || address(_token) == address(0)) {
            revert ZeroAddress();
        }

        __Governor_init("Lendefi Governor");
        __GovernorSettings_init(DEFAULT_VOTING_DELAY, DEFAULT_VOTING_PERIOD, DEFAULT_PROPOSAL_THRESHOLD);
        __GovernorCountingSimple_init();
        __GovernorVotes_init(_token);
        __GovernorVotesQuorumFraction_init(1);
        __GovernorTimelockControl_init(_timelock);
        __AccessControl_init();
        __UUPSUpgradeable_init();

        // Role setup consistent with other contracts
        _grantRole(DEFAULT_ADMIN_ROLE, address(_timelock));
        _grantRole(UPGRADER_ROLE, _gnosisSafe);

        ++uupsVersion;
        emit Initialized(msg.sender);
    }

    /**
     * @notice Schedules an upgrade to a new implementation with timelock
     * @dev Can only be called by addresses with UPGRADER_ROLE
     * @param newImplementation Address of the new implementation contract
     */
    function scheduleUpgrade(address newImplementation) external onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();

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
     * @notice Returns the remaining time before a scheduled upgrade can be executed
     * @return timeRemaining The time remaining in seconds, or 0 if no upgrade is scheduled or timelock has passed
     */
    function upgradeTimelockRemaining() external view returns (uint256) {
        return pendingUpgrade.exists && block.timestamp < pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION
            ? pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION - block.timestamp
            : 0;
    }

    // The following functions are overrides required by Solidity.

    /// @inheritdoc GovernorUpgradeable
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(GovernorUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /// @inheritdoc GovernorUpgradeable
    function votingDelay() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingDelay();
    }

    /// @inheritdoc GovernorUpgradeable
    function votingPeriod() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingPeriod();
    }

    /// @inheritdoc GovernorUpgradeable
    function quorum(uint256 blockNumber)
        public
        view
        override(GovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    /// @inheritdoc GovernorUpgradeable
    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    /// @inheritdoc GovernorUpgradeable
    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    /// @inheritdoc GovernorUpgradeable
    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    /// @inheritdoc GovernorUpgradeable
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc GovernorUpgradeable
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc GovernorUpgradeable
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc UUPSUpgradeable
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

        ++uupsVersion;
        emit Upgrade(msg.sender, newImplementation);
    }

    /// @inheritdoc GovernorUpgradeable
    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }
}
