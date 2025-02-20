// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Ecosystem Interface
 * @custom:security-contact security@nebula-labs.xyz
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

interface IECOSYSTEM {
    /**
     * @dev Initialized Event.
     * @param src sender address
     */
    event Initialized(address indexed src);

    /**
     * @dev Burn Event.
     * @param src, sender
     * @param amount burned
     */
    event Burn(address indexed src, uint256 amount);

    /**
     * @dev Reward Event.
     * @param src, sender
     * @param to beneficiary address
     * @param amount rewarded
     */
    event Reward(address indexed src, address indexed to, uint256 amount);

    /**
     * @dev Airdrop Event.
     * @param winners winner addresses
     * @param amount airdropped per user
     */
    event AirDrop(address[] winners, uint256 amount);

    /**
     * @dev Upgrade Event.
     * @param src sender address
     * @param implementation address
     */
    event Upgrade(address indexed src, address indexed implementation);

    /**
     * @dev AddPartner Event.
     * @param account beneficiary address
     * @param vesting contract address
     * @param amount of token allocated
     */
    event AddPartner(address indexed account, address indexed vesting, uint256 amount);

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
     * @dev Airdrop tokens to community memebers
     * @param winners address array
     * @param amount of tokens
     * Emits a {AirDrop} event.
     */
    function airdrop(address[] calldata winners, uint256 amount) external;

    /**
     * @dev Rewards liquidity providers participating in the Nebula Protocol.
     * @param to address
     * @param amount of tokens
     * Emits a {Reward} event.
     */
    function reward(address to, uint256 amount) external;

    /**
     * @dev Burns tokens from the Ecosystem.
     * @param amount of tokens to burn
     * Emits a {Burn} event.
     */
    function burn(uint256 amount) external;

    /**
     * @dev Creates vesting contracts for partners and funds them.
     * @param account address
     * @param amount token allocation
     * @param cliff cliff period
     * @param duration vesting duration
     * Emits a {AddPartner} event.
     */
    function addPartner(address account, uint256 amount, uint256 cliff, uint256 duration) external;
    /**
     * @dev Getter for the starting reward supply.
     * @return starting reward supply
     */
    function rewardSupply() external view returns (uint256);

    /**
     * @dev Getter for the max one time reward amount.
     * @return maximal one time reward amount
     */
    function maxReward() external view returns (uint256);

    /**
     * @dev Getter for the starting airdrop supply.
     * @return staring airdrop supply
     */
    function airdropSupply() external view returns (uint256);

    /**
     * @dev Getter for the starting partnership supply.
     * @return starting partnership supply
     */
    function partnershipSupply() external view returns (uint256);

    /**
     * @dev Getter for the issued amount of tokens issued as reward.
     * @return total reward amount issued so far
     */
    function issuedReward() external view returns (uint256);

    /**
     * @dev Getter for the issued amount of tokens airdropped.
     * @return total airdroped amount so far
     */
    function issuedAirDrop() external view returns (uint256);

    /**
     * @dev Getter for the issued amount of tokens allocated to partners.
     * @return total partner allocation issued so far
     */
    function issuedPartnership() external view returns (uint256);

    /**
     * @dev Getter for the UUPS version.
     * @return upgrade version (1,2,3)
     */
    function version() external view returns (uint32);

    /**
     * @dev Getter for the vesting contract addresses recorded by the AddPartner function.
     * @param src address
     * @return partner's vesting contract address
     */
    function vestingContracts(address src) external view returns (address);
}
