// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
import {InvestorVesting} from "../../contracts/ecosystem/InvestorVesting.sol"; // Path to your contract

contract InvestorVestingTest is BasicDeploy {
    // Declare variables to interact with your contract
    InvestorVesting public vestingContract;

    // Set up the test environment
    function setUp() public {
        deployComplete();
        assertEq(tokenInstance.totalSupply(), 0);
        // this is the TGE
        vm.startPrank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        uint256 ecoBal = tokenInstance.balanceOf(address(ecoInstance));
        uint256 treasuryBal = tokenInstance.balanceOf(address(treasuryInstance));

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 28_000_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal);

        vestingContract = new InvestorVesting(
            address(tokenInstance),
            alice,
            uint64(block.timestamp + 365 days), // cliff timestamp
            uint64(730 days) // duration after cliff
        );

        address[] memory investors = new address[](1);
        investors[0] = address(vestingContract);

        ecoInstance.grantRole(MANAGER_ROLE, managerAdmin);
        vm.stopPrank();
        vm.prank(managerAdmin);
        ecoInstance.airdrop(investors, 200_000 ether); //put some tokens into vesting contract
    }

    function testConstructorZeroAddress() public {
        // Test zero token address
        vm.expectRevert("ZERO_ADDRESS");
        new InvestorVesting(
            address(0), // zero token address
            alice,
            uint64(block.timestamp + 365 days),
            uint64(730 days)
        );

        // Test zero beneficiary address
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new InvestorVesting(
            address(tokenInstance),
            address(0), // zero beneficiary address
            uint64(block.timestamp + 365 days),
            uint64(730 days)
        );
    }

    // Test case: Check if an investor is added correctly
    function testInvestorAdded() public {
        address owner = vestingContract.owner();
        assertEq(owner, alice, "Investor's is the owner");
    }

    // Test case: Check the vesting claim functionality
    function testClaim() public {
        uint256 amountToClaimBefore = vestingContract.releasable();

        vm.warp(block.timestamp + 450 days); // Move forward in time
        uint256 amountToClaimAfter = vestingContract.releasable();

        assertTrue(amountToClaimAfter > amountToClaimBefore, "Claimable amount should increase over time");

        // Simulate a claim
        vestingContract.release();

        uint256 amountClaimed = vestingContract.released();
        assertEq(amountClaimed, amountToClaimAfter, "Claimed amount should match claimable amount");

        uint256 remainingBalance = tokenInstance.balanceOf(address(vestingContract));

        assertEq(remainingBalance, 200_000 ether - amountClaimed, "Vested amount should reduce after claim");
    }

    // Fuzz Test case: Check the claimable amount under various times
    function testFuzzClaimableAmount(uint256 _daysForward) public {
        vm.assume(_daysForward <= 730); // Assume within vesting period
        // Move forward in time
        vm.warp(block.timestamp + 365 days + _daysForward * 1 days);
        uint256 claimableAmount = vestingContract.releasable();
        uint256 expectedClaimable = (200_000 ether * _daysForward) / 730; // Example of linear vesting

        assertEq(claimableAmount, expectedClaimable, "Claimable amount should be linear based on vesting duration");
    }

    // Fuzz Test: Claim edge cases (before and after vesting period)
    function testFuzzClaimEdgeCases(uint256 _daysForward) public {
        vm.assume(_daysForward <= 730); // Assume max vesting period is 100 days + some buffer

        if (_daysForward >= 730) {
            // If time has passed, ensure claimable is the total vested
            vm.warp(block.timestamp + 365 days + _daysForward * 1 days);
            uint256 claimableAmount = vestingContract.releasable();
            uint256 totalVested = 200_000 ether;
            assertEq(claimableAmount, totalVested, "Claimable should be equal to total vested after the vesting period");
        } else if (_daysForward >= 1) {
            // Check that claimable amount is progressively increasing over time
            uint256 claimableAmountBefore = vestingContract.releasable();
            vm.warp(block.timestamp + 365 days + _daysForward * 1 days);
            uint256 claimableAmountAfter = vestingContract.releasable();
            assertTrue(claimableAmountAfter > claimableAmountBefore, "Claimable amount should increase over time");
        }
    }

    // Test case: Edge case of claiming after the vesting period
    function testClaimAfterVestingPeriod() public {
        vm.warp(block.timestamp + 1095 days); // Move beyond the vesting period

        uint256 claimableAmount = vestingContract.releasable();
        uint256 totalVested = 200_000 ether;

        assertEq(
            claimableAmount,
            totalVested,
            "Claimable amount should be equal to the total vested after the vesting period"
        );
    }

    // Test case: Ensure no double claiming
    function testNoDoubleClaiming() public {
        vm.warp(block.timestamp + 700 days);
        vestingContract.release(); // First claim
        uint256 claimAmountAfterFirstClaim = vestingContract.released();
        assertTrue(claimAmountAfterFirstClaim > 0, "Claim should be successful");

        // Trying to claim again should not change anything
        vestingContract.release();
        uint256 claimAmountAfterSecondClaim = vestingContract.released();

        assertEq(claimAmountAfterFirstClaim, claimAmountAfterSecondClaim);
    }

    // Fuzz Test: Ensure no claim is possible before vesting starts
    function testFuzzNoClaimBeforeVesting(uint256 _daysBefore) public {
        vm.assume(_daysBefore <= 365); //cliff
        vm.warp(block.timestamp + _daysBefore * 1 days);

        uint256 claimableBeforeStart = vestingContract.releasable();
        assertEq(claimableBeforeStart, 0, "Claimable amount should be 0 before the vesting period starts");
    }
}
