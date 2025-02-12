// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title Lendefi Math Interface
 * @author Nebula Labs LLC
 * @custom:security-contact security@nebula-labs.xyz
 */

interface IYODAMATH {
    /**
     * @dev rmul function
     * @param x amount
     * @param y amount
     * @return value
     */
    function rmul(uint256 x, uint256 y) external pure returns (uint256);

    /**
     * @dev rdiv function
     * @param x amount
     * @param y amount
     * @return value
     */
    function rdiv(uint256 x, uint256 y) external pure returns (uint256);

    /**
     * @dev rpow function
     * @param x amount
     * @param n amount
     * @return value
     */
    function rpow(uint256 x, uint256 n) external pure returns (uint256);

    /**
     * @dev Converts rate to rateRay
     * @param rate rate
     * @return rateRay
     */
    function annualRateToRay(uint256 rate) external pure returns (uint256);

    /**
     * @dev Accrues compounded interest
     * @param principal amount
     * @param rateRay rateray
     * @param time duration
     * @return amount (pricipal + compounded interest)
     */
    function accrueInterest(uint256 principal, uint256 rateRay, uint256 time) external pure returns (uint256);

    /**
     * @dev Calculates compounded interest
     * @param principal amount
     * @param rateRay rateray
     * @param time duration
     * @return amount (compounded interest)
     */
    function getInterest(uint256 principal, uint256 rateRay, uint256 time) external pure returns (uint256);

    /**
     * @dev Calculates breakeven borrow rate
     * @param loan amount
     * @param supplyInterest amount
     * @return breakeven borrow rate
     */
    function breakEvenRate(uint256 loan, uint256 supplyInterest) external pure returns (uint256);
}
