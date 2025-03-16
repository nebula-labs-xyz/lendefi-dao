// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title PartnerVesting Contract
 * @author alexei@nebula-labs(dot)xyz
 * @notice Interface for PartnerVesting.sol
 * @custom:security-contact security@nebula-labs.xyz
 */
interface IPARTNERVESTING {
    /**
     * @notice Emitted when a new vesting contract is initialized
     * @dev Triggered during contract creation with the vesting parameters
     * @param token Address of the ERC20 token being vested
     * @param beneficiary Address of the partner receiving the vested tokens
     * @param startTimestamp UNIX timestamp when vesting begins
     * @param duration Length of the vesting period in seconds
     */
    event VestingInitialized(
        address indexed token, address indexed beneficiary, uint64 startTimestamp, uint64 duration
    );

    /**
     * @notice Emitted when a vesting contract is cancelled
     * @dev Triggered when the contract creator cancels the vesting and reclaims unvested tokens
     * @param amount The amount of unvested tokens returned to the creator
     */
    event Cancelled(uint256 amount);

    /**
     * @notice Emitted when vested tokens are released to the beneficiary
     * @dev Triggered each time tokens are claimed or automatically released during cancellation
     * @param token Address of the token that was released
     * @param amount The amount of tokens released
     */
    event ERC20Released(address indexed token, uint256 amount);

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
     * @notice Cancels the vesting contract and returns unvested funds to the creator
     * @dev Only callable by the contract creator (typically the Ecosystem contract)
     * @return The amount of tokens returned to the creator
     */
    function cancelContract() external returns (uint256);

    /**
     * @notice Releases vested tokens to the beneficiary (partner)
     * @dev Can be called by anyone, but tokens are always sent to the contract owner (beneficiary)
     */
    function release() external;

    /**
     * @notice Calculates the amount of tokens that can be released at the current time
     * @dev Subtracts already released tokens from the total vested amount
     * @return The amount of tokens currently available for release
     */
    function releasable() external view returns (uint256);

    /**
     * @notice Returns the timestamp when vesting begins
     * @dev This value is immutable and set during contract creation
     * @return The start timestamp of the vesting period
     */
    function start() external view returns (uint256);

    /**
     * @notice Returns the length of the vesting period
     * @dev This value is immutable and set during contract creation
     * @return The duration in seconds of the vesting period
     */
    function duration() external view returns (uint256);

    /**
     * @notice Returns the timestamp when vesting ends
     * @dev Calculated as start() + duration()
     * @return The end timestamp of the vesting period
     */
    function end() external view returns (uint256);

    /**
     * @notice Returns the total amount of tokens that have been released so far
     * @dev Used in vesting calculations to determine how many more tokens can be released
     * @return The cumulative amount of tokens released to the beneficiary
     */
    function released() external view returns (uint256);
}
