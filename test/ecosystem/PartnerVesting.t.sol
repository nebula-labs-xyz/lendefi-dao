// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, Vm} from "forge-std/Test.sol";
import {PartnerVesting} from "../../contracts/ecosystem/PartnerVesting.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {IPARTNERVESTING} from "../../contracts/interfaces/IPartnerVesting.sol";

contract PartnerVestingTest is Test {
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
    address timelock = address(0xABCD);
    address partner = address(0x1234);
    address creator = address(this);
    address alice = address(0x5678);

    // Contract instances
    TokenMock token;
    PartnerVesting vesting;

    // Vesting parameters
    uint64 startTime;
    uint64 vestingDuration = 365 days;
    uint256 vestingAmount = 1000 ether;

    function setUp() public {
        // Deploy mock token
        token = new TokenMock("Test Token", "TEST");

        // Set start time to current timestamp
        startTime = uint64(block.timestamp);

        // Deploy vesting contract first without event verification
        vesting = new PartnerVesting(address(token), partner, startTime, vestingDuration);

        // Fund the vesting contract
        token.mint(address(vesting), vestingAmount);

        // Verify initial state
        assertEq(vesting.owner(), partner);

        assertEq(vesting._creator(), address(this));
        assertEq(vesting.start(), startTime);
        assertEq(vesting.duration(), vestingDuration);
        assertEq(vesting.end(), startTime + vestingDuration);
        assertEq(vesting.released(), 0);
        assertEq(token.balanceOf(address(vesting)), vestingAmount);
    }

    // Test basic constructor validations
    // Test basic constructor validations
    function testRevert_ConstructorZeroAddresses() public {
        // Test zero token address
        vm.expectRevert(IPARTNERVESTING.ZeroAddress.selector);
        new PartnerVesting(address(0), partner, startTime, vestingDuration);

        // Test zero partner address (owner)
        // This comes from Ownable, not our custom error
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new PartnerVesting(address(token), address(0), startTime, vestingDuration);
    }

    // Test releasing tokens after vesting begins
    function test_ReleasePartial() public {
        // Warp to 25% through vesting period
        vm.warp(startTime + vestingDuration / 4);

        // Calculate expected amount
        uint256 expectedAmount = vestingAmount / 4; // 25%

        // Release as partner
        vm.prank(partner);
        vm.expectEmit(address(vesting));
        emit ERC20Released(address(token), expectedAmount);
        vesting.release();

        // Verify balances and state
        assertEq(token.balanceOf(partner), expectedAmount);
        assertEq(token.balanceOf(address(vesting)), vestingAmount - expectedAmount);
        assertEq(vesting.released(), expectedAmount);

        // Trying to release again immediately should do nothing
        vm.prank(partner);
        vesting.release();
        assertEq(token.balanceOf(partner), expectedAmount);
        assertEq(vesting.released(), expectedAmount);
    }

    // Test releasing tokens after full vesting
    function test_ReleaseFull() public {
        // Warp to after vesting period
        vm.warp(startTime + vestingDuration + 1 days);

        // Release as partner
        vm.prank(partner);
        vesting.release();

        // Verify all tokens released
        assertEq(token.balanceOf(partner), vestingAmount);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.released(), vestingAmount);
    }

    // Test releasable calculation
    function test_Releasable() public {
        // Initially nothing is releasable
        assertEq(vesting.releasable(), 0);

        // At 50% of vesting period
        vm.warp(startTime + vestingDuration / 2);
        assertEq(vesting.releasable(), vestingAmount / 2);

        // After vesting period
        vm.warp(startTime + vestingDuration + 1);
        assertEq(vesting.releasable(), vestingAmount);

        // After releasing tokens
        vm.prank(partner);
        vesting.release();
        assertEq(vesting.releasable(), 0);
    }

    // Test cancellation by creator
    function test_CancelByCreator() public {
        // Warp to 25% through vesting period
        vm.warp(startTime + vestingDuration / 4);

        // Expected vested amount: 25%
        uint256 vestedAmount = vestingAmount / 4;
        uint256 unvestedAmount = vestingAmount - vestedAmount;

        // Cancel as creator (this contract)
        vm.expectEmit(address(vesting));
        emit Cancelled(unvestedAmount);
        vesting.cancelContract();

        // Verify partner got vested tokens
        assertEq(token.balanceOf(partner), vestedAmount);

        // Verify creator got unvested tokens (not timelock)
        assertEq(token.balanceOf(address(this)), unvestedAmount);
    }

    // Test revert on unauthorized cancellation
    function testRevert_UnauthorizedCancel() public {
        vm.prank(alice);
        vm.expectRevert(IPARTNERVESTING.Unauthorized.selector);
        vesting.cancelContract();

        vm.prank(partner);
        vm.expectRevert(IPARTNERVESTING.Unauthorized.selector);
        vesting.cancelContract();
    }

    // Test ownership transfer
    function test_OwnershipTransfer() public {
        // Start transfer
        vm.prank(partner);
        vm.expectEmit(address(vesting));
        emit OwnershipTransferStarted(partner, alice);
        vesting.transferOwnership(alice);

        // Still owned by partner
        assertEq(vesting.owner(), partner);

        // Accept transfer
        vm.prank(alice);
        vm.expectEmit(address(vesting));
        emit OwnershipTransferred(partner, alice);
        vesting.acceptOwnership();

        // Now owned by alice
        assertEq(vesting.owner(), alice);

        // Alice can release tokens
        vm.warp(startTime + vestingDuration / 2);
        vm.prank(alice);
        vesting.release();
        assertEq(token.balanceOf(alice), vestingAmount / 2);
    }

    // Test timing edge cases
    function test_VestingScheduleTiming() public {
        // Before start - nothing vested
        vm.warp(startTime - 1);
        assertEq(vesting.releasable(), 0);

        // At start - nothing vested
        vm.warp(startTime);
        assertEq(vesting.releasable(), 0);

        // Just after start - tiny amount vested
        vm.warp(startTime + 1);
        uint256 oneSecondAmount = vestingAmount / vestingDuration;
        assertEq(vesting.releasable(), oneSecondAmount);

        // At end - everything vested
        vm.warp(startTime + vestingDuration);
        assertEq(vesting.releasable(), vestingAmount);

        // After end - everything vested
        vm.warp(startTime + vestingDuration + 1000 days);
        assertEq(vesting.releasable(), vestingAmount);
    }

    // Test partial releases
    function test_PartialReleases() public {
        // Release at 25%
        vm.warp(startTime + vestingDuration / 4);
        vm.prank(partner);
        vesting.release();
        assertEq(token.balanceOf(partner), vestingAmount / 4);

        // Release at 50%
        vm.warp(startTime + vestingDuration / 2);
        vm.prank(partner);
        vesting.release();
        assertEq(token.balanceOf(partner), vestingAmount / 2);

        // Release at 75%
        vm.warp(startTime + vestingDuration * 3 / 4);
        vm.prank(partner);
        vesting.release();
        assertEq(token.balanceOf(partner), vestingAmount * 3 / 4);

        // Final release
        vm.warp(startTime + vestingDuration);
        vm.prank(partner);
        vesting.release();
        assertEq(token.balanceOf(partner), vestingAmount);
    }

    // Fuzz Test: Check vested amount at different time points
    function testFuzz_Vesting(uint256 _daysForward) public {
        // Bound days to be reasonable (0 to 2 years)
        _daysForward = bound(_daysForward, 0, 730);

        // Convert days to seconds for vm.warp
        uint256 timeInSeconds = _daysForward * 1 days;
        vm.warp(startTime + timeInSeconds);

        // Calculate expected vested amount (linear vesting)
        uint256 expectedVested;
        if (_daysForward >= vestingDuration / 1 days) {
            // Fully vested
            expectedVested = vestingAmount;
        } else {
            // Linear vesting
            expectedVested = (vestingAmount * _daysForward * 1 days) / vestingDuration;
        }

        assertEq(vesting.releasable(), expectedVested, "Vested amount incorrect");
    }

    // Test for edge cases in release behavior// Test for edge cases in release behavior
    function test_ReleaseEdgeCases() public {
        // Test release when not the owner
        vm.warp(startTime + vestingDuration / 2);

        vm.prank(partner);
        vesting.release();

        // Verify tokens went to partner (the current owner), not alice (the caller)
        assertEq(token.balanceOf(partner), vestingAmount / 2, "Tokens should go to current owner (partner)");
        assertEq(token.balanceOf(alice), 0, "Caller (Alice) should not receive tokens");

        // Test after ownership transfer
        vm.prank(partner);
        vesting.transferOwnership(alice);

        vm.prank(alice);
        vesting.acceptOwnership();

        // Warp further into vesting period to have more tokens vested
        vm.warp(startTime + vestingDuration * 3 / 4);

        // Calculate newly vested tokens (75% - 50% = 25% of total)
        uint256 newlyVested = vestingAmount / 4;

        // Release as alice (now the owner)
        vm.prank(alice);
        vesting.release();

        // Verify new tokens went to alice (new owner)
        assertEq(token.balanceOf(alice), newlyVested, "Newly vested tokens should go to new owner (alice)");
        assertEq(token.balanceOf(partner), vestingAmount / 2, "Previous owner (partner) balance shouldn't change");
    }

    // Test release with zero amount (shouldn't revert but do nothing)
    function test_ReleaseWithZeroAmount() public {
        // Before vesting starts, releasable is 0
        vm.warp(startTime - 1);

        // Get current state
        uint256 beforeReleased = vesting.released();

        // Call release
        vm.prank(partner);
        vesting.release();

        // Verify state didn't change
        assertEq(vesting.released(), beforeReleased, "Released amount should not change");
        assertEq(token.balanceOf(partner), 0, "No tokens should be transferred");
    }

    // Test exact calculation at 1/3 of vesting period
    function test_PreciseVestingCalculation() public {
        // Warp to 1/3 through vesting period (odd fraction to catch rounding errors)
        vm.warp(startTime + vestingDuration / 3);

        // Calculate exact expected amount
        uint256 expectedAmount = (vestingAmount * vestingDuration / 3) / vestingDuration;

        // Check releasable
        assertEq(vesting.releasable(), expectedAmount, "Releasable calculation incorrect at 1/3 vesting");

        // Release and verify
        vm.prank(partner);
        vesting.release();

        assertEq(token.balanceOf(partner), expectedAmount, "Released amount incorrect at 1/3 vesting");
    }

    // Test status after initialization and pre-funding
    function test_InitialStateBeforeFunding() public {
        // Deploy a new vesting contract without funding
        PartnerVesting newVesting = new PartnerVesting(address(token), partner, startTime, vestingDuration);

        // Check state
        assertEq(newVesting.releasable(), 0, "Releasable should be 0 without funding");
        assertEq(newVesting.released(), 0, "Released should be 0 initially");

        // Even after vesting period passes, nothing should be releasable without funding
        vm.warp(startTime + vestingDuration + 1 days);
        assertEq(newVesting.releasable(), 0, "Releasable should be 0 without funding even after vesting period");
    }

    // Test for edge cases with zero duration or very large durations
    function test_VestingWithSpecialDurations() public {
        // Test with 1 day duration (very short)
        uint64 shortDuration = 1 days;
        PartnerVesting shortVesting = new PartnerVesting(address(token), partner, startTime, shortDuration);

        // Fund it
        token.mint(address(shortVesting), vestingAmount);

        // Warp to after vesting
        vm.warp(startTime + 2 days);

        // Should be fully vested
        assertEq(shortVesting.releasable(), vestingAmount, "Short duration should vest fully");

        // Test with very long duration
        uint64 longDuration = 10 * 365 days; // 10 years
        PartnerVesting longVesting = new PartnerVesting(address(token), partner, startTime, longDuration);

        // Fund it
        token.mint(address(longVesting), vestingAmount);

        // Warp to 1 year
        vm.warp(startTime + 365 days);

        // Should be ~10% vested
        uint256 expectedVested = vestingAmount / 10;
        uint256 actualVested = longVesting.releasable();

        // Allow small rounding error (1 wei)
        assertApproxEqAbs(actualVested, expectedVested, 1, "Long duration should vest proportionally");
    }

    // Test that timelock can't cancel directly anymore
    function testRevert_TimelockCannotCancel() public {
        // Attempt to cancel as timelock (should fail)
        vm.prank(timelock);
        vm.expectRevert(IPARTNERVESTING.Unauthorized.selector);
        vesting.cancelContract();
    }

    // Test cancellation after full vesting
    function test_CancelAfterFullVesting() public {
        // Warp to after vesting period
        vm.warp(startTime + vestingDuration + 1 days);

        // Cancel as creator (not timelock)
        vesting.cancelContract();

        // Verify partner got all tokens
        assertEq(token.balanceOf(partner), vestingAmount);

        // Verify creator got nothing
        assertEq(token.balanceOf(address(this)), 0);

        // Verify contract has no remaining tokens
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    // Test cancellation before any vesting
    function test_CancelBeforeVesting() public {
        // Cancel as creator before vesting starts
        vm.warp(startTime - 1);

        vesting.cancelContract(); // No need to prank since test contract is creator

        // Verify partner got nothing
        assertEq(token.balanceOf(partner), 0);

        // Verify creator got everything
        assertEq(token.balanceOf(address(this)), vestingAmount);
    }

    // Test double cancel scenario
    function test_DoubleCancel() public {
        // First cancel returns unvested tokens to creator
        vesting.cancelContract();

        // Second cancel should complete without any token movement
        uint256 creatorBalanceBefore = token.balanceOf(address(this));
        uint256 partnerBalanceBefore = token.balanceOf(partner);

        vesting.cancelContract();

        assertEq(
            token.balanceOf(address(this)), creatorBalanceBefore, "Creator balance shouldn't change on second cancel"
        );
        assertEq(token.balanceOf(partner), partnerBalanceBefore, "Partner balance shouldn't change on second cancel");
    }

    // Test cancellation at specific time points
    function test_CancelAtSpecificTimePoints() public {
        // Test at exact start
        vm.warp(startTime);

        vesting.cancelContract(); // No need to prank

        assertEq(token.balanceOf(partner), 0, "Partner should get nothing at start");
        assertEq(token.balanceOf(address(this)), vestingAmount, "Creator should get everything at start");

        // Reset for next test
        setUp();

        // Test at exactly 1 second after start
        vm.warp(startTime + 1);

        // Calculate expected tiny vested amount for 1 second
        uint256 tinyVestedAmount = (vestingAmount * 1) / vestingDuration;

        vesting.cancelContract(); // No need to prank

        assertEq(token.balanceOf(partner), tinyVestedAmount, "Partner should get tiny amount at start+1");
        assertEq(
            token.balanceOf(address(this)), vestingAmount - tinyVestedAmount, "Creator should get remainder at start+1"
        );
    }

    // Test cancellation with direct emission verification
    function test_CancelEmitsEvent() public {
        // Warp to 25% through vesting period
        vm.warp(startTime + vestingDuration / 4);

        // Expected unvested amount: 75%
        uint256 unvestedAmount = vestingAmount * 3 / 4;

        // Record logs to verify event emission
        vm.recordLogs();

        // Cancel as creator
        vesting.cancelContract(); // No need to prank

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

    // Test cancellation during pending ownership transfer
    function testCancelWithPendingOwnershipTransfer() public {
        // Warp to 25% through vesting period
        vm.warp(startTime + vestingDuration / 4);

        // Calculate expected amounts
        uint256 vestedAmount = vestingAmount / 4; // 25%
        uint256 unvestedAmount = vestingAmount - vestedAmount;

        // Partner initiates ownership transfer to alice
        vm.prank(partner);
        vm.expectEmit(address(vesting));
        emit OwnershipTransferStarted(partner, alice);
        vesting.transferOwnership(alice);

        // Verify ownership is still with partner
        assertEq(vesting.owner(), partner);

        // Cancel contract as creator
        vm.expectEmit(address(vesting));
        emit Cancelled(unvestedAmount);
        vesting.cancelContract();

        // Verify partner (still the owner) got vested tokens
        assertEq(token.balanceOf(partner), vestedAmount);

        // Verify creator got unvested tokens
        assertEq(token.balanceOf(address(this)), unvestedAmount);

        // Alice should still be able to accept ownership (Ownable2Step functionality)
        vm.prank(alice);
        vm.expectEmit(address(vesting));
        emit OwnershipTransferred(partner, alice);
        vesting.acceptOwnership();

        // Verify Alice is now owner
        assertEq(vesting.owner(), alice);

        // Contract should now be empty - verify balances remain unchanged
        // (No need to call release() since all tokens were already distributed during cancellation)
        assertEq(token.balanceOf(partner), vestedAmount, "Partner balance should remain unchanged");
        assertEq(token.balanceOf(alice), 0, "Alice should not receive any tokens as the contract is empty");
        assertEq(token.balanceOf(address(this)), unvestedAmount, "Creator balance should remain unchanged");
        assertEq(token.balanceOf(address(vesting)), 0, "Vesting contract should be empty");
    }
}
