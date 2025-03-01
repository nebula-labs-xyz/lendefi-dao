// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
import {TeamVesting} from "../../contracts/ecosystem/TeamVesting.sol";

contract TeamVestingTest is BasicDeploy {
    // Constants
    uint64 public constant CLIFF_PERIOD = 365 days;
    uint64 public constant VESTING_DURATION = 730 days;
    uint256 public constant VESTING_AMOUNT = 200_000 ether;
    // State variables
    uint64 public startTimestamp;
    TeamVesting internal vestingContract;

    // Events
    event ERC20Released(address indexed token, uint256 amount);
    event VestingInitialized(
        address indexed token,
        address indexed beneficiary,
        address indexed timelock,
        uint64 startTimestamp,
        uint64 duration
    );
    event AddPartner(address account, address vesting, uint256 amount);
    event Cancelled(uint256 amount);

    function setUp() public {
        // Deploy base contracts
        deployComplete();
        startTimestamp = uint64(block.timestamp);

        // Initialize token distribution
        _initializeTokenDistribution();

        // Deploy and fund vesting contract
        _deployAndFundVesting();
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testDeploy() public {
        // Test successful deployment
        TeamVesting vesting =
            new TeamVesting(address(tokenInstance), address(0x2), address(0x3), startTimestamp, VESTING_DURATION);

        // Verify initial state
        assertEq(vesting.owner(), address(0x3));
        assertEq(vesting._timelock(), address(0x2));
        assertEq(vesting.start(), startTimestamp);
        assertEq(vesting.duration(), VESTING_DURATION);

        // Test zero address validations
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new TeamVesting(address(0), address(0x2), address(0x3), startTimestamp, VESTING_DURATION);

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new TeamVesting(address(tokenInstance), address(0), address(0x3), startTimestamp, VESTING_DURATION);

        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new TeamVesting(address(tokenInstance), address(0x2), address(0), startTimestamp, VESTING_DURATION);
    }

    /*//////////////////////////////////////////////////////////////
                            VESTING TESTS
    //////////////////////////////////////////////////////////////*/

    function testVestingBeforeCliff() public {
        uint256 initialBalance = tokenInstance.balanceOf(address(vestingContract));

        vm.warp(vestingContract.start() - 1);
        vm.prank(alice);
        vestingContract.release();

        assertEq(vestingContract.releasable(), 0);
        assertEq(tokenInstance.balanceOf(alice), 0);
        assertEq(vestingContract.released(), 0);
        assertEq(tokenInstance.balanceOf(address(vestingContract)), initialBalance);
    }

    function testVestingAfterCliff() public {
        vm.warp(block.timestamp + CLIFF_PERIOD + 100 days);

        uint256 expectedVested = vestingContract.releasable();
        vestingContract.release();

        assertEq(vestingContract.released(), expectedVested);
        assertEq(tokenInstance.balanceOf(alice), expectedVested);
        assertEq(tokenInstance.balanceOf(address(vestingContract)), VESTING_AMOUNT - expectedVested);
    }

    function testFullyVested() public {
        vm.warp(block.timestamp + CLIFF_PERIOD + VESTING_DURATION);

        assertEq(vestingContract.releasable(), VESTING_AMOUNT);

        vestingContract.release();

        assertEq(tokenInstance.balanceOf(alice), VESTING_AMOUNT);
        assertEq(tokenInstance.balanceOf(address(vestingContract)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function testOwnershipTransfer() public {
        vm.prank(alice);
        vestingContract.transferOwnership(bob);

        assertEq(vestingContract.pendingOwner(), bob);
        assertEq(vestingContract.owner(), alice);

        vm.prank(bob);
        vestingContract.acceptOwnership();

        assertEq(vestingContract.owner(), bob);
        assertEq(vestingContract.pendingOwner(), address(0));
    }

    function testUnauthorizedOwnershipTransfer() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        vestingContract.transferOwnership(bob);
    }

    //Test: TransferOwnership
    function testTransferOwnership() public {
        vm.prank(alice);
        vestingContract.transferOwnership(bob);

        // Check pending owner is set
        assertEq(vestingContract.pendingOwner(), bob);
        // Check current owner hasn't changed
        assertEq(vestingContract.owner(), alice);
    }

    //Test: TransferOwnershipUnauthorized
    function testTransferOwnershipUnauthorized() public {
        // Try to transfer ownership from non-owner account
        vm.prank(address(0x9999));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x9999)));
        vestingContract.transferOwnership(bob);
    }

    // Test: AcceptOwnership
    function testAcceptOwnership() public {
        // Set up pending ownership transfer
        vm.prank(alice);
        vestingContract.transferOwnership(bob);

        // Accept ownership as new owner
        vm.prank(bob);
        vestingContract.acceptOwnership();

        // Verify ownership changed
        assertEq(vestingContract.owner(), bob);
        assertEq(vestingContract.pendingOwner(), address(0));
    }

    //Test: AcceptOwnershipUnauthorized
    function testAcceptOwnershipUnauthorized() public {
        // Set up pending ownership transfer
        vm.prank(alice);
        vestingContract.transferOwnership(bob);

        // Try to accept ownership from unauthorized account
        address unauthorized = address(0x9999);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", unauthorized));
        vestingContract.acceptOwnership();
    }

    // Test: CancelTransferOwnership
    function testCancelTransferOwnership() public {
        // Set up pending ownership transfer
        vm.prank(alice);
        vestingContract.transferOwnership(bob);

        // Cancel transfer by setting pending owner to zero address
        vm.prank(alice);
        vestingContract.transferOwnership(address(0));

        // Verify pending owner is cleared
        assertEq(vestingContract.pendingOwner(), address(0));
        // Verify current owner hasn't changed
        assertEq(vestingContract.owner(), alice);
    }

    // Test: Ownership Transfer
    function testOwnershipTransferTwo() public {
        // Transfer ownership to a new address
        address newOwner = address(0x123);
        vm.prank(alice);
        vestingContract.transferOwnership(newOwner);

        // Verify the new owner
        vm.prank(newOwner);
        vestingContract.acceptOwnership();
        assertEq(vestingContract.owner(), newOwner);

        // Attempt unauthorized ownership transfer and expect a revert
        vm.startPrank(address(0x9999991));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x9999991)));
        vestingContract.transferOwnership(alice);
        vm.stopPrank();
    }

    // Test: Ownership Renouncement
    function testOwnershipRenouncement() public {
        // Renounce ownership
        vm.prank(alice);
        vestingContract.renounceOwnership();

        // Verify that the owner is set to the zero address
        assertEq(vestingContract.owner(), address(0));

        // Attempt unauthorized ownership renouncement and expect a revert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vestingContract.renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                        CANCELLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCancelContractBeforeCliff() public {
        // Try to cancel before cliff
        vm.prank(address(timelockInstance));
        vestingContract.cancelContract();

        // Nothing should be released to beneficiary
        assertEq(tokenInstance.balanceOf(alice), 0);
        // All tokens should be returned to timelock
        assertEq(tokenInstance.balanceOf(address(timelockInstance)), VESTING_AMOUNT);
    }

    function testCancelContractAfterCliff() public {
        // Warp to after cliff but before full vesting
        vm.warp(block.timestamp + CLIFF_PERIOD + 100 days);

        // Calculate expected vested amount
        uint256 expectedVested = vestingContract.releasable();

        vm.prank(address(timelockInstance));
        vestingContract.cancelContract();

        // Check vested tokens sent to beneficiary
        assertEq(tokenInstance.balanceOf(alice), expectedVested);
        // Check remaining tokens returned to timelock
        assertEq(tokenInstance.balanceOf(address(timelockInstance)), VESTING_AMOUNT - expectedVested);
    }

    function testCancelContractAfterFullVesting() public {
        // Warp to after full vesting
        vm.warp(block.timestamp + CLIFF_PERIOD + VESTING_DURATION);

        vm.prank(address(timelockInstance));
        vestingContract.cancelContract();

        // All tokens should go to beneficiary
        assertEq(tokenInstance.balanceOf(alice), VESTING_AMOUNT);
        // No tokens should be returned to timelock
        assertEq(tokenInstance.balanceOf(address(timelockInstance)), 0);
    }

    function testUnauthorizedCancel() public {
        // Try to cancel from unauthorized address
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vestingContract.cancelContract();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vestingContract.cancelContract();
    }

    function testCancelEmitsEvent() public {
        vm.prank(address(timelockInstance));

        // Expect Cancelled event with remaining balance
        vm.expectEmit(false, false, false, true);
        emit Cancelled(VESTING_AMOUNT);

        vestingContract.cancelContract();
    }

    function testCancelMidVesting() public {
        vm.warp(block.timestamp + VESTING_DURATION / 2);
        uint256 vested = vestingContract.releasable();

        vm.prank(address(timelockInstance));
        vm.expectEmit(true, true, true, true);
        emit Cancelled(VESTING_AMOUNT - vested);
        vestingContract.cancelContract();

        assertEq(tokenInstance.balanceOf(alice), vested);
        assertEq(tokenInstance.balanceOf(address(timelockInstance)), VESTING_AMOUNT - vested);
        assertEq(tokenInstance.balanceOf(address(vestingContract)), 0);
    }

    function testDoubleCancel() public {
        // First cancel
        vm.prank(address(timelockInstance));
        vestingContract.cancelContract();

        // Second cancel should emit event with 0 amount
        vm.prank(address(timelockInstance));
        vestingContract.cancelContract();
    }

    function testCancelContract() public {
        vm.warp(block.timestamp + CLIFF_PERIOD + 100 days);
        uint256 claimable = vestingContract.releasable();

        vm.prank(address(timelockInstance));
        vestingContract.cancelContract();

        assertEq(tokenInstance.balanceOf(alice), claimable);
        assertEq(tokenInstance.balanceOf(address(vestingContract)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION EVENTS TESTS
    //////////////////////////////////////////////////////////////*/

    function testInitializationEvents() public {
        // Deploy a new vesting contract and check initialization event
        vm.expectEmit(true, true, true, true);
        emit VestingInitialized(address(tokenInstance), address(0x3), address(0x2), startTimestamp, VESTING_DURATION);

        new TeamVesting(address(tokenInstance), address(0x2), address(0x3), startTimestamp, VESTING_DURATION);
    }

    /*//////////////////////////////////////////////////////////////
                            RELEASABLE TESTS
    //////////////////////////////////////////////////////////////*/

    function testReleasableAmount() public {
        // Test releasable before start
        assertEq(vestingContract.releasable(), 0, "Should be 0 before start");

        // Test releasable at start
        vm.warp(vestingContract.start());
        assertEq(vestingContract.releasable(), 0, "Should be 0 at start");

        // Test releasable at 25% vesting
        vm.warp(vestingContract.start() + VESTING_DURATION / 4);
        assertEq(vestingContract.releasable(), VESTING_AMOUNT / 4, "Should be 25% of total amount");

        // Test releasable at 50% vesting
        vm.warp(vestingContract.start() + VESTING_DURATION / 2);
        assertEq(vestingContract.releasable(), VESTING_AMOUNT / 2, "Should be 50% of total amount");

        // Test releasable at full vesting
        vm.warp(vestingContract.start() + VESTING_DURATION);
        assertEq(vestingContract.releasable(), VESTING_AMOUNT, "Should be 100% of total amount");

        // Test releasable after full vesting
        vm.warp(vestingContract.start() + VESTING_DURATION + 1 days);
        assertEq(vestingContract.releasable(), VESTING_AMOUNT, "Should remain at 100% after vesting period");
    }

    function testReleasableAfterPartialRelease() public {
        // Warp to 50% vesting
        vm.warp(vestingContract.start() + VESTING_DURATION / 2);
        uint256 initialReleasable = vestingContract.releasable();

        // Release half of vested amount
        vm.prank(alice);
        vestingContract.release();

        // Warp to 75% vesting
        vm.warp(vestingContract.start() + (VESTING_DURATION * 3 / 4));
        uint256 expectedReleasable = (VESTING_AMOUNT * 3 / 4) - initialReleasable;

        assertEq(vestingContract.releasable(), expectedReleasable, "Should account for previously released tokens");
    }

    function testReleasableWithFuzzedTime(uint256 _timeOffset) public {
        // Bound time offset between start and end of vesting
        _timeOffset = bound(_timeOffset, 0, VESTING_DURATION);

        vm.warp(vestingContract.start() + _timeOffset);

        uint256 expectedAmount = (_timeOffset * VESTING_AMOUNT) / VESTING_DURATION;
        assertEq(vestingContract.releasable(), expectedAmount, "Incorrect releasable amount for given time");
    }

    function testReleasableAfterMultipleReleases() public {
        // Warp to 25% vesting and release
        vm.warp(vestingContract.start() + VESTING_DURATION / 4);
        vm.prank(alice);
        vestingContract.release();

        // Warp to 50% vesting and release
        vm.warp(vestingContract.start() + VESTING_DURATION / 2);
        vm.prank(alice);
        vestingContract.release();

        // Warp to 75% vesting
        vm.warp(vestingContract.start() + (VESTING_DURATION * 3 / 4));
        uint256 expectedReleasable = (VESTING_AMOUNT * 3 / 4) - (VESTING_AMOUNT / 2);

        assertEq(vestingContract.releasable(), expectedReleasable, "Should account for all previous releases");
    }

    /*//////////////////////////////////////////////////////////////
                            RELEASE TESTS
    //////////////////////////////////////////////////////////////*/

    function testReleaseWithZeroAmount() public {
        // Test release when releasable is 0 (before vesting starts)
        vm.warp(vestingContract.start() - 1);

        // Get current released amount
        uint256 beforeReleased = vestingContract.released();

        // Call release and verify it doesn't revert and doesn't change state
        vm.prank(alice);
        vestingContract.release();

        assertEq(vestingContract.released(), beforeReleased, "Released amount should not change");
        assertEq(tokenInstance.balanceOf(alice), 0, "No tokens should be transferred");
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzzVesting(uint256 _daysForward) public {
        // Bound days to be between cliff and total duration (in days)
        _daysForward = bound(_daysForward, 365, 1095); // 365 to (365 + 730) days

        // Convert days to seconds for vm.warp
        uint256 timeInSeconds = _daysForward * 1 days;
        vm.warp(startTimestamp + timeInSeconds);

        uint256 expectedVested;
        if (_daysForward >= 1095) {
            // CLIFF_PERIOD + VESTING_DURATION in days
            // Fully vested after cliff + duration
            expectedVested = VESTING_AMOUNT;
        } else if (_daysForward > 365) {
            // CLIFF_PERIOD in days
            // Linear vesting after cliff
            uint256 timeAfterCliff = _daysForward - 365;
            expectedVested = (VESTING_AMOUNT * timeAfterCliff) / 730; // VESTING_DURATION in days
        } else {
            // Nothing vested before cliff
            expectedVested = 0;
        }

        assertEq(vestingContract.releasable(), expectedVested, "Vested amount incorrect");
    }

    // Fuzz Test case: Check the claimable amount under various times
    function testFuzzReleasableAmount(uint256 _daysForward) public {
        vm.assume(_daysForward <= 730); // Assume within vesting period

        // Get initial state
        uint256 startTime = vestingContract.start();

        // Move forward in time after cliff period
        vm.warp(startTime + (_daysForward * 1 days));

        // Calculate expected vested amount
        uint256 claimableAmount = vestingContract.releasable();
        uint256 expectedClaimable;

        if (_daysForward == 730) {
            expectedClaimable = VESTING_AMOUNT; // Fully vested
        } else if (_daysForward > 0) {
            expectedClaimable = (VESTING_AMOUNT * _daysForward) / 730; // Linear vesting
        } else {
            expectedClaimable = 0; // Nothing vested yet
        }

        assertEq(claimableAmount, expectedClaimable, "Claimable amount should match linear vesting schedule");
    }

    // Fuzz Test: Claim edge cases (before and after vesting period)
    function testFuzzReleaseEdgeCases(uint256 _daysForward) public {
        vm.assume(_daysForward <= 730); // Assume max vesting period is 100 days + some buffer

        if (_daysForward >= 730) {
            // If time has passed, ensure claimable is the total vested
            vm.warp(block.timestamp + CLIFF_PERIOD + _daysForward * 1 days);
            uint256 claimableAmount = vestingContract.releasable();

            assertEq(
                claimableAmount, VESTING_AMOUNT, "Claimable should be equal to total vested after the vesting period"
            );
        } else if (_daysForward >= 1) {
            // Check that claimable amount is progressively increasing over time
            uint256 claimableAmountBefore = vestingContract.releasable();
            vm.warp(block.timestamp + CLIFF_PERIOD + _daysForward * 1 days);
            uint256 claimableAmountAfter = vestingContract.releasable();
            assertTrue(claimableAmountAfter > claimableAmountBefore, "Claimable amount should increase over time");
        }
    }

    // Fuzz Test: Ensure no claim is possible before vesting starts
    function testFuzzNoReleaseBeforeVesting(uint256 _daysBefore) public {
        vm.assume(_daysBefore <= 365); // cliff period is 365 days

        // Get initial state
        uint256 startTime = vestingContract.start();

        // Warp to a time before the cliff ends
        vm.warp(startTime - (_daysBefore * 1 days));

        // Check releasable amount
        uint256 claimableBeforeStart = vestingContract.releasable();
        assertEq(claimableBeforeStart, 0, "Claimable amount should be 0 before the vesting period starts");

        // Verify no tokens can be released
        vm.prank(alice);
        vestingContract.release();
        assertEq(vestingContract.released(), 0, "No tokens should be released before cliff");
        assertEq(tokenInstance.balanceOf(alice), 0, "Beneficiary should not receive tokens before cliff");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _initializeTokenDistribution() internal {
        vm.startPrank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        assertEq(tokenInstance.balanceOf(address(ecoInstance)), 22_000_000 ether);
        assertEq(tokenInstance.balanceOf(address(treasuryInstance)), 28_000_000 ether);
        vm.stopPrank();
    }

    function _deployAndFundVesting() internal {
        // Deploy vesting contract with VestingInitialized event expectation
        vm.expectEmit(true, true, true, true);
        emit VestingInitialized(
            address(tokenInstance),
            alice,
            address(timelockInstance),
            uint64(startTimestamp + CLIFF_PERIOD),
            VESTING_DURATION
        );

        vestingContract = new TeamVesting(
            address(tokenInstance),
            address(timelockInstance),
            alice,
            uint64(startTimestamp + CLIFF_PERIOD),
            VESTING_DURATION
        );

        // Fund vesting contract
        address[] memory investors = new address[](1);
        investors[0] = address(vestingContract);

        vm.startPrank(guardian);
        ecoInstance.grantRole(MANAGER_ROLE, managerAdmin);
        vm.stopPrank();

        vm.prank(managerAdmin);
        ecoInstance.airdrop(investors, VESTING_AMOUNT);
    }
}
