// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title IERC20Bridgable Interface
 * @custom:security-contact security@nebula-labs.xyz
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20Bridgable is IERC20 {
    /**
     * @dev BridgeMint Event.
     * @param to beneficiary address
     * @param amount rewarded
     */
    event BridgeMint(address indexed to, uint256 amount);

    /**
     * @dev Burns tokens.
     * @param amount of tokens to burn
     * Emits a {Burn} event. Inherited from ERC20Burnable
     */
    function burn(uint256 amount) external;

    /**
     * @dev BnM BridgeMint.
     * @param to address
     * @param amount of tokens
     * Emits a {BridgeMint} event.
     */
    function bridgeMint(address to, uint256 amount) external;
}
