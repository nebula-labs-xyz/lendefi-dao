// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
import {TeamVesting} from "../../contracts/ecosystem/TeamVesting.sol"; // Path to your contract

contract TeamVestingTest is BasicDeploy {
    // Declare variables to interact with your contract
    uint256 internal cliff = 365 days;
    uint256 internal amount = 200_000 ether;
    // TeamManager internal tmInstance;
    TeamVesting internal vestingContract;

    event ERC20Released(address indexed token, uint256 amount);
    event AddPartner(address account, address vesting, uint256 amount);

    // Set up initial conditions before each test
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

        vestingContract = new TeamVesting(
            address(tokenInstance),
            address(timelockInstance),
            alice,
            uint64(block.timestamp + 365 days), // cliff timestamp
            uint64(730 days) // duration after cliff
        );

        address[] memory investors = new address[](1);
        investors[0] = address(vestingContract);

        ecoInstance.grantRole(MANAGER_ROLE, managerAdmin);
        vm.stopPrank();
        vm.prank(managerAdmin);
        ecoInstance.airdrop(investors, amount); //put some tokens into vesting contract
    }

    // Test: Contract Initialization
    function testInitialState() public {
        assertEq(vestingContract.owner(), alice);
    }

    // Test: Token Release before Cliff
    function testReleaseTokensBeforeCliff() public {
        uint256 startTime = block.timestamp;

        // Move time forward to before cliff ends
        vm.warp(startTime + cliff - 1);

        // Try to release tokens
        vestingContract.release();
        uint256 vested = vestingContract.releasable();
        assertEq(0, vested);
        assertEq(0, tokenInstance.balanceOf(alice));
    }

    // Test: Token Release after Cliff
    function testReleaseTokensAfterCliff() public {
        uint256 startTime = block.timestamp;

        // Move forward in time
        vm.warp(startTime + cliff + 100 days);

        uint256 vested = vestingContract.releasable();
        // Simulate a claim
        vestingContract.release();

        uint256 amountClaimed = vestingContract.released();
        assertEq(amountClaimed, vested, "Claimed amount should match claimable amount");

        uint256 remainingBalance = tokenInstance.balanceOf(address(vestingContract));

        assertEq(remainingBalance, amount - amountClaimed, "Vested amount should reduce after claim");

        // Check the released amount (depending on how your contract releases tokens)
        assertEq(vested, tokenInstance.balanceOf(alice));
    }

    // Test case: Edge case of claiming after the vesting period
    function testReleaseAfterVestingPeriod() public {
        vm.warp(block.timestamp + 1095 days); // Move beyond the vesting period

        uint256 claimableAmount = vestingContract.releasable();
        uint256 totalVested = amount;

        assertEq(
            claimableAmount,
            totalVested,
            "Claimable amount should be equal to the total vested after the vesting period"
        );
    }

    // Test case: Ensure no double claiming
    function testNoDoubleRelease() public {
        vm.warp(block.timestamp + 700 days);
        vestingContract.release(); // First claim
        uint256 claimAmountAfterFirstClaim = vestingContract.released();
        assertTrue(claimAmountAfterFirstClaim > 0, "Claim should be successful");

        // Trying to claim again should not change anything
        vestingContract.release();
        uint256 claimAmountAfterSecondClaim = vestingContract.released();

        assertEq(claimAmountAfterFirstClaim, claimAmountAfterSecondClaim);
    }

    // Test case: Cancel contract mid flight
    function testCancelContract() public {
        vm.warp(block.timestamp + 700 days);
        uint256 claimableAmount = vestingContract.releasable();
        assertTrue(claimableAmount > 0);
        vm.prank(address(timelockInstance));
        vestingContract.cancelContract();
        assertEq(tokenInstance.balanceOf(alice), claimableAmount);
        assertEq(tokenInstance.balanceOf(address(vestingContract)), 0);
    }

    // Fuzz Test case: Check the claimable amount under various times
    function testFuzzReleasableAmount(uint256 _daysForward) public {
        vm.assume(_daysForward <= 730); // Assume within vesting period
        // Move forward in time
        vm.warp(block.timestamp + cliff + _daysForward * 1 days);
        uint256 claimableAmount = vestingContract.releasable();
        uint256 expectedClaimable = (amount * _daysForward) / 730; // Example of linear vesting

        assertEq(claimableAmount, expectedClaimable, "Claimable amount should be linear based on vesting duration");
    }

    // Fuzz Test: Claim edge cases (before and after vesting period)
    function testFuzzReleaseEdgeCases(uint256 _daysForward) public {
        vm.assume(_daysForward <= 730); // Assume max vesting period is 100 days + some buffer

        if (_daysForward >= 730) {
            // If time has passed, ensure claimable is the total vested
            vm.warp(block.timestamp + cliff + _daysForward * 1 days);
            uint256 claimableAmount = vestingContract.releasable();
            uint256 totalVested = amount;
            assertEq(claimableAmount, totalVested, "Claimable should be equal to total vested after the vesting period");
        } else if (_daysForward >= 1) {
            // Check that claimable amount is progressively increasing over time
            uint256 claimableAmountBefore = vestingContract.releasable();
            vm.warp(block.timestamp + cliff + _daysForward * 1 days);
            uint256 claimableAmountAfter = vestingContract.releasable();
            assertTrue(claimableAmountAfter > claimableAmountBefore, "Claimable amount should increase over time");
        }
    }

    // Fuzz Test: Ensure no claim is possible before vesting starts
    function testFuzzNoReleaseBeforeVesting(uint256 _daysBefore) public {
        vm.assume(_daysBefore <= 365); //cliff
        vm.warp(block.timestamp + _daysBefore * 1 days);

        uint256 claimableBeforeStart = vestingContract.releasable();
        assertEq(claimableBeforeStart, 0, "Claimable amount should be 0 before the vesting period starts");
    }
}
