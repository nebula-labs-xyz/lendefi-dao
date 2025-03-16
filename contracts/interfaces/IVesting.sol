// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title Interface for Lendefi DAO Investor Vesting Contract
 * @custom:security-contact security@nebula-labs.xyz
 */

interface IVESTING {
    /// @notice  event emmited when contract cancelled
    /// @param amount tokens returned
    event Cancelled(uint256 amount);

    /**
     * @dev ERC20Released Event
     * @param token address
     * @param amount released
     */
    event ERC20Released(address indexed token, uint256 amount);

    /**
     * @notice Error thrown when a zero address is provided where a valid address is required
     * @dev Used in validation of constructor parameters
     */
    error ZeroAddress();

    /// @dev Getter for the start timestamp
    /// @return start timestamp
    function start() external returns (uint256);

    /// @dev Getter for the duration period
    /// @return duration seconds
    function duration() external returns (uint256);

    /// @dev Getter for the end timestamp.
    /// @return end timestamp
    function end() external returns (uint256);

    /// @dev Amount of token already released
    /// @return amount released
    function released() external returns (uint256);

    /// @dev Getter for the amount of releasable ERC20 tokens.
    /// @return available amount
    function releasable() external returns (uint256);

    /// @dev Release the tokens that have already vested.
    /// Emits a {ERC20Released} event.
    function release() external;
}
