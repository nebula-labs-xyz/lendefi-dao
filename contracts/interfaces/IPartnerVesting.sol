// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title Partner Vesting Interface
 * @notice Interface for partner vesting contracts with cancellation capabilities
 */
interface IPARTNERVESTING {
    /**
     * @dev Emitted when partner vesting is cancelled and remaining tokens returned to timelock
     */
    event Cancelled(uint256 amount);

    /**
     * @dev Emitted when tokens are released to the beneficiary
     */
    event ERC20Released(address indexed token, uint256 amount);

    /**
     * @notice Cancels the vesting contract and returns unvested funds to timelock
     * @dev Only callable by timelock
     */
    function cancelContract() external returns (uint256);

    /**
     * @notice Releases vested tokens to the beneficiary (partner)
     */
    function release() external;

    /**
     * @notice Returns the amount of tokens that can be released at the current time
     * @return The amount of releasable tokens
     */
    function releasable() external view returns (uint256);

    /**
     * @notice Returns the start time of the vesting period
     * @return The start timestamp
     */
    function start() external view returns (uint256);

    /**
     * @notice Returns the duration of the vesting period in seconds
     * @return The duration in seconds
     */
    function duration() external view returns (uint256);

    /**
     * @notice Returns the end time of the vesting period
     * @return The end timestamp
     */
    function end() external view returns (uint256);

    /**
     * @notice Returns the amount of tokens already released
     * @return The amount of tokens released
     */
    function released() external view returns (uint256);
}
