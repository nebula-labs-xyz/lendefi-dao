// SPDX-License-Identifier: MIT
// Derived from OpenZeppelin Contracts (last updated v5.0.0) (finance/VestingWallet.sol)
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO Investor Vesting Contract
 * @notice Investor Vesting contract
 * @notice Offers flexible withdrawal schedule (gas efficient)
 * @dev Implements linear vesting schedule for investors
 * @custom:security-contact security@nebula-labs.xyz
 */

import {IVESTING} from "../interfaces/IVesting.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract InvestorVesting is IVESTING, Context, Ownable2Step, ReentrancyGuard {
    /// @dev start timestamp
    uint64 private immutable _start;
    /// @dev duration seconds
    uint64 private immutable _duration;
    /// @dev token address
    address private immutable _token;
    /// @dev amount of tokens released
    mapping(address token => uint256 amount) private _erc20Released;

    /**
     * @dev Sets the owner to beneficiary address, the start timestamp and the
     * vesting duration of the vesting contract.
     */
    constructor(address token, address beneficiary, uint64 startTimestamp, uint64 durationSeconds)
        Ownable(beneficiary)
    {
        if (token == address(0) || beneficiary == address(0)) {
            revert ZeroAddress();
        }
        _token = token;
        _start = startTimestamp;
        _duration = durationSeconds;
    }

    /**
     * @dev Release the tokens that have already vested.
     *
     * Emits a {ERC20Released} event.
     */
    function release() public virtual nonReentrant onlyOwner {
        uint256 amount = releasable();
        _erc20Released[_token] += amount;
        emit ERC20Released(_token, amount);
        SafeERC20.safeTransfer(IERC20(_token), owner(), amount);
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
     * @dev Getter for the amount of token already released
     * @return amount of tokens released so far
     */
    function released() public view virtual returns (uint256) {
        return _erc20Released[_token];
    }

    /**
     * @dev Getter for the amount of vested `ERC20` tokens.
     * @return amount of vested tokens
     */
    function releasable() public view virtual returns (uint256) {
        return vestedAmount(SafeCast.toUint64(block.timestamp)) - released();
    }

    /**
     * @dev Calculates the amount of tokens that has already vested. Default implementation is a linear vesting curve.
     * @param timestamp current timestamp
     * @return amount vested
     */
    function vestedAmount(uint64 timestamp) internal view virtual returns (uint256) {
        return _vestingSchedule(IERC20(_token).balanceOf(address(this)) + released(), timestamp);
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
