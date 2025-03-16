// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, Vm} from "forge-std/Test.sol";
import {TeamVesting} from "../../contracts/ecosystem/TeamVesting.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {ITEAMVESTING} from "../../contracts/interfaces/ITeamVesting.sol";
import "../BasicDeploy.sol";

contract TeamVestingTest is Test {
    // Events
    event VestingInitialized(
        address indexed token,
        address indexed beneficiary,
        address indexed timelock,
        uint64 startTimestamp,
        uint64 duration
    );
    event ERC20Released(address indexed token, uint256 amount);
    event Cancelled(uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    // Test accounts
    address timelock;
    address teamMember;
    address alice = address(0x5678);
    address bob = address(0x8765);

    // Contract instances
    TokenMock tokenInstance;
    TeamVesting vestingContract;

    // Vesting parameters
    uint64 startTimestamp;
    uint64 VESTING_DURATION = 365 days;
    uint64 CLIFF_PERIOD = 90 days;
    uint256 VESTING_AMOUNT = 1_000_000e18;

    function setUp() public {
        // Deploy mock token
        tokenInstance = new TokenMock("Ecosystem Token", "ECO");

        // Setup test addresses
        timelock = address(0xABCD);
        teamMember = address(0x1234);

        // Set start time to current timestamp
        startTimestamp = uint64(block.timestamp);

        // Deploy vesting contract
        vestingContract =
            new TeamVesting(address(tokenInstance), timelock, teamMember, startTimestamp, VESTING_DURATION);

        // Fund the vesting contract
        tokenInstance.mint(address(vestingContract), VESTING_AMOUNT);

        // Verify initial state
        assertEq(vestingContract.owner(), teamMember, "Owner should be team member");
        assertEq(vestingContract._timelock(), timelock, "Timelock address incorrect");
        assertEq(vestingContract.start(), startTimestamp, "Start timestamp incorrect");
        assertEq(vestingContract.duration(), VESTING_DURATION, "Duration incorrect");
        assertEq(vestingContract.end(), startTimestamp + VESTING_DURATION, "End timestamp incorrect");
        assertEq(vestingContract.released(), 0, "Released amount should be zero initially");
        assertEq(tokenInstance.balanceOf(address(vestingContract)), VESTING_AMOUNT, "Contract should have tokens");
    }

    // Test constructor validations
    function testRevertConstructorZeroAddresses() public {
        // Test zero token address
        vm.expectRevert(ITEAMVESTING.ZeroAddress.selector);
        new TeamVesting(address(0), timelock, teamMember, startTimestamp, VESTING_DURATION);

        // Test zero timelock address
        vm.expectRevert(ITEAMVESTING.ZeroAddress.selector);
        new TeamVesting(address(tokenInstance), address(0), teamMember, startTimestamp, VESTING_DURATION);

        // Test zero beneficiary address (owner)
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new TeamVesting(address(tokenInstance), timelock, address(0), startTimestamp, VESTING_DURATION);
    }

    // Test constructor event emission
    function testConstructorEvents() public {
        // Create a new contract and expect the event
        vm.expectEmit(true, true, true, true);
        emit VestingInitialized(address(tokenInstance), teamMember, timelock, startTimestamp, VESTING_DURATION);
        new TeamVesting(address(tokenInstance), timelock, teamMember, startTimestamp, VESTING_DURATION);
    }

    // Test releasing tokens after vesting begins
    function testReleasePartial() public {
        // Warp to 25% through vesting period
        vm.warp(startTimestamp + VESTING_DURATION / 4);

        // Calculate expected amount
        uint256 expectedAmount = VESTING_AMOUNT / 4; // 25%

        // Release as team member
        vm.prank(teamMember);
        vm.expectEmit(address(vestingContract));
        emit ERC20Released(address(tokenInstance), expectedAmount);
        vestingContract.release();

        // Verify balances and state
        assertEq(tokenInstance.balanceOf(teamMember), expectedAmount, "Team member should receive vested tokens");
        assertEq(
            tokenInstance.balanceOf(address(vestingContract)),
            VESTING_AMOUNT - expectedAmount,
            "Contract balance incorrect"
        );
        assertEq(vestingContract.released(), expectedAmount, "Released amount incorrect");

        // Trying to release again immediately should do nothing
        vm.prank(teamMember);
        vestingContract.release();
        assertEq(tokenInstance.balanceOf(teamMember), expectedAmount, "No additional tokens should be released");
        assertEq(vestingContract.released(), expectedAmount, "Released amount shouldn't change");
    }

    // Test releasing tokens after full vesting
    function testReleaseFull() public {
        // Warp to after vesting period
        vm.warp(startTimestamp + VESTING_DURATION + 1 days);

        // Release as team member
        vm.prank(teamMember);
        vestingContract.release();

        // Verify all tokens released
        assertEq(tokenInstance.balanceOf(teamMember), VESTING_AMOUNT, "All tokens should be released");
        assertEq(tokenInstance.balanceOf(address(vestingContract)), 0, "Contract should have no tokens left");
        assertEq(vestingContract.released(), VESTING_AMOUNT, "Released amount should match total");
    }

    // Test releasable calculation
    function testReleasable() public {
        // Initially nothing is releasable
        assertEq(vestingContract.releasable(), 0, "Nothing should be releasable at start");

        // At 50% of vesting period
        vm.warp(startTimestamp + VESTING_DURATION / 2);
        assertEq(vestingContract.releasable(), VESTING_AMOUNT / 2, "50% should be releasable at midpoint");

        // After vesting period
        vm.warp(startTimestamp + VESTING_DURATION + 1);
        assertEq(vestingContract.releasable(), VESTING_AMOUNT, "Everything should be releasable after end");

        // After releasing tokens
        vm.prank(teamMember);
        vestingContract.release();
        assertEq(vestingContract.releasable(), 0, "Nothing releasable after full release");
    }

    // Test cancellation by timelock
    function testCancelByTimelock() public {
        // Warp to 25% through vesting period
        vm.warp(startTimestamp + VESTING_DURATION / 4);

        // Expected vested amount: 25%
        uint256 vestedAmount = VESTING_AMOUNT / 4;
        uint256 unvestedAmount = VESTING_AMOUNT - vestedAmount;

        // Cancel as timelock
        vm.prank(timelock);
        vm.expectEmit(address(vestingContract));
        emit Cancelled(unvestedAmount);
        vestingContract.cancelContract();

        // Verify team member got vested tokens
        assertEq(tokenInstance.balanceOf(teamMember), vestedAmount, "Team member should get vested tokens");

        // Verify timelock got unvested tokens
        assertEq(tokenInstance.balanceOf(timelock), unvestedAmount, "Timelock should get unvested tokens");

        // Verify contract has no tokens left
        assertEq(tokenInstance.balanceOf(address(vestingContract)), 0, "Contract should have no tokens left");
    }

    // Test revert on unauthorized cancellation
    function testRevertUnauthorizedCancel() public {
        vm.prank(alice);
        vm.expectRevert(ITEAMVESTING.Unauthorized.selector);
        vestingContract.cancelContract();

        vm.prank(teamMember);
        vm.expectRevert(ITEAMVESTING.Unauthorized.selector);
        vestingContract.cancelContract();
    }

    // Test ownership transfer
    function testOwnershipTransfer() public {
        // Start transfer
        vm.prank(teamMember);
        vm.expectEmit(address(vestingContract));
        emit OwnershipTransferStarted(teamMember, alice);
        vestingContract.transferOwnership(alice);

        // Still owned by team member
        assertEq(vestingContract.owner(), teamMember, "Owner shouldn't change until accepted");

        // Accept transfer
        vm.prank(alice);
        vm.expectEmit(address(vestingContract));
        emit OwnershipTransferred(teamMember, alice);
        vestingContract.acceptOwnership();

        // Now owned by alice
        assertEq(vestingContract.owner(), alice, "Alice should be the new owner");

        // Alice can release tokens that go to her (new behavior)
        vm.warp(startTimestamp + VESTING_DURATION / 2);
        vm.prank(alice);
        vestingContract.release();
        assertEq(tokenInstance.balanceOf(alice), VESTING_AMOUNT / 2, "Tokens should go to the new owner");
    }

    // Test release after ownership transfer (critical test for TeamVesting)
    function testReleaseAfterOwnershipTransfer() public {
        // Make sure we're past the cliff first
        vm.warp(startTimestamp + VESTING_DURATION / 4);

        // Transfer ownership
        vm.prank(teamMember);
        vestingContract.transferOwnership(alice);

        vm.prank(alice);
        vestingContract.acceptOwnership();

        // Verify owner changed
        assertEq(vestingContract.owner(), alice, "Alice should be the new owner");

        // Warp to 50% through vesting period
        vm.warp(startTimestamp + VESTING_DURATION / 2);

        // Calculate expected amount (50% of total vesting amount)
        uint256 expectedAmount = VESTING_AMOUNT / 2;

        // Release as new owner
        vm.prank(alice);
        vestingContract.release();

        // Important: In TeamVesting, tokens go to the current owner, not original beneficiary
        assertEq(tokenInstance.balanceOf(alice), expectedAmount, "Tokens should go to new owner");
        assertEq(tokenInstance.balanceOf(teamMember), 0, "Original beneficiary should not receive tokens");
    }

    // Test timing edge cases
    function testVestingScheduleTiming() public {
        // Before start - nothing vested
        vm.warp(startTimestamp - 1);
        assertEq(vestingContract.releasable(), 0, "Nothing should be vested before start");

        // At start - nothing vested
        vm.warp(startTimestamp);
        assertEq(vestingContract.releasable(), 0, "Nothing should be vested at start");

        // Just after start - tiny amount vested
        vm.warp(startTimestamp + 1);
        uint256 oneSecondAmount = VESTING_AMOUNT / VESTING_DURATION;
        assertEq(vestingContract.releasable(), oneSecondAmount, "Tiny amount should be vested after one second");

        // At end - everything vested
        vm.warp(startTimestamp + VESTING_DURATION);
        assertEq(vestingContract.releasable(), VESTING_AMOUNT, "Everything should be vested at end");

        // After end - everything vested
        vm.warp(startTimestamp + VESTING_DURATION + 1000 days);
        assertEq(vestingContract.releasable(), VESTING_AMOUNT, "Everything should remain vested after end");
    }

    // Test partial releases
    function testPartialReleases() public {
        // Release at 25%
        vm.warp(startTimestamp + VESTING_DURATION / 4);
        vm.prank(teamMember);
        vestingContract.release();
        assertEq(tokenInstance.balanceOf(teamMember), VESTING_AMOUNT / 4, "Should receive 25% at quarter point");

        // Release at 50%
        vm.warp(startTimestamp + VESTING_DURATION / 2);
        vm.prank(teamMember);
        vestingContract.release();
        assertEq(tokenInstance.balanceOf(teamMember), VESTING_AMOUNT / 2, "Should receive 50% at midpoint");

        // Release at 75%
        vm.warp(startTimestamp + VESTING_DURATION * 3 / 4);
        vm.prank(teamMember);
        vestingContract.release();
        assertEq(tokenInstance.balanceOf(teamMember), VESTING_AMOUNT * 3 / 4, "Should receive 75% at third quarter");

        // Final release
        vm.warp(startTimestamp + VESTING_DURATION);
        vm.prank(teamMember);
        vestingContract.release();
        assertEq(tokenInstance.balanceOf(teamMember), VESTING_AMOUNT, "Should receive 100% at end");
    }

    // Fuzz Test: Check vested amount at different time points
    function testFuzzVesting(uint256 _daysForward) public {
        // Bound days to be reasonable (0 to 2 years)
        _daysForward = bound(_daysForward, 0, 730);

        // Convert days to seconds for vm.warp
        uint256 timeInSeconds = _daysForward * 1 days;
        vm.warp(startTimestamp + timeInSeconds);

        // Calculate expected vested amount (linear vesting)
        uint256 expectedVested;
        if (_daysForward >= VESTING_DURATION / 1 days) {
            // Fully vested
            expectedVested = VESTING_AMOUNT;
        } else {
            // Linear vesting
            expectedVested = (VESTING_AMOUNT * timeInSeconds) / VESTING_DURATION;
        }

        assertEq(vestingContract.releasable(), expectedVested, "Vested amount calculation incorrect");
    }

    // Test precise calculation at 1/3 of vesting period
    function testPreciseVestingCalculation() public {
        // Warp to 1/3 through vesting period (odd fraction to catch rounding errors)
        vm.warp(startTimestamp + VESTING_DURATION / 3);

        // Calculate exact expected amount
        uint256 expectedAmount = (VESTING_AMOUNT * (VESTING_DURATION / 3)) / VESTING_DURATION;

        // Check releasable
        assertEq(vestingContract.releasable(), expectedAmount, "Releasable calculation incorrect at 1/3 vesting");

        // Release and verify
        vm.prank(teamMember);
        vestingContract.release();

        assertEq(tokenInstance.balanceOf(teamMember), expectedAmount, "Released amount incorrect at 1/3 vesting");
    }

    // Test status after initialization and pre-funding
    function testInitialStateBeforeFunding() public {
        // Deploy a new vesting contract without funding
        TeamVesting newVesting =
            new TeamVesting(address(tokenInstance), timelock, teamMember, startTimestamp, VESTING_DURATION);

        // Check state
        assertEq(newVesting.releasable(), 0, "Releasable should be 0 without funding");
        assertEq(newVesting.released(), 0, "Released should be 0 initially");

        // Even after vesting period passes, nothing should be releasable without funding
        vm.warp(startTimestamp + VESTING_DURATION + 1 days);
        assertEq(newVesting.releasable(), 0, "Releasable should be 0 without funding even after vesting period");
    }

    // Test for edge cases with zero duration or very large durations
    function testVestingWithShortDuration() public {
        // Create a new vesting contract with very short duration
        uint64 shortDuration = 1 days;

        TeamVesting shortVesting =
            new TeamVesting(address(tokenInstance), timelock, teamMember, uint64(block.timestamp), shortDuration);

        // Fund it
        tokenInstance.mint(address(shortVesting), VESTING_AMOUNT);

        // Warp to after vesting
        vm.warp(block.timestamp + shortDuration + 1 hours);

        // Check full vesting
        assertEq(shortVesting.releasable(), VESTING_AMOUNT, "Short duration should vest fully");

        // Release tokens and verify
        vm.prank(teamMember);
        shortVesting.release();
        assertEq(tokenInstance.balanceOf(teamMember), VESTING_AMOUNT, "All tokens should be released");
    }

    // Test cancellation after full vesting
    function testCancelAfterFullVesting() public {
        // Warp to after vesting period
        vm.warp(startTimestamp + VESTING_DURATION + 1 days);

        // Cancel as timelock
        vm.prank(timelock);
        vestingContract.cancelContract();

        // Verify team member got all tokens
        assertEq(
            tokenInstance.balanceOf(teamMember), VESTING_AMOUNT, "Team member should get all tokens when fully vested"
        );

        // Verify timelock got nothing
        assertEq(tokenInstance.balanceOf(timelock), 0, "Timelock should get nothing when fully vested");

        // Verify contract has no remaining tokens
        assertEq(tokenInstance.balanceOf(address(vestingContract)), 0, "Contract should have no tokens left");
    }

    // Test cancellation before any vesting
    function testCancelBeforeVesting() public {
        // Cancel before vesting starts
        vm.warp(startTimestamp - 1);

        vm.prank(timelock);
        vestingContract.cancelContract();

        // Verify team member got nothing
        assertEq(tokenInstance.balanceOf(teamMember), 0, "Team member should get nothing before vesting starts");

        // Verify timelock got everything
        assertEq(
            tokenInstance.balanceOf(timelock), VESTING_AMOUNT, "Timelock should get all tokens before vesting starts"
        );
    }

    // Test double cancel scenario
    function testDoubleCancel() public {
        // First cancel returns unvested tokens to timelock
        vm.prank(timelock);
        vestingContract.cancelContract();

        // Second cancel should complete without any token movement
        uint256 timelockBalanceBefore = tokenInstance.balanceOf(timelock);
        uint256 teamMemberBalanceBefore = tokenInstance.balanceOf(teamMember);

        vm.prank(timelock);
        vestingContract.cancelContract();

        assertEq(
            tokenInstance.balanceOf(timelock),
            timelockBalanceBefore,
            "Timelock balance shouldn't change on second cancel"
        );
        assertEq(
            tokenInstance.balanceOf(teamMember),
            teamMemberBalanceBefore,
            "Team member balance shouldn't change on second cancel"
        );
    }

    // Test cancellation at specific time points
    function testCancelAtSpecificTimePoints() public {
        // Test at exact start time
        vm.warp(startTimestamp);

        vm.prank(timelock);
        vestingContract.cancelContract();

        assertEq(tokenInstance.balanceOf(teamMember), 0, "Team member should get nothing at start");
        assertEq(tokenInstance.balanceOf(timelock), VESTING_AMOUNT, "Timelock should get everything at start");

        // Reset for next test
        setUp();

        // Test at exactly 1 second after start
        vm.warp(startTimestamp + 1);

        // Calculate expected tiny vested amount for 1 second
        uint256 tinyVestedAmount = (VESTING_AMOUNT * 1) / VESTING_DURATION;

        vm.prank(timelock);
        vestingContract.cancelContract();

        assertApproxEqAbs(
            tokenInstance.balanceOf(teamMember), tinyVestedAmount, 1, "Team member should get tiny amount at start+1"
        );
        assertApproxEqAbs(
            tokenInstance.balanceOf(timelock),
            VESTING_AMOUNT - tinyVestedAmount,
            1,
            "Timelock should get remainder at start+1"
        );
    }

    // Test cancellation with direct emission verification
    function testCancelEmitsEventRecordedLogs() public {
        // Warp to 25% through vesting period
        vm.warp(startTimestamp + VESTING_DURATION / 4);

        // Expected unvested amount: 75%
        uint256 vestedAmount = VESTING_AMOUNT / 4;
        uint256 unvestedAmount = VESTING_AMOUNT - vestedAmount;

        // Record logs to verify event emission
        vm.recordLogs();

        // Cancel as timelock
        vm.prank(timelock);
        vestingContract.cancelContract();

        // Get the emitted logs
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Find and verify the Cancelled event
        bool foundEvent = false;
        for (uint256 i = 0; i < entries.length; i++) {
            // The event signature for Cancelled
            if (entries[i].topics[0] == keccak256("Cancelled(uint256)")) {
                // Decode the data
                uint256 emittedAmount = abi.decode(entries[i].data, (uint256));
                assertEq(emittedAmount, unvestedAmount, "Emitted amount incorrect");
                foundEvent = true;
                break;
            }
        }

        assertTrue(foundEvent, "Cancelled event not emitted");
    }

    // Test calling release multiple times in same block
    function testCallingReleaseMultipleTimesInSameBlock() public {
        // Warp to middle of vesting period
        vm.warp(startTimestamp + VESTING_DURATION / 2);

        // First release should work
        uint256 releasableAmount = vestingContract.releasable();
        vm.prank(teamMember);
        vestingContract.release();

        // Second release in same block should do nothing
        vm.prank(teamMember);
        vestingContract.release();

        // Verify token balance matches only one release
        assertEq(tokenInstance.balanceOf(teamMember), releasableAmount);
    }
}
