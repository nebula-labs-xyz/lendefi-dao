// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title PartnerVesting Contract
 * @author alexei@nebula-labs(dot)xyz
 * @notice Manages linear token vesting for Lendefi partners
 * @dev Implements a time-based linear vesting schedule with partner control and DAO cancellation capability
 * @custom:security-contact security@nebula-labs.xyz
 */

import {IPARTNERVESTING} from "../interfaces/IPartnerVesting.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PartnerVesting is IPARTNERVESTING, Context, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Start timestamp of the vesting period
    uint64 private immutable _start;

    /// @dev Duration of the vesting period in seconds
    uint64 private immutable _duration;

    /// @dev Address of the token being vested
    address private immutable _token;

    /// @dev Address that created this contract (Ecosystem contract)
    address public immutable _creator;

    /// @dev Running total of tokens that have been released
    uint256 private _tokensReleased;

    /**
     * @notice Restricts function access to the contract creator only
     * @dev Used for cancellation functionality
     */
    modifier onlyAuthorized() {
        _checkAuthorized();
        _;
    }

    /**
     * @notice Creates a new vesting contract for a partner
     * @dev Sets the beneficiary as the owner, initializes immutable vesting parameters
     * @param token Address of the ERC20 token to be vested
     * @param beneficiary Address that will receive the vested tokens
     * @param startTimestamp UNIX timestamp when vesting begins
     * @param durationSeconds Duration of vesting period in seconds
     */
    constructor(address token, address beneficiary, uint64 startTimestamp, uint64 durationSeconds)
        Ownable(beneficiary)
    {
        if (token == address(0) || beneficiary == address(0)) {
            revert ZeroAddress();
        }

        _token = token;
        _creator = msg.sender; // Store the creator (Ecosystem contract)
        _start = startTimestamp;
        _duration = durationSeconds;

        emit VestingInitialized(token, beneficiary, startTimestamp, durationSeconds);
    }

    /**
     * @notice Cancels the vesting contract, releasing vested tokens and returning unvested tokens
     * @dev First releases any vested tokens to the beneficiary, then returns remaining tokens to creator
     * @return remainder The amount of tokens returned to the creator
     */
    function cancelContract() external nonReentrant onlyAuthorized returns (uint256 remainder) {
        IERC20 tokenInstance = IERC20(_token);
        uint256 releasableAmount = releasable();

        // Release vested tokens directly without calling release()
        if (releasableAmount > 0) {
            _tokensReleased += releasableAmount;
            emit ERC20Released(_token, releasableAmount);
            tokenInstance.safeTransfer(owner(), releasableAmount);
        }

        // Get current balance
        remainder = tokenInstance.balanceOf(address(this));

        // Only emit event and transfer if there are tokens to transfer
        if (remainder > 0) {
            emit Cancelled(remainder);
            tokenInstance.safeTransfer(_creator, remainder);
        }
    }

    /**
     * @notice Releases vested tokens to the beneficiary
     * @dev Can be called by anyone but tokens are always sent to the owner (beneficiary)
     */
    function release() public virtual nonReentrant {
        uint256 amount = releasable();
        if (amount == 0) return;

        _tokensReleased += amount;
        emit ERC20Released(_token, amount);
        IERC20(_token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Returns the timestamp when vesting starts
     * @return The start timestamp of the vesting period
     */
    function start() public view virtual returns (uint256) {
        return _start;
    }

    /**
     * @notice Returns the duration of the vesting period
     * @return The duration in seconds of the vesting period
     */
    function duration() public view virtual returns (uint256) {
        return _duration;
    }

    /**
     * @notice Returns the timestamp when vesting ends
     * @return The end timestamp of the vesting period
     */
    function end() public view virtual returns (uint256) {
        return start() + duration();
    }

    /**
     * @notice Returns the amount of tokens already released
     * @return The amount of tokens that have been released so far
     */
    function released() public view virtual returns (uint256) {
        return _tokensReleased;
    }

    /**
     * @notice Calculates the amount of tokens that can be released now
     * @return The amount of tokens currently available to be released
     */
    function releasable() public view virtual returns (uint256) {
        return vestedAmount(uint64(block.timestamp)) - released();
    }

    /**
     * @notice Calculates the amount of tokens that have vested by a given timestamp
     * @dev Internal function used by releasable()
     * @param timestamp The timestamp to calculate vested amount for
     * @return The total amount of tokens vested at the specified timestamp
     */
    function vestedAmount(uint64 timestamp) internal view virtual returns (uint256) {
        return _vestingSchedule(IERC20(_token).balanceOf(address(this)) + released(), timestamp);
    }

    /**
     * @notice Calculates vested tokens according to the linear vesting schedule
     * @dev Implements the core vesting calculation logic
     * @param totalAllocation Total token allocation (current balance + already released)
     * @param timestamp The timestamp to calculate vested amount for
     * @return The amount of tokens vested at the specified timestamp
     */
    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp) internal view virtual returns (uint256) {
        if (timestamp < start()) {
            return 0;
        } else if (timestamp >= end()) {
            return totalAllocation;
        }
        return (totalAllocation * (timestamp - start())) / duration();
    }

    /**
     * @notice Verifies the caller is authorized to perform creator-only actions
     * @dev Throws Unauthorized error if caller is not the creator
     */
    function _checkAuthorized() internal view virtual {
        if (_creator != _msgSender()) {
            revert Unauthorized();
        }
    }
}
