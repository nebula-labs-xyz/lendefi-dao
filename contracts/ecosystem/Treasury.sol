// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title Lendefi DAO Treasury
 * @notice Treasury contract with 3-year linear vesting and external multisig support
 * @dev Implements a secure and upgradeable treasury with vesting for ETH and ERC20 tokens
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */
import {ITREASURY} from "../interfaces/ITreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @custom:oz-upgrades
contract Treasury is
    ITREASURY,
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using Address for address payable;
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /**
     * @dev Role identifier for accounts that can release funds
     */
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /**
     * @dev Role identifier for accounts that can pause/unpause the contract
     */
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /**
     * @dev Role identifier for accounts that can upgrade the contract
     */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /**
     * @dev Upgrade timelock duration in seconds (3 days)
     */
    uint256 private constant UPGRADE_TIMELOCK_DURATION = 3 days;

    // ============ State Variables ============

    /**
     * @dev Current version of the contract implementation
     * Incremented during upgrades
     */
    uint32 private _version;

    /**
     * @dev Start timestamp of the vesting schedule
     */
    uint256 private _start;

    /**
     * @dev Duration of the vesting period in seconds
     */
    uint256 private _duration;

    /**
     * @dev Total amount of ETH already released
     */
    uint256 private _released;

    /**
     * @dev Timelock controller address
     */
    address private _timelockAddress;

    /**
     * @dev Mapping of token address to amount released for each token
     */
    mapping(address => uint256) private _erc20Released;

    /**
     * @dev Pending upgrade information
     */
    UpgradeRequest public pendingUpgrade;

    /**
     * @dev Reserved storage space for future upgrades
     * This allows adding new state variables in future versions while maintaining
     * the storage layout (30 - 7 = 23)
     */
    uint256[23] private __gap;

    // ============ Modifiers ============

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

    // ============ Constructor & Initializer ============

    /**
     * @dev Prevents initialization of the implementation contract
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Allows the contract to receive ETH
     * @dev Emits a {Received} event
     */
    receive() external payable virtual {
        emit Received(msg.sender, msg.value);
    }

    /**
     * @notice Initializes the treasury contract
     * @dev Sets up the initial state of the contract
     * @param guardian The address that will have the PAUSER_ROLE
     * @param timelock The address that will have the DEFAULT_ADMIN_ROLE and MANAGER_ROLE
     * @param multisig The address of the Gnosis Safe multisig that will be granted the UPGRADER_ROLE
     * @param startOffset The number of seconds the start time is before the current block timestamp
     * @param vestingDuration The duration of vesting in seconds (must be at least 730 days)
     */
    function initialize(
        address guardian,
        address timelock,
        address multisig,
        uint256 startOffset,
        uint256 vestingDuration
    ) external initializer nonZeroAddress(guardian) nonZeroAddress(timelock) nonZeroAddress(multisig) {
        if (vestingDuration < 730 days) revert InvalidDuration(730 days);

        // Initialize inherited contracts
        __UUPSUpgradeable_init();
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        // Set roles
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(MANAGER_ROLE, timelock);
        _grantRole(PAUSER_ROLE, guardian);
        _grantRole(UPGRADER_ROLE, multisig); // Grant upgrade role to multisig

        _start = block.timestamp - startOffset;
        _duration = vestingDuration;
        _timelockAddress = timelock;
        _version = 1;

        emit Initialized(msg.sender, _start, _duration);
    }

    // ============ External Functions ============

    /**
     * @notice Pauses all token transfers and releases
     * @dev Can only be called by accounts with the PAUSER_ROLE
     */
    function pause() external override onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses token transfers and releases
     * @dev Can only be called by accounts with the PAUSER_ROLE
     */
    function unpause() external override onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Releases a specific amount of vested ETH
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @dev Reverts if the requested amount exceeds vested amount
     * @param to The address that will receive the ETH
     * @param amount The amount of ETH to release
     */
    function release(address to, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(MANAGER_ROLE)
        nonZeroAddress(to)
        nonZeroAmount(amount)
    {
        uint256 vested = releasable();
        if (amount > vested) revert InsufficientVestedAmount(amount, vested);

        _released += amount;
        emit EthReleased(to, amount, vested - amount);

        payable(to).sendValue(amount);
    }

    /**
     * @notice Releases a specific amount of vested tokens
     * @dev Can only be called by accounts with the MANAGER_ROLE
     * @dev Reverts if the requested amount exceeds vested amount
     * @param token The ERC20 token to release
     * @param to The address that will receive the tokens
     * @param amount The amount of tokens to release
     */
    function release(address token, address to, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(MANAGER_ROLE)
        nonZeroAddress(token)
        nonZeroAddress(to)
        nonZeroAmount(amount)
    {
        uint256 vested = releasable(token);
        if (amount > vested) revert InsufficientVestedAmount(amount, vested);

        _erc20Released[token] += amount;
        emit TokenReleased(token, to, amount);

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Updates the vesting schedule parameters
     * @dev Can only be called by accounts with the DEFAULT_ADMIN_ROLE
     * @param newStart The new start timestamp
     * @param newDuration The new duration in seconds
     */
    function updateVestingSchedule(uint256 newStart, uint256 newDuration)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newDuration == 0) revert InvalidDuration(0);

        _start = newStart;
        _duration = newDuration;

        emit VestingScheduleUpdated(msg.sender, newStart, newDuration);
    }

    /**
     * @dev Emergency function to withdraw all tokens to the timelock
     * @param token The ERC20 token to withdraw
     * @notice Only callable by addresses with MANAGER_ROLE
     * @custom:throws ZeroAddress if token address is zero
     * @custom:throws ZeroBalanceError if contract has no token balance
     */
    function emergencyWithdrawToken(address token) external nonReentrant onlyRole(MANAGER_ROLE) nonZeroAddress(token) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroBalance();

        IERC20(token).safeTransfer(_timelockAddress, balance);
        emit EmergencyWithdrawal(token, _timelockAddress, balance);
    }

    /**
     * @dev Emergency function to withdraw all ETH to the timelock
     * @notice Only callable by addresses with MANAGER_ROLE
     * @custom:throws ZeroBalanceError if contract has no ETH balance
     */
    function emergencyWithdrawEther() external nonReentrant onlyRole(MANAGER_ROLE) {
        uint256 balance = address(this).balance;
        if (balance == 0) revert ZeroBalance();

        payable(_timelockAddress).sendValue(balance);
        emit EmergencyWithdrawal(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, _timelockAddress, balance);
    }

    /**
     * @dev Schedules an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function scheduleUpgrade(address newImplementation) external onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();

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

    /**
     * @dev Get the timelock controller address
     * @return The timelock controller address
     */
    function timelockAddress() external view returns (address) {
        return _timelockAddress;
    }

    // ============ Public View Functions ============

    /**
     * @notice Returns the amount of ETH that can be released now
     * @return Amount of releasable ETH
     */
    function releasable() public view virtual override returns (uint256) {
        return vestedAmount(uint256(block.timestamp)) - _released;
    }

    /**
     * @notice Returns the amount of a specific token that can be released now
     * @param token The ERC20 token to check
     * @return Amount of releasable tokens
     */
    function releasable(address token) public view virtual override returns (uint256) {
        return vestedAmount(token, uint256(block.timestamp)) - _erc20Released[token];
    }

    /**
     * @notice Calculates the amount of ETH vested at a specific timestamp
     * @param timestamp The timestamp to check
     * @return The vested amount of ETH
     */
    function vestedAmount(uint256 timestamp) public view virtual override returns (uint256) {
        return _vestingSchedule(address(this).balance + _released, timestamp);
    }

    /**
     * @notice Calculates the amount of tokens vested at a specific timestamp
     * @param token The ERC20 token to check
     * @param timestamp The timestamp to check
     * @return The vested amount of tokens
     */
    function vestedAmount(address token, uint256 timestamp) public view virtual override returns (uint256) {
        uint256 totalAllocation = IERC20(token).balanceOf(address(this)) + _erc20Released[token];
        return _vestingSchedule(totalAllocation, timestamp);
    }

    /**
     * @notice Returns the current contract version
     * @return Current version number
     */
    function version() public view virtual override returns (uint32) {
        return _version;
    }

    /**
     * @notice Returns the start timestamp of the vesting period
     * @return Start timestamp
     */
    function start() public view virtual override returns (uint256) {
        return _start;
    }

    /**
     * @notice Returns the duration of the vesting period
     * @return Duration in seconds
     */
    function duration() public view virtual override returns (uint256) {
        return _duration;
    }

    /**
     * @notice Returns the end timestamp of the vesting period
     * @return End timestamp (start + duration)
     */
    function end() public view virtual override returns (uint256) {
        return start() + duration();
    }

    /**
     * @notice Returns the amount of ETH already released
     * @return Amount of ETH released so far
     */
    function released() public view virtual override returns (uint256) {
        return _released;
    }

    /**
     * @notice Returns the amount of a specific token already released
     * @param token The ERC20 token to check
     * @return Amount of tokens released so far
     */
    function released(address token) public view virtual override returns (uint256) {
        return _erc20Released[token];
    }

    // ============ Internal Functions ============

    /**
     * @dev Internal function to calculate vested amounts for a given allocation and timestamp
     * @dev Uses linear vesting between start and end time
     * @param totalAllocation The total amount to vest
     * @param timestamp The timestamp to check
     * @return The amount vested at the specified timestamp
     */
    function _vestingSchedule(uint256 totalAllocation, uint256 timestamp) internal view virtual returns (uint256) {
        if (timestamp < _start) {
            return 0;
        } else if (timestamp >= _start + _duration) {
            return totalAllocation;
        } else {
            return (totalAllocation * (timestamp - _start)) / _duration;
        }
    }

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
        ++_version;

        // Emit the upgrade event
        emit Upgraded(msg.sender, newImplementation, _version);
    }
}
