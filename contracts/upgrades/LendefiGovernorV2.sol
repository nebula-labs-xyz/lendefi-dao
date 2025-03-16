// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO GovernorV2 (for testing upgrades)
 * @notice Standard OZUpgradeable governor, small modification with UUPS
 * @dev Implements a secure and upgradeable DAO governor
 * @custom:security-contact security@nebula-labs.xyz
 */

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
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

/// @custom:oz-upgrades-from contracts/ecosystem/LendefiGovernor.sol:LendefiGovernor
contract LendefiGovernorV2 is
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable
{
    /// @dev UUPS version tracker
    uint32 public uupsVersion;

    /// @dev GnosisSafe address for emergency operations
    address public gnosisSafe;

    /// @dev Emergency action constants
    uint48 public constant DEFAULT_VOTING_DELAY = 7200; // ~1 day
    uint32 public constant DEFAULT_VOTING_PERIOD = 50400; // ~1 week
    uint256 public constant DEFAULT_PROPOSAL_THRESHOLD = 20_000 ether; // 20,000 tokens

    /// @dev Upgrade timelock duration in seconds (3 days)
    uint256 public constant UPGRADE_TIMELOCK_DURATION = 3 days;

    /// @dev Structure to hold upgrade request details
    struct UpgradeRequest {
        address implementation;
        uint64 scheduledTime;
        bool exists;
    }

    /// @dev Pending upgrade information
    UpgradeRequest public pendingUpgrade;
    /// @dev Storage gap for future upgrades
    uint256[22] private __gap;

    /**
     * @dev Initialized Event.
     * @param src sender address
     */
    event Initialized(address indexed src);

    /**
     * @dev event emitted on UUPS upgrade
     * @param src upgrade sender address
     * @param implementation new implementation address
     */
    event Upgrade(address indexed src, address indexed implementation);

    /**
     * @dev Event emitted when an upgrade is scheduled
     * @param scheduler address scheduling the upgrade
     * @param implementation new implementation address
     * @param scheduledTime when upgrade was scheduled
     * @param effectiveTime when upgrade can be executed
     */
    event UpgradeScheduled(
        address indexed scheduler, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );

    /**
     * @dev Event emitted when governance settings are updated via emergency reset
     */
    event GovernanceSettingsUpdated(
        address indexed caller, uint256 votingDelay, uint256 votingPeriod, uint256 proposalThreshold
    );

    /**
     * @dev Event emitted when gnosisSafe address is updated
     */
    event GnosisSafeUpdated(address indexed oldGnosisSafe, address indexed newGnosisSafe);

    /**
     * @dev Error thrown when an address parameter is zero
     */
    error ZeroAddress();

    /**
     * @dev Error thrown when unauthorized access
     */
    error UnauthorizedAccess();

    /**
     * @dev Error thrown when trying to upgrade before timelock expires
     */
    error UpgradeTimelockActive(uint256 timeRemaining);

    /**
     * @dev Error thrown when trying to upgrade without scheduling first
     */
    error UpgradeNotScheduled();

    /**
     * @dev Error thrown when implementation address doesn't match scheduled upgrade
     */
    error ImplementationMismatch(address scheduledImpl, address attemptedImpl);

    /**
     * @dev Modifier to restrict access to gnosisSafe only
     */
    modifier onlyGnosisSafe() {
        if (msg.sender != gnosisSafe) revert UnauthorizedAccess();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the UUPS contract
     * @param _token IVotes token instance
     * @param _timelock timelock instance
     * @param _gnosisSafe gnosis safe address for emergency functions and upgrades
     */
    function initialize(IVotes _token, TimelockControllerUpgradeable _timelock, address _gnosisSafe)
        external
        initializer
    {
        if (_gnosisSafe == address(0x0) || address(_timelock) == address(0x0) || address(_token) == address(0x0)) {
            revert ZeroAddress();
        }

        __Governor_init("Lendefi Governor");
        __GovernorSettings_init(DEFAULT_VOTING_DELAY, DEFAULT_VOTING_PERIOD, DEFAULT_PROPOSAL_THRESHOLD);
        __GovernorCountingSimple_init();
        __GovernorVotes_init(_token);
        __GovernorVotesQuorumFraction_init(1);
        __GovernorTimelockControl_init(_timelock);
        __Ownable_init(_gnosisSafe); // Set the gnosisSafe as the owner
        __UUPSUpgradeable_init();

        // Set gnosisSafe address
        gnosisSafe = _gnosisSafe;

        ++uupsVersion;
        emit Initialized(msg.sender);
    }

    /**
     * @notice Updates the gnosisSafe address
     * @dev Can only be called by the current gnosisSafe address
     * @param newGnosisSafe The new gnosisSafe address
     */
    function updateGnosisSafe(address newGnosisSafe) external onlyGnosisSafe {
        if (newGnosisSafe == address(0x0)) {
            revert ZeroAddress();
        }
        address oldGnosisSafe = gnosisSafe;
        gnosisSafe = newGnosisSafe;
        emit GnosisSafeUpdated(oldGnosisSafe, newGnosisSafe);
    }
    /**
     * @notice Schedules an upgrade to a new implementation with timelock
     * @dev Can only be called by the gnosisSafe address
     * @param newImplementation Address of the new implementation contract
     */

    function scheduleUpgrade(address newImplementation) external onlyGnosisSafe {
        if (newImplementation == address(0)) revert ZeroAddress();

        uint64 currentTime = uint64(block.timestamp);
        uint64 effectiveTime = currentTime + uint64(UPGRADE_TIMELOCK_DURATION);

        pendingUpgrade = UpgradeRequest({implementation: newImplementation, scheduledTime: currentTime, exists: true});

        emit UpgradeScheduled(msg.sender, newImplementation, currentTime, effectiveTime);
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

    /// @inheritdoc GovernorUpgradeable
    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyGnosisSafe {
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
}
