// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title Lendefi DAO Ecosystem Team Manager
 * @notice Creates and deploys team vesting contracts
 * @dev Implements a secure and upgradeable team manager for the DAO
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */
import {ILENDEFI} from "../interfaces/ILendefi.sol";
import {ITEAMMANAGER} from "../interfaces/ITeamManager.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20 as TH} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TeamVesting} from "../ecosystem/TeamVesting.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @custom:oz-upgrades-from contracts/ecosystem/TeamManager.sol:TeamManager
contract TeamManagerV2 is
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
    /// @dev Minimum cliff period (6 months)
    uint64 public constant MIN_CLIFF = 90 days;
    /// @dev Maximum cliff period (2 years)
    uint64 public constant MAX_CLIFF = 365 days;
    /// @dev Minimum vesting duration (1 year)
    uint64 public constant MIN_DURATION = 365 days;
    /// @dev Maximum vesting duration (4 years)
    uint64 public constant MAX_DURATION = 1460 days;

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
    /// @dev token allocations to team members
    mapping(address src => uint256 amount) public allocations;
    /// @dev vesting contract addresses for team members
    mapping(address src => address vesting) public vestingContracts;
    /// @dev gap for future storage variables
    uint256[50] private __gap;

    // ============ Constructor ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    /// @dev Prevents receiving Ether

    receive() external payable {
        revert("NO_ETHER_ACCEPTED");
    }
    // ============ External Functions ============

    /**
     * @notice Initializes the team manager contract
     * @dev Sets up the initial state of the contract with core functionality:
     *      1. Initializes upgradeable base contracts
     *      2. Sets up access control roles
     *      3. Configures token and supply parameters
     * @param token The address of the ecosystem token contract
     * @param timelock_ The address of the timelock controller
     * @param guardian The address of the admin who will receive DEFAULT_ADMIN_ROLE
     * @custom:requires-role None - can only be called once during initialization
     * @custom:security Implements initializer modifier to prevent re-initialization
     * @custom:security Validates all input addresses are non-zero
     * @custom:events-emits Initialized(msg.sender)
     * @custom:throws CustomError("ZERO_ADDRESS_DETECTED") if any input address is zero
     */
    function initialize(address token, address timelock_, address guardian) external initializer {
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (token != address(0x0) && timelock_ != address(0x0) && guardian != address(0x0)) {
            _grantRole(DEFAULT_ADMIN_ROLE, guardian);
            _grantRole(MANAGER_ROLE, timelock_);

            timelock = timelock_;
            ecosystemToken = ILENDEFI(payable(token));
            supply = (ecosystemToken.initialSupply() * TEAM_ALLOCATION_PERCENT) / 100;
            ++version;
            emit Initialized(msg.sender);
        } else {
            revert CustomError("ZERO_ADDRESS_DETECTED");
        }
    }

    /**
     * @notice Pauses all contract operations
     * @dev Prevents execution of state-modifying functions
     * @custom:requires-role PAUSER_ROLE
     * @custom:security Inherits OpenZeppelin's PausableUpgradeable
     * @custom:events-emits {Paused} event from PausableUpgradeable
     * @custom:throws Unauthorized if caller lacks PAUSER_ROLE
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Resumes all contract operations
     * @dev Re-enables execution of state-modifying functions
     * @custom:requires-role PAUSER_ROLE
     * @custom:security Inherits OpenZeppelin's PausableUpgradeable
     * @custom:events-emits {Unpaused} event from PausableUpgradeable
     * @custom:throws Unauthorized if caller lacks PAUSER_ROLE
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
     * @custom:requires beneficiary must not be zero address
     * @custom:requires cliff must be between MIN_CLIFF and MAX_CLIFF
     * @custom:requires duration must be between MIN_DURATION and MAX_DURATION
     * @custom:requires amount must not exceed remaining supply
     * @custom:throws CustomError("SUPPLY_LIMIT") if allocation exceeds supply
     * @custom:throws CustomError("INVALID_BENEFICIARY") if beneficiary is zero address
     * @custom:throws CustomError("INVALID_CLIFF") if cliff period is invalid
     * @custom:throws CustomError("INVALID_DURATION") if duration is invalid
     * @custom:throws CustomError("ALREADY_ADDED") if beneficiary already has allocation
     */
    function addTeamMember(address beneficiary, uint256 amount, uint256 cliff, uint256 duration)
        external
        nonReentrant
        whenNotPaused
        onlyRole(MANAGER_ROLE)
    {
        if (beneficiary == address(0)) {
            revert CustomError("INVALID_BENEFICIARY");
        }

        if (vestingContracts[beneficiary] != address(0)) {
            revert CustomError("ALREADY_ADDED");
        }

        if (cliff < MIN_CLIFF || cliff > MAX_CLIFF) {
            revert CustomError("INVALID_CLIFF");
        }

        if (duration < MIN_DURATION || duration > MAX_DURATION) {
            revert CustomError("INVALID_DURATION");
        }

        if (totalAllocation + amount > supply) {
            revert CustomError("SUPPLY_LIMIT");
        }

        totalAllocation += amount;

        TeamVesting vestingContract = new TeamVesting(
            address(ecosystemToken),
            timelock,
            beneficiary,
            SafeCast.toUint64(block.timestamp + cliff),
            SafeCast.toUint64(duration)
        );

        allocations[beneficiary] = amount;
        vestingContracts[beneficiary] = address(vestingContract);

        emit AddTeamMember(beneficiary, address(vestingContract), amount);
        TH.safeTransfer(ecosystemToken, address(vestingContract), amount);
    }

    // ============ Internal Functions ============

    /**
     * @notice Authorizes and processes contract upgrades
     * @dev Internal override for UUPS upgrade authorization
     * @dev Performs:
     *      1. Validates caller has UPGRADER_ROLE
     *      2. Increments contract version
     *      3. Emits upgrade event with details
     * @param newImplementation Address of the new implementation contract
     * @custom:throws Unauthorized if caller lacks UPGRADER_ROLE
     * @custom:emits Upgrade event with upgrader address and new implementation
     * @custom:security Role-based access control via UPGRADER_ROLE
     * @custom:security Version tracking for upgrade management
     * @custom:security Inherits OpenZeppelin's UUPSUpgradeable pattern
     * @inheritdoc UUPSUpgradeable
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
