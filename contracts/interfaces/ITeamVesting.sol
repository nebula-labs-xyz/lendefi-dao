// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title Team Vesting Interface
 * @custom:security-contact security@nebula-labs.xyz
 */

interface ITEAMVESTING {
    /**
     * @dev Cancelled Event
     * @param amount that was refunded to the treasury
     */
    event Cancelled(uint256 amount);

    /**
     * @dev ERC20Released Event
     * @param token address
     * @param amount released
     */
    event ERC20Released(address indexed token, uint256 amount);

    /**
     * @dev Contract initialization event
     */
    event VestingInitialized(
        address indexed token,
        address indexed beneficiary,
        address indexed timelock,
        uint64 startTimestamp,
        uint64 duration
    );
    /**
     * @notice Error thrown when an unauthorized address attempts a restricted action
     * @dev Used to restrict functions that should only be callable by the contract creator
     */

    error Unauthorized();

    /**
     * @notice Error thrown when a zero address is provided where a valid address is required
     * @dev Used in validation of constructor parameters
     */
    error ZeroAddress();

    /**
     * @dev Getter for the start timestamp.
     * @return start timestamp
     */
    function start() external returns (uint256);

    /**
     * @dev Getter for the vesting duration.
     * @return duration seconds
     */
    function duration() external returns (uint256);

    /**
     * @dev Getter for the end timestamp.
     * @return end timestamp
     */
    function end() external returns (uint256);

    /**
     * @dev Getter for the amount of token already released
     * @return amount of tokens released so far
     */
    function released() external returns (uint256);

    /**
     * @dev Getter for the amount of releasable `token` ERC20 tokens.
     * @return amount of vested tokens
     */
    function releasable() external returns (uint256);

    /**
     * @dev Release the tokens that have already vested.
     *
     * Emits a {ERC20Released} event.
     */
    function release() external;

    /**
     * @dev Release the tokens that have already vested.
     *
     * Emits a {ERC20Released} event.
     *
     * Refund the remainder to the timelock
     */
    function cancelContract() external returns (uint256 remainder);
}
