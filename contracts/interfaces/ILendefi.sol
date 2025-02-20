// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title Governance Token Interface
 * @custom:security-contact security@nebula-labs.xyz
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

interface ILENDEFI is IERC20, IERC20Metadata {
    /**
     * @dev TGE Event.
     * @param amount of initial supply
     */
    event TGE(uint256 amount);

    /**
     * @dev BridgeMint Event.
     * @param src sender address
     * @param to beneficiary address
     * @param amount to bridge
     */
    event BridgeMint(address indexed src, address indexed to, uint256 amount);

    /// @dev event emitted on UUPS upgrades
    /// @param src sender address
    /// @param implementation new implementation address
    event Upgrade(address indexed src, address indexed implementation);

    /**
     * @dev UUPS deploy proxy initializer.
     * @param admin address
     */
    function initializeUUPS(address admin) external;

    /**
     * @dev Performs TGE.
     * @param ecosystem contract address
     * @param treasury contract address
     * Emits a {TGE} event.
     */
    function initializeTGE(address ecosystem, address treasury) external;

    /**
     * @dev ERC20 pause contract.
     */
    function pause() external;

    /**
     * @dev ERC20 unpause contract.
     */
    function unpause() external;

    /**
     * @dev ERC20 Burn.
     * @param amount of tokens to burn
     * Emits a {Burn} event.
     */
    function burn(uint256 amount) external;

    /**
     * @dev ERC20 burn from.
     * @param account address
     * @param amount of tokens to burn from
     * Emits a {Burn} event.
     */
    function burnFrom(address account, uint256 amount) external;

    /**
     * @dev Facilitates Bridge BnM functionality.
     * @param to beneficiary address
     * @param amount to bridge
     */
    function bridgeMint(address to, uint256 amount) external;

    /**
     * @dev Getter for the Initial supply.
     * @return initial supply at TGE
     */
    function initialSupply() external view returns (uint256);

    /**
     * @dev Getter for the maximum amount alowed to pass through bridge in a single transaction.
     * @return maximum bridge transaction size
     */
    function maxBridge() external view returns (uint256);

    /**
     * @dev Getter for the UUPS version, incremented with every upgrade.
     * @return version number (1,2,3)
     */
    function version() external view returns (uint32);
}
