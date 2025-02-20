// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Team Manager Interface
 * @notice Interface for the Lendefi DAO Team Manager
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

interface ITEAMMANAGER {
    /**
     * @dev Initialized Event.
     * @param src sender address
     */
    event Initialized(address indexed src);

    /**
     * @dev Upgrade Event.
     * @param src sender address
     * @param implementation address
     */
    event Upgrade(address indexed src, address indexed implementation);

    /**
     * @dev AddTeamMember Event.
     * @param account member address
     * @param vesting contract address
     * @param amount of tokens allocated to vesting
     */
    event AddTeamMember(address indexed account, address indexed vesting, uint256 amount);

    /**
     * @dev Custom Error.
     * @param msg error desription
     */
    error CustomError(string msg);

    /**
     * @dev Pause contract.
     */
    function pause() external;

    /**
     * @dev Unpause contract.
     */
    function unpause() external;

    /**
     * @dev Create and fund a vesting contract for a new team member
     * @param beneficiary beneficiary address
     * @param amount token amount
     * @param cliff cliff period in seconds
     * @param duration vesting duration in seconds after cliff  (e.g. 24 months)
     */
    function addTeamMember(address beneficiary, uint256 amount, uint256 cliff, uint256 duration) external;

    /**
     * @dev Getter for the UUPS version, incremented each time an upgrade occurs.
     * @return version number (1,2,3)
     */
    function version() external view returns (uint32);

    /**
     * @dev Getter for the amount of tokens allocated to team member.
     * @param account address
     * @return amount of tokens allocated to member
     */
    function allocations(address account) external view returns (uint256);

    /**
     * @dev Getter for the  address of vesting contract created for team member.
     * @param account address
     * @return vesting contract address
     */
    function vestingContracts(address account) external view returns (address);

    /**
     * @dev Starting supply allocated to team.
     * @return amount
     */
    function supply() external view returns (uint256);

    /**
     * @dev Total amount of token allocated so far.
     * @return amount
     */
    function totalAllocation() external view returns (uint256);
}
