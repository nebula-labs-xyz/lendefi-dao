// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPARTNERVESTING} from "../interfaces/IPartnerVesting.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PartnerVesting is IPARTNERVESTING, Context, Ownable2Step, ReentrancyGuard {
    /// @dev start timestamp
    uint64 private immutable _start;
    /// @dev duration seconds
    uint64 private immutable _duration;
    /// @dev token address
    address private immutable _token;
    /// @dev timelock address
    address public immutable _timelock;
    /// @dev creator address (Ecosystem)
    address public immutable _creator;
    /// @dev amount of tokens released
    uint256 private _tokensReleased;

    /**
     * @dev Throws if called by any account other than the timelock or creator.
     */
    modifier onlyAuthorized() {
        _checkAuthorized();
        _;
    }

    /**
     * @dev Sets the owner to partner address (beneficiary), the start timestamp and the
     * vesting duration of the vesting contract.
     */
    constructor(address token, address timelock, address beneficiary, uint64 startTimestamp, uint64 durationSeconds)
        Ownable(beneficiary)
    {
        if (token == address(0) || timelock == address(0) || beneficiary == address(0)) {
            revert ZeroAddress();
        }

        _token = token;
        _timelock = timelock;
        _creator = msg.sender; // Store the creator (Ecosystem contract)
        _start = startTimestamp;
        _duration = durationSeconds;

        emit VestingInitialized(token, beneficiary, timelock, startTimestamp, durationSeconds);
    }

    /**
     * @dev Allows the DAO to cancel the contract in case the partnership ends.
     * First releases any vested tokens to the beneficiary, then returns
     * the remaining unvested tokens to the creator (Ecosystem contract).
     * @return remainder The amount of tokens returned to the creator
     * Can only be called by the creator (Ecosystem contract).
     */
    function cancelContract() external nonReentrant onlyAuthorized returns (uint256 remainder) {
        IERC20 tokenInstance = IERC20(_token);
        uint256 releasableAmount = releasable();

        // Release vested tokens directly without calling release()
        if (releasableAmount > 0) {
            _tokensReleased += releasableAmount;
            emit ERC20Released(_token, releasableAmount);
            SafeERC20.safeTransfer(tokenInstance, owner(), releasableAmount);
        }

        // Get current balance
        remainder = tokenInstance.balanceOf(address(this));

        // Only emit event and transfer if there are tokens to transfer
        if (remainder > 0) {
            emit Cancelled(remainder);
            SafeERC20.safeTransfer(tokenInstance, _creator, remainder);
        }
    }

    // Rest of the contract remains the same...
    function release() public virtual nonReentrant {
        uint256 amount = releasable();
        if (amount == 0) return;

        _tokensReleased += amount;
        emit ERC20Released(_token, amount);
        SafeERC20.safeTransfer(IERC20(_token), owner(), amount);
    }

    function start() public view virtual returns (uint256) {
        return _start;
    }

    function duration() public view virtual returns (uint256) {
        return _duration;
    }

    function end() public view virtual returns (uint256) {
        return start() + duration();
    }

    function released() public view virtual returns (uint256) {
        return _tokensReleased;
    }

    function releasable() public view virtual returns (uint256) {
        return vestedAmount(uint64(block.timestamp)) - released();
    }

    function vestedAmount(uint64 timestamp) internal view virtual returns (uint256) {
        return _vestingSchedule(IERC20(_token).balanceOf(address(this)) + released(), timestamp);
    }

    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp) internal view virtual returns (uint256) {
        if (timestamp < start()) {
            return 0;
        } else if (timestamp >= end()) {
            return totalAllocation;
        }
        return (totalAllocation * (timestamp - start())) / duration();
    }

    /**
     * @dev Throws if the sender is not authorized to cancel.
     */
    function _checkAuthorized() internal view virtual {
        if (_creator != _msgSender()) {
            revert Unauthorized();
        }
    }
}
