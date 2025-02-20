// SPDX-License-Identifier: MIT
// Derived from OpenZeppelin Contracts (last updated v5.0.0) (finance/VestingWallet.sol)
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO Treasury Contract
 * @notice Vesting contract: initialRelease + (36 month duration)
 * @notice Offers flexible withdrawal schedule (gas efficient)
 * @dev Implements secure and upgradeable DAO treasury with linear vesting
 * @custom:security-contact security@nebula-labs.xysz
 */

import {ITREASURY} from "../interfaces/ITreasury.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @custom:oz-upgrades
contract Treasury is
    ITREASURY,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    /// @dev AccessControl Pauser Role
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @dev AccessControl Manager Role
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @dev AccessControl Upgrader Role
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @dev ETH amount released so far
    uint256 private _released;
    /// @dev start timestamp
    uint64 private _start;
    /// @dev duration seconds
    uint64 private _duration;
    /// @dev UUPS version
    uint32 public version;
    /// @dev token amounts released so far
    mapping(address token => uint256) private _erc20Released;
    /// @dev upgrade gap
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice solidity receive function
    receive() external payable virtual {
        emit Received(msg.sender, msg.value);
    }

    /**
     * @dev Initializes the UUPS contract
     * @param guardian admin address
     * @param timelock address of timelock contract
     */
    function initialize(address guardian, address timelock) external initializer {
        // Initialize upgradeable contracts
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(MANAGER_ROLE, timelock);

        // Set up vesting schedule
        // 180 days before current time as start
        _start = SafeCast.toUint64(block.timestamp - 180 days);
        // 3 years (1095 days) duration
        _duration = SafeCast.toUint64(1095 days);

        // Increment version and emit event
        version = 1;
        emit Initialized(msg.sender);
    }

    /**
     * @dev Pauses all token transfers and releases.
     * @notice Emergency function to pause contract operations
     * @custom:requires-role PAUSER_ROLE
     * @custom:events-emits {Paused} from PausableUpgradeable
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses token transfers and releases.
     * @notice Resumes normal contract operations after pause
     * @custom:requires-role PAUSER_ROLE
     * @custom:events-emits {Unpaused} from PausableUpgradeable
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Release the native token (ether) that have already vested.
     * @notice Allows the manager to release vested ETH to a beneficiary
     * @param to The address that will receive the vested ETH
     * @param amount The amount of ETH to release
     * @custom:requires-role MANAGER_ROLE
     * @custom:requires Contract must not be paused
     * @custom:requires Amount must not exceed vested amount
     * @custom:requires Beneficiary address must not be zero
     * @custom:security non-reentrant
     * @custom:access restricted to MANAGER_ROLE
     * @custom:events-emits {EtherReleased}
     */
    function release(address to, uint256 amount) external nonReentrant whenNotPaused onlyRole(MANAGER_ROLE) {
        uint256 vested = releasable();
        if (to == address(0)) revert CustomError({msg: "ZERO_ADDRESS"});
        if (amount > vested) revert CustomError({msg: "NOT_ENOUGH_VESTED"});
        _released += amount;
        emit EtherReleased(to, amount);
        Address.sendValue(payable(to), amount);
    }

    /**
     * @dev Release the ERC20 tokens that have already vested.
     * @notice Allows the manager to release vested tokens to a beneficiary
     * @param token The address of the ERC20 token to release
     * @param to The address that will receive the vested tokens
     * @param amount The amount of tokens to release
     * @custom:requires-role MANAGER_ROLE
     * @custom:requires Contract must not be paused
     * @custom:requires Amount must not exceed vested amount
     * @custom:requires Token address must not be zero
     * @custom:requires Beneficiary address must not be zero
     * @custom:access restricted to MANAGER_ROLE
     * @custom:events-emits {ERC20Released}
     */
    function release(address token, address to, uint256 amount) external whenNotPaused onlyRole(MANAGER_ROLE) {
        uint256 vested = releasable(token);
        if (to == address(0)) revert CustomError({msg: "ZERO_ADDRESS"});
        if (amount > vested) revert CustomError({msg: "NOT_ENOUGH_VESTED"});
        _erc20Released[token] += amount;
        emit ERC20Released(token, to, amount);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    /**
     * @dev Getter for the start timestamp.
     * @return start timestamp
     */
    function start() public view virtual returns (uint256) {
        return _start;
    }

    /**
     * @dev Getter for the vesting duration.
     * @return duration seconds
     */
    function duration() public view virtual returns (uint256) {
        return _duration;
    }

    /**
     * @dev Getter for the end timestamp.
     * @return end timnestamp
     */
    function end() public view virtual returns (uint256) {
        return start() + duration();
    }

    /**
     * @dev Getter for the amount of eth already released
     * @return amount of ETH released so far
     */
    function released() public view virtual returns (uint256) {
        return _released;
    }

    /**
     * @dev Getter for the amount of token already released
     * @param token address
     * @return amount of tokens released so far
     */
    function released(address token) public view virtual returns (uint256) {
        return _erc20Released[token];
    }

    /**
     * @dev Getter for the amount of releasable eth.
     * @return amount of vested ETH
     */
    function releasable() public view virtual returns (uint256) {
        return vestedAmount(SafeCast.toUint64(block.timestamp)) - released();
    }

    /**
     * @dev Getter for the amount of vested `ERC20` tokens.
     * @param token address
     * @return amount of vested tokens
     */
    function releasable(address token) public view virtual returns (uint256) {
        return vestedAmount(token, SafeCast.toUint64(block.timestamp)) - released(token);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }

    /**
     * @dev Calculates the amount of ETH that has already vested. Default implementation is a linear vesting curve.
     * @param timestamp current timestamp
     * @return amount ETH vested
     */
    function vestedAmount(uint64 timestamp) internal view virtual returns (uint256) {
        return _vestingSchedule(address(this).balance + released(), timestamp);
    }

    /**
     * @dev Calculates the amount of tokens that has already vested. Default implementation is a linear vesting curve.
     * @param token address of token
     * @param timestamp current timestamp
     * @return amount vested
     */
    function vestedAmount(address token, uint64 timestamp) internal view virtual returns (uint256) {
        return _vestingSchedule(IERC20(token).balanceOf(address(this)) + released(token), timestamp);
    }

    /**
     * @dev Virtual implementation of the vesting formula. This returns the amount vested, as a function of time, for
     * an asset given its total historical allocation.
     * @param totalAllocation initial amount
     * @param timestamp current timestamp
     * @return amount vested
     */
    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp) internal view virtual returns (uint256) {
        if (timestamp < start()) {
            return 0;
        } else if (timestamp >= end()) {
            return totalAllocation;
        }
        return (totalAllocation * (timestamp - start())) / duration();
    }
}
