// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title Treasury Interface
 * @custom:security-contact security@nebula-labs.xyz
 */

interface ITREASURY {
    /**
     * @dev Initialized Event.
     * @param src sender address
     */
    event Initialized(address indexed src);

    /**
     * @dev Received Event
     * @param src sender address
     * @param amount amount
     */
    event Received(address indexed src, uint256 amount);

    /**
     * @dev Upgrade Event.
     * @param src sender address
     * @param implementation address
     */
    event Upgrade(address indexed src, address indexed implementation);

    /**
     * @dev EtherReleased Event
     * @param to beneficiary address
     * @param amount amount of ETH to transfer
     */
    event EtherReleased(address indexed to, uint256 amount);

    /**
     * @dev ERC20Released Event
     * @param token address
     * @param to address
     * @param amount released
     */
    event ERC20Released(address indexed token, address indexed to, uint256 amount);

    /**
     * @dev Custom Error.
     * @param msg error desription
     */
    error CustomError(string msg);

    /**
     * @dev UUPS version incremented every upgrade
     * @return version number
     */
    function version() external returns (uint32);

    /**
     * @dev Pause contract
     */
    function pause() external;

    /**
     * @dev Unpause contract.
     */
    function unpause() external;

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
     * @return end timnestamp
     */
    function end() external returns (uint256);

    /**
     * @dev Getter for the amount of eth already released
     * @return amount of ETH released so far
     */
    function released() external returns (uint256);

    /**
     * @dev Getter for the amount of token already released
     * @param token address
     * @return amount of tokens released so far
     */
    function released(address token) external returns (uint256);

    /**
     * @dev Getter for the amount of releasable eth.
     * @return amount of vested ETH
     */
    function releasable() external returns (uint256);

    /**
     * @dev Getter for the amount of vested `ERC20` tokens.
     * @param token address
     * @return amount of vested tokens
     */
    function releasable(address token) external returns (uint256);

    /**
     * @dev Release the native token (ether) that have already vested.
     * @param to beneficiary address
     * @param amount amount of ETH to transfer
     * Emits a {EtherReleased} event.
     */
    function release(address to, uint256 amount) external;

    /**
     * @dev Release the tokens that have already vested.
     * @param token token address
     * @param to beneficiary address
     * @param amount amount of tokens to transfer
     * Emits a {ERC20Released} event.
     */
    function release(address token, address to, uint256 amount) external;
}
