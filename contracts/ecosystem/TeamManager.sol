// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title Lendefi DAO Ecosystem Team Manager
 * @notice Creates and deploys team vesting contracts
 * @dev Implements a secure and upgradeable team manager with upgrade timelock
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */
import {ILENDEFI} from "../interfaces/ILendefi.sol";
import {ITEAMMANAGER} from "../interfaces/ITeamManager.sol";
import {SafeERC20 as TH} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TeamVesting} from "./TeamVesting.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @custom:oz-upgrades
contract TeamManager is
    ITEAMMANAGER,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ============ Constants ============

    /// @dev Team allocation percentage of total supply (18%)
    uint256 private constant TEAM_ALLOCATION_PERCENT = 18;
    /// @dev Minimum cliff period (3 months)
    uint64 private constant MIN_CLIFF = 90 days;
    /// @dev Maximum cliff period (1 year)
    uint64 private constant MAX_CLIFF = 365 days;
    /// @dev Minimum vesting duration (1 year)
    uint64 private constant MIN_DURATION = 365 days;
    /// @dev Maximum vesting duration (4 years)
    uint64 private constant MAX_DURATION = 1460 days;
    /// @dev Upgrade timelock duration (4 days)
    uint256 private constant UPGRADE_TIMELOCK_DURATION = 3 days;

    /// @dev AccessControl Pauser Role
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @dev AccessControl Manager Role
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @dev AccessControl Upgrader Role
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============ Storage Variables ============

    /// @dev governance token instance
    ILENDEFI internal ecosystemToken;
    /// @dev amount of ecosystem tokens in the contract
    uint256 public supply;
    /// @dev amount of tokens allocated so far
    uint256 public totalAllocation;
    /// @dev timelock address
    address public timelock;
    /// @dev number of UUPS upgrades
    uint32 public version;

    /// @dev Pending upgrade information
    UpgradeRequest public pendingUpgrade;

    /// @dev token allocations to team members
    mapping(address src => uint256 amount) public allocations;
    /// @dev vesting contract addresses for team members
    mapping(address src => address vesting) public vestingContracts;

    /// @dev gap for future storage variables (50 - 8 existing variables = 42)
    uint256[22] private __gap;

    /**
     * @dev Modifier to check for non-zero address
     * @param addr The address to check
     */
    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    /**
     * @dev Modifier to check for non-zero amount
     * @param amount The amount to check
     */
    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }
    // ============ Constructor & Receive Function ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Prevents receiving Ether
    receive() external payable {
        revert ValidationFailed("NO_ETHER_ACCEPTED");
    }

    // ============ External Functions ============

    /**
     * @notice Initializes the team manager contract
     * @dev Sets up the initial state of the contract with core functionality
     * @param token The address of the ecosystem token contract
     * @param timelock_ The address of the timelock controller
     * @param guardian The address of the admin who receives PAUSER_ROLE
     * @param multisig The address receiving UPGRADER_ROLE
     */
    function initialize(address token, address timelock_, address guardian, address multisig) external initializer {
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (token == address(0) || timelock_ == address(0) || guardian == address(0) || multisig == address(0)) {
            revert ZeroAddress();
        }

        // Set up roles properly
        _grantRole(DEFAULT_ADMIN_ROLE, timelock_);
        _grantRole(PAUSER_ROLE, guardian);
        _grantRole(MANAGER_ROLE, timelock_);
        _grantRole(UPGRADER_ROLE, multisig);

        timelock = timelock_;
        ecosystemToken = ILENDEFI(payable(token));
        supply = (ecosystemToken.initialSupply() * TEAM_ALLOCATION_PERCENT) / 100;

        version = 1;
        emit Initialized(msg.sender);
    }

    /**
     * @notice Pauses all contract operations
     * @dev Prevents execution of state-modifying functions
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Resumes all contract operations
     * @dev Re-enables execution of state-modifying functions
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Create and fund a vesting contract for a new team member
     * @param beneficiary The address of the team member
     * @param amount The amount of tokens to vest
     * @param cliff The cliff period in seconds
     * @param duration The vesting duration in seconds after cliff
     */
    function addTeamMember(address beneficiary, uint256 amount, uint256 cliff, uint256 duration)
        external
        nonReentrant
        whenNotPaused
        onlyRole(MANAGER_ROLE)
        nonZeroAddress(beneficiary)
        nonZeroAmount(amount)
    {
        if (vestingContracts[beneficiary] != address(0)) {
            revert BeneficiaryAlreadyExists(beneficiary);
        }

        if (cliff < MIN_CLIFF || cliff > MAX_CLIFF) {
            revert InvalidCliff(cliff, MIN_CLIFF, MAX_CLIFF);
        }

        if (duration < MIN_DURATION || duration > MAX_DURATION) {
            revert InvalidDuration(duration, MIN_DURATION, MAX_DURATION);
        }

        uint256 availableSupply = supply - totalAllocation;
        if (amount > availableSupply) {
            revert SupplyExceeded(amount, availableSupply);
        }

        totalAllocation += amount;

        TeamVesting vestingContract = new TeamVesting(
            address(ecosystemToken), timelock, beneficiary, uint64(block.timestamp + cliff), uint64(duration)
        );

        allocations[beneficiary] = amount;
        vestingContracts[beneficiary] = address(vestingContract);

        emit AddTeamMember(beneficiary, address(vestingContract), amount);
        TH.safeTransfer(ecosystemToken, address(vestingContract), amount);
    }

    /**
     * @dev Schedules an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
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
     * @dev Returns the remaining time before a scheduled upgrade can be executed
     * @return timeRemaining The time remaining in seconds, or 0 if no upgrade is scheduled or timelock has passed
     */
    function upgradeTimelockRemaining() external view returns (uint256) {
        return pendingUpgrade.exists && block.timestamp < pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION
            ? pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION - block.timestamp
            : 0;
    }

    // ============ Internal Functions ============

    /**
     * @notice Authorizes and processes contract upgrades with timelock enforcement
     * @dev Internal override for UUPS upgrade authorization
     * @param newImplementation Address of the new implementation contract
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
