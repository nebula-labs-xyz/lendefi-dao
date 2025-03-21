// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
import {USDC} from "../../contracts/mock/USDC.sol";

contract TreasuryTest is BasicDeploy {
    address public owner = guardian;
    address public beneficiary = address(0x456);
    address public nonOwner = address(0x789);

    uint256 public vestingAmount = 1000 ether;
    uint256 public startTime;
    uint256 public vestingDuration;

    event EthReleased(address indexed to, uint256 amount, uint256 remainingReleasable); // Added remainingReleasable parameter
    event TokenReleased(address indexed token, address indexed to, uint256 amount);
    event VestingScheduleUpdated(address indexed updater, uint256 newStart, uint256 newDuration);
    event Initialized(address indexed initializer, uint256 startTime, uint256 duration);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);
    event Upgraded(address indexed upgrader, address indexed implementation, uint32 version);
    event UpgradeCancelled(address indexed canceller, address indexed implementation);
    event Received(address indexed src, uint256 amount);

    receive() external payable {
        if (msg.sender == address(treasuryInstance)) {
            // extends testRevert_ReleaseEther_Branch4
            bytes memory expError = abi.encodeWithSignature("ReentrancyGuardReentrantCall()");
            vm.prank(address(timelockInstance));
            vm.expectRevert(expError); // reentrancy
            treasuryInstance.release(guardian, 100 ether);
        }
    }

    function setUp() public {
        vm.warp(block.timestamp + 365 days);
        startTime = uint64(block.timestamp - 180 days);
        vestingDuration = uint64(1095 days);
        deployComplete();
        _setupToken();

        vm.prank(address(timelockInstance));
        treasuryInstance.grantRole(PAUSER_ROLE, pauser);
        vm.deal(address(treasuryInstance), vestingAmount);
    }

    // ============ Initialization Tests ============
    // Test: InitializeSuccess
    function testInitializeSuccess() public {
        // Update these assertions to match the new role assignments
        assertEq(treasuryInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)), true); // Changed from guardian
        assertEq(treasuryInstance.hasRole(PAUSER_ROLE, pauser), true);
        assertEq(treasuryInstance.hasRole(MANAGER_ROLE, address(timelockInstance)), true);
        assertEq(treasuryInstance.hasRole(UPGRADER_ROLE, gnosisSafe), true); // Check for multisig role
        assertEq(treasuryInstance.start(), block.timestamp - 180 days);
        assertEq(treasuryInstance.duration(), 1095 days);
        assertEq(treasuryInstance.version(), 1);
    }

    // Test: RevertInitializeTwice
    function testRevert_CantInitializeTwice() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        treasuryInstance.initialize(address(timelockInstance), gnosisSafe, startTime, vestingDuration);
    }

    // ============ Start Tests ============

    // Test: StartTimeInitialization
    function testStartTimeInitialization() public {
        assertEq(
            treasuryInstance.start(), block.timestamp - 180 days, "Start time should be 180 days before current time"
        );
    }

    // Test: StartTimeImmutability
    function testStartTimeImmutability() public {
        uint256 initialStart = treasuryInstance.start();

        // Warp time forward
        vm.warp(block.timestamp + 365 days);

        assertEq(treasuryInstance.start(), initialStart, "Start time should not change after initialization");
    }

    // ============ Receive Tests ============

    // Test: ReceiveETH
    function testReceiveETH() public {
        uint256 amount = 1 ether;
        uint256 initialBalance = address(treasuryInstance).balance;

        vm.expectEmit(true, true, true, true);
        emit Received(address(this), amount);

        // Send ETH to contract
        (bool success,) = address(treasuryInstance).call{value: amount}("");
        assertTrue(success, "ETH transfer should succeed");

        assertEq(address(treasuryInstance).balance, initialBalance + amount, "Treasury balance should increase");
    }

    // Test: ReceiveZeroETH
    function testReceiveZeroETH() public {
        uint256 initialBalance = address(treasuryInstance).balance;

        vm.expectEmit(true, true, true, true);
        emit Received(address(this), 0);

        // Send 0 ETH to contract
        (bool success,) = address(treasuryInstance).call{value: 0}("");
        assertTrue(success, "Zero ETH transfer should succeed");

        assertEq(address(treasuryInstance).balance, initialBalance, "Treasury balance should remain unchanged");
    }

    // Test: ReceiveMultipleETH
    function testReceiveMultipleETH() public {
        uint256 initialBalance = address(treasuryInstance).balance;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 0.5 ether;
        amounts[1] = 1 ether;
        amounts[2] = 1.5 ether;

        uint256 totalSent = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            vm.expectEmit(true, true, true, true);
            emit Received(address(this), amounts[i]);

            (bool success,) = address(treasuryInstance).call{value: amounts[i]}("");
            assertTrue(success, "ETH transfer should succeed");
            totalSent += amounts[i];
        }

        assertEq(
            address(treasuryInstance).balance,
            initialBalance + totalSent,
            "Treasury balance should reflect all transfers"
        );
    }
    // Test: Only Pauser Can Pause

    function testRevert_OnlyPauserCanPause() public {
        assertEq(treasuryInstance.paused(), false);
        vm.startPrank(pauser);
        treasuryInstance.pause();
        assertEq(treasuryInstance.paused(), true);
        treasuryInstance.unpause();
        assertEq(treasuryInstance.paused(), false);
        vm.stopPrank();

        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", nonOwner, PAUSER_ROLE);
        vm.prank(nonOwner);
        vm.expectRevert(expError); // access control violation
        treasuryInstance.pause();

        vm.prank(pauser);
        treasuryInstance.pause();
        assertTrue(treasuryInstance.paused());
    }

    // Test: Only Pauser Can Unpause
    function testRevert_OnlyPauserCanUnpause() public {
        assertEq(treasuryInstance.paused(), false);
        vm.prank(pauser);
        treasuryInstance.pause();
        assertTrue(treasuryInstance.paused());

        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", nonOwner, PAUSER_ROLE);
        vm.prank(nonOwner);
        vm.expectRevert(expError); // access control violation
        treasuryInstance.unpause();

        vm.prank(pauser);
        treasuryInstance.unpause();
        assertFalse(treasuryInstance.paused());
    }

    // Test: Cannot Release Tokens When Paused
    function testRevert_CannotReleaseWhenPaused() public {
        vm.warp(startTime + 10 days);
        assertEq(treasuryInstance.paused(), false);

        vm.prank(pauser);
        treasuryInstance.pause();
        assertEq(treasuryInstance.paused(), true);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError); // contract paused
        treasuryInstance.release(assetRecipient, 10 ether);
    }

    // Test: Cannot Release ERC20 When Paused
    function testRevert_CannotReleaseERC20WhenPaused() public {
        // Move to a time when tokens are vested
        _moveToVestingTime(50);

        // Get releasable amount
        uint256 releasableAmount = treasuryInstance.releasable(address(tokenInstance));
        assertTrue(releasableAmount > 0, "Should have releasable tokens");

        // Pause the contract
        vm.prank(pauser);
        treasuryInstance.pause();
        assertTrue(treasuryInstance.paused(), "Contract should be paused");

        // Try to release tokens while paused
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        treasuryInstance.release(address(tokenInstance), beneficiary, releasableAmount);
    }
    // Test: Only Manager Can Release Tokens

    function testRevert_OnlyManagerCanRelease() public {
        vm.warp(block.timestamp + 548 days); // half-vested
        uint256 vested = treasuryInstance.releasable(address(tokenInstance));
        // console.log(vested);
        assertTrue(vested > 0);
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError); // access control violation
        treasuryInstance.release(address(tokenInstance), beneficiary, vested);
    }

    // ============ Released Tests ============

    // Test: ReleasedETH
    // Test: ReleasedETH
    function testReleasedETH() public {
        // Check initial state
        assertEq(treasuryInstance.released(), 0, "Initial released ETH should be 0");

        // Move to 50% vesting time
        _moveToVestingTime(50);

        // Get releasable amount
        uint256 releasableAmount = treasuryInstance.releasable();
        assertTrue(releasableAmount > 0, "Should have releasable ETH");

        // Release ETH using timelock
        vm.prank(address(timelockInstance));
        treasuryInstance.release(beneficiary, releasableAmount);

        // Verify released amount
        assertEq(treasuryInstance.released(), releasableAmount, "Released ETH should match releasable amount");
    }

    // Test: ReleasedERC20
    function testReleasedERC20() public {
        // Check initial state
        assertEq(treasuryInstance.released(address(tokenInstance)), 0, "Initial released tokens should be 0");

        // Move to 50% vesting time
        _moveToVestingTime(50);

        // Get releasable amount
        uint256 releasableAmount = treasuryInstance.releasable(address(tokenInstance));
        assertTrue(releasableAmount > 0, "Should have releasable tokens");

        // Release tokens using timelock
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), beneficiary, releasableAmount);

        // Verify released amount
        assertEq(
            treasuryInstance.released(address(tokenInstance)),
            releasableAmount,
            "Released tokens should match releasable amount"
        );
    }

    // Test: ReleasedETHBeforeAnyRelease
    function testReleasedETHBeforeAnyRelease() public {
        assertEq(treasuryInstance.released(), 0, "Initial ETH release should be 0");
    }

    // Test: ReleasedTokenBeforeAnyRelease
    function testReleasedTokenBeforeAnyRelease() public {
        assertEq(treasuryInstance.released(address(tokenInstance)), 0, "Initial token release should be 0");
    }

    // Test: ReleasedTokenZeroAddress
    function testReleasedTokenZeroAddress() public {
        assertEq(treasuryInstance.released(address(0)), 0, "Zero address token release should be 0");
    }
    // ============ Releasable Tests ============
    // Test: ReleasableETHBeforeStart

    function testReleasableETHBeforeStart() public {
        vm.warp(startTime - 1 days);
        assertEq(treasuryInstance.releasable(), 0, "Nothing should be releasable before start");
    }

    // Test: ReleasableTokenBeforeStart
    function testReleasableTokenBeforeStart() public {
        vm.warp(startTime - 1 days);
        assertEq(treasuryInstance.releasable(address(tokenInstance)), 0, "Nothing should be releasable before start");
    }

    // Test: ReleasableAfterFullVesting
    function testReleasableAfterFullVesting() public {
        _moveToVestingTime(100);
        assertEq(treasuryInstance.releasable(), vestingAmount, "All ETH should be releasable");
        assertEq(
            treasuryInstance.releasable(address(tokenInstance)),
            tokenInstance.balanceOf(address(treasuryInstance)),
            "All tokens should be releasable"
        );
    }

    // Test: ReleasableZeroBalance
    function testReleasableZeroBalance() public {
        _moveToVestingTime(50);

        // Deploy new USDC instance for zero balance test
        USDC newUsdc = new USDC();

        // Check releasable for token with zero balance
        uint256 releasable = treasuryInstance.releasable(address(newUsdc));

        assertEq(releasable, 0, "Should be 0 for token with no balance");
        assertEq(newUsdc.balanceOf(address(treasuryInstance)), 0, "Treasury should have no balance");
    }

    // Test: ReleasableWithBalance
    function testReleasableWithBalance() public {
        // Deploy and mint USDC
        USDC newUsdc = new USDC();
        newUsdc.mint(address(treasuryInstance), INIT_BALANCE_USDC);
        _moveToVestingTime(50);

        uint256 elapsed = block.timestamp - treasuryInstance.start();
        uint256 expectedVested = (INIT_BALANCE_USDC * elapsed) / vestingDuration;
        uint256 releasable = treasuryInstance.releasable(address(newUsdc));

        assertEq(releasable, expectedVested, "Incorrect releasable amount");
    }

    // Test: ReleasableETH
    function testReleasableETH() public {
        _moveToVestingTime(50); // Move to 50% vesting time

        uint256 vested = treasuryInstance.releasable();
        uint256 elapsed = block.timestamp - treasuryInstance.start();
        uint256 expectedVested = (vestingAmount * elapsed) / vestingDuration;

        assertEq(vested, expectedVested, "Incorrect releasable ETH amount");
    }

    // Test: ReleasableERC20
    function testReleasableERC20() public {
        _moveToVestingTime(50); // Move to 50% vesting time

        uint256 totalBalance = tokenInstance.balanceOf(address(treasuryInstance));
        uint256 elapsed = block.timestamp - treasuryInstance.start();
        uint256 expectedVested = (totalBalance * elapsed) / vestingDuration;
        uint256 vested = treasuryInstance.releasable(address(tokenInstance));

        assertEq(vested, expectedVested, "Incorrect releasable token amount");
    }

    // Fuzz Test: Releasing Tokens with Randomized Timing
    function testFuzzRelease(uint256 warpTime) public {
        // Bound warpTime between start + cliff and end of vesting
        warpTime = bound(warpTime, startTime, startTime + vestingDuration);
        vm.warp(warpTime);

        uint256 elapsed = warpTime - startTime;
        uint256 expectedRelease = (elapsed * vestingAmount) / vestingDuration;

        // Ensure we're not trying to release more than what's vested
        uint256 alreadyReleased = treasuryInstance.released();
        expectedRelease = expectedRelease > alreadyReleased ? expectedRelease - alreadyReleased : 0;

        if (expectedRelease > 0) {
            uint256 beneficiaryBalanceBefore = beneficiary.balance;

            vm.prank(address(timelockInstance));
            treasuryInstance.release(beneficiary, expectedRelease);

            assertEq(beneficiary.balance, beneficiaryBalanceBefore + expectedRelease);
        }
    }

    // Fuzz Test: Only Pauser Can Pause or Unpause
    function testFuzzOnlyPauserCanPauseUnpause(address caller) public {
        vm.startPrank(caller);
        if (caller != address(timelockInstance)) {
            //guardian is pauser now
            bytes memory expError =
                abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", caller, PAUSER_ROLE);

            vm.expectRevert(expError); // access control violation
            treasuryInstance.pause();
        } else {
            treasuryInstance.pause();
            assertTrue(treasuryInstance.paused());

            treasuryInstance.unpause();
            assertFalse(treasuryInstance.paused());
        }
    }

    // Test: ReleaseEther
    function testReleaseEther() public {
        vm.warp(startTime + 219 days);
        uint256 startBal = address(treasuryInstance).balance;
        uint256 vested = treasuryInstance.releasable();

        // Update the event name and parameters to match the contract
        vm.startPrank(address(timelockInstance));
        vm.expectEmit(true, true, true, true);
        emit EthReleased(managerAdmin, vested, 0); // Use EthReleased to match contract
        treasuryInstance.release(managerAdmin, vested);
        vm.stopPrank();

        assertEq(managerAdmin.balance, vested);
        assertEq(address(treasuryInstance).balance, startBal - vested);
    }

    // Test: RevertReleaseEtherBranch1
    function testRevertReleaseEtherBranch1() public {
        vm.warp(startTime + 219 days);
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError); // access control violation
        treasuryInstance.release(guardian, 100 ether);
    }

    // Test: RevertReleaseEtherBranch2
    function testRevertReleaseEtherBranch2() public {
        vm.warp(startTime + 219 days);
        assertEq(treasuryInstance.paused(), false);
        vm.prank(address(timelockInstance));
        treasuryInstance.grantRole(PAUSER_ROLE, pauser);
        vm.prank(pauser);
        treasuryInstance.pause();
        assertEq(treasuryInstance.paused(), true);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError); // contract paused
        treasuryInstance.release(assetRecipient, 100 ether);
    }

    // Test: testRevert_ReleaseEther_Branch4
    function testRevert_ReleaseEther_Branch4() public {
        vm.warp(startTime + 1095 days);
        uint256 startingBal = address(this).balance;

        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(this), 100 ether);
        assertEq(address(this).balance, startingBal + 100 ether);
        assertEq(guardian.balance, 0);
    }

    // Test: ReleaseTokens
    function testReleaseTokens() public {
        vm.warp(startTime + 219 days);
        uint256 vested = treasuryInstance.releasable(address(tokenInstance));
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), assetRecipient, vested);
        assertEq(tokenInstance.balanceOf(assetRecipient), vested);
    }

    // Test: RevertReleaseTokensBranch1
    function testRevertReleaseTokensBranch1() public {
        vm.warp(startTime + 700 days);
        uint256 vested = treasuryInstance.releasable(address(tokenInstance));
        assertTrue(vested > 0);
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError); // access control violation
        treasuryInstance.release(address(tokenInstance), assetRecipient, vested);
    }

    // Test: RevertReleaseTokensBranch2
    function testRevertReleaseTokensBranch2() public {
        vm.warp(startTime + 219 days);
        uint256 vested = treasuryInstance.releasable(address(tokenInstance));
        assertTrue(vested > 0);
        assertEq(treasuryInstance.paused(), false);
        vm.prank(address(timelockInstance));
        treasuryInstance.grantRole(PAUSER_ROLE, pauser);
        vm.prank(pauser);
        treasuryInstance.pause();
        assertEq(treasuryInstance.paused(), true);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError); // contract paused
        treasuryInstance.release(address(tokenInstance), assetRecipient, vested);
    }

    // Test: ERC20Released
    function testERC20Released() public {
        // Test initial state
        assertEq(treasuryInstance.released(address(tokenInstance)), 0, "Initial released amount should be 0");

        // Move to 50% vesting time and release tokens
        _moveToVestingTime(50);
        uint256 releaseAmount = treasuryInstance.releasable(address(tokenInstance));

        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), beneficiary, releaseAmount);

        // Verify erc20Released matches released(address)
        assertEq(
            tokenInstance.balanceOf(beneficiary),
            treasuryInstance.released(address(tokenInstance)),
            "erc20Released should match released(address)"
        );
        assertEq(
            treasuryInstance.released(address(tokenInstance)),
            releaseAmount,
            "erc20Released should return correct amount"
        );
    }

    function testRoleManagement() public {
        // Change the prank from guardian to timelock since timelock now has DEFAULT_ADMIN_ROLE
        vm.startPrank(address(timelockInstance));
        treasuryInstance.grantRole(MANAGER_ROLE, managerAdmin);
        assertTrue(treasuryInstance.hasRole(MANAGER_ROLE, managerAdmin));
        treasuryInstance.revokeRole(MANAGER_ROLE, managerAdmin);
        assertFalse(treasuryInstance.hasRole(MANAGER_ROLE, managerAdmin));
        vm.stopPrank();
    }

    function testPartialVestingRelease() public {
        _moveToVestingTime(50); // 50% vested
        uint256 vested = treasuryInstance.releasable();
        uint256 partialAmount = vested / 2;

        vm.prank(address(timelockInstance));
        treasuryInstance.release(beneficiary, partialAmount);

        assertEq(treasuryInstance.released(), partialAmount);
        assertEq(beneficiary.balance, partialAmount);
    }

    function testMultipleReleasesInSameBlock() public {
        _moveToVestingTime(75); // 75% vested
        uint256 vested = treasuryInstance.releasable();
        uint256 firstRelease = vested / 3;
        uint256 secondRelease = vested / 3;

        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(beneficiary, firstRelease);
        treasuryInstance.release(beneficiary, secondRelease);
        vm.stopPrank();

        assertEq(treasuryInstance.released(), firstRelease + secondRelease);
        assertEq(beneficiary.balance, firstRelease + secondRelease);
    }

    function testFuzzVestingSchedule(uint8 percentage) public {
        vm.assume(percentage > 0 && percentage <= 100);
        _moveToVestingTime(percentage);

        uint256 expectedVested = (vestingAmount * percentage) / 100;
        uint256 actualVested = treasuryInstance.releasable();

        assertApproxEqRel(actualVested, expectedVested, 0.01e18);
    }

    function testReentrancyOnMultipleReleases() public {
        _moveToVestingTime(100);
        address reentrancyAttacker = address(this);

        vm.prank(address(timelockInstance));
        treasuryInstance.release(reentrancyAttacker, 100 ether);
    }

    function testPausedStateTransitions() public {
        // Test multiple pause/unpause transitions
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(pauser);
            treasuryInstance.pause();
            assertTrue(treasuryInstance.paused());

            vm.prank(pauser);
            treasuryInstance.unpause();
            assertFalse(treasuryInstance.paused());
        }
    }

    function testFuzzReleaseAmounts(uint256 amount) public {
        vm.assume(amount > 0 && amount <= vestingAmount);
        _moveToVestingTime(100);

        vm.prank(address(timelockInstance));
        treasuryInstance.release(beneficiary, amount);

        assertEq(beneficiary.balance, amount);
        assertEq(treasuryInstance.released(), amount);
    }

    function testReleaseAfterRoleRevocation() public {
        _moveToVestingTime(100);
        address tempManager = address(0xDEF);

        _grantManagerRole(tempManager);
        _revokeManagerRole(tempManager);

        vm.prank(tempManager);
        vm.expectRevert(); // Should revert due to lack of role
        treasuryInstance.release(beneficiary, 100 ether);
    }

    // Test: RevertReleaseEtherBranch3
    function testRevertReleaseEtherBranch3() public {
        vm.warp(startTime + 10 days);
        uint256 vested = treasuryInstance.releasable();
        uint256 requestedAmount = 101 ether;

        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(ITREASURY.InsufficientVestedAmount.selector, requestedAmount, vested));
        treasuryInstance.release(assetRecipient, requestedAmount);
    }

    // Test: RevertReleaseTokensBranch3
    function testRevertReleaseTokensBranch3() public {
        vm.warp(startTime + 219 days);
        uint256 vested = treasuryInstance.releasable(address(tokenInstance));
        assertTrue(vested > 0);
        uint256 requestedAmount = vested + 1 ether;

        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(ITREASURY.InsufficientVestedAmount.selector, requestedAmount, vested));
        treasuryInstance.release(address(tokenInstance), assetRecipient, requestedAmount);
    }

    // Test: RevertReleaseTokensZeroToken
    function testRevertReleaseTokensZeroToken() public {
        _moveToVestingTime(50);
        uint256 amount = 100 ether;

        vm.prank(address(timelockInstance));
        vm.expectRevert(ITREASURY.ZeroAddress.selector);
        treasuryInstance.release(address(tokenInstance), address(0), amount);
    }

    // Test: ReleaseToZeroAddress
    function testReleaseToZeroAddress() public {
        _moveToVestingTime(100);
        vm.prank(address(timelockInstance));
        vm.expectRevert(ITREASURY.ZeroAddress.selector);
        treasuryInstance.release(address(0), 100 ether);
        assertEq(address(0).balance, 0);
    }

    // Add new tests for zero amount errors
    function testRevert_ReleaseZeroAmount() public {
        _moveToVestingTime(50);

        vm.prank(address(timelockInstance));
        vm.expectRevert(ITREASURY.ZeroAmount.selector);
        treasuryInstance.release(beneficiary, 0);

        vm.prank(address(timelockInstance));
        vm.expectRevert(ITREASURY.ZeroAmount.selector);
        treasuryInstance.release(address(tokenInstance), beneficiary, 0);
    }

    // Test for invalid duration
    function testRevert_InvalidDuration() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(ITREASURY.InvalidDuration.selector, 0));
        treasuryInstance.updateVestingSchedule(uint64(block.timestamp), 0);
    }

    // Additional helper functions
    function _grantManagerRole(address account) internal {
        vm.prank(address(timelockInstance));
        treasuryInstance.grantRole(MANAGER_ROLE, account);
    }

    function _revokeManagerRole(address account) internal {
        vm.prank(address(timelockInstance));
        treasuryInstance.revokeRole(MANAGER_ROLE, account);
    }

    function _moveToVestingTime(uint256 percentage) internal {
        require(percentage <= 100, "Invalid percentage");
        uint256 timeToMove = (vestingDuration * percentage) / 100;
        vm.warp(startTime + timeToMove);
    }

    function _setupToken() private {
        assertEq(tokenInstance.totalSupply(), 0);
        vm.startPrank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        uint256 ecoBal = tokenInstance.balanceOf(address(ecoInstance));
        uint256 treasuryBal = tokenInstance.balanceOf(address(treasuryInstance));
        uint256 guardianBal = tokenInstance.balanceOf(guardian);

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 27_400_000 ether);
        assertEq(guardianBal, 600_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal + guardianBal);
        vm.stopPrank();
    }

    // Test successful scheduling of an upgrade
    function testScheduleUpgrade() public {
        address mockImplementation = address(0xABCD);

        vm.recordLogs();

        vm.prank(gnosisSafe);
        treasuryInstance.scheduleUpgrade(mockImplementation);

        // Verify event emission
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);

        // Get pending upgrade info
        (address implementation, uint64 scheduledTime, bool exists) = treasuryInstance.pendingUpgrade();
        assertEq(implementation, mockImplementation);
        assertEq(scheduledTime, uint64(block.timestamp));
        assertTrue(exists);
    }

    // Test the remaining time calculation
    function testUpgradeTimelockRemaining() public {
        address mockImplementation = address(0xABCD);

        // Schedule an upgrade
        vm.prank(gnosisSafe);
        treasuryInstance.scheduleUpgrade(mockImplementation);

        // Check initial remaining time
        uint256 remaining = treasuryInstance.upgradeTimelockRemaining();
        assertEq(remaining, 3 days, "Remaining time should be 3 days initially");

        // Forward time by 1 day
        vm.warp(block.timestamp + 1 days);

        // Check updated remaining time
        remaining = treasuryInstance.upgradeTimelockRemaining();
        assertEq(remaining, 2 days, "Remaining time should be 2 days after 1 day has passed");

        // Forward time past timelock
        vm.warp(block.timestamp + 3 days);

        // Check that remaining time is now 0
        remaining = treasuryInstance.upgradeTimelockRemaining();
        assertEq(remaining, 0, "Remaining time should be 0 after timelock period has passed");
    }

    // Test that non-upgraders can't schedule upgrades
    function testRevert_OnlyUpgraderCanSchedule() public {
        address mockImplementation = address(0xABCD);

        bytes memory expError = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", guardian, treasuryInstance.UPGRADER_ROLE()
        );

        vm.prank(guardian);
        vm.expectRevert(expError);
        treasuryInstance.scheduleUpgrade(mockImplementation);
    }

    // Test revert on zero address implementation
    function testRevert_ScheduleUpgradeZeroAddress() public {
        vm.prank(gnosisSafe);
        vm.expectRevert(ITREASURY.ZeroAddress.selector);
        treasuryInstance.scheduleUpgrade(address(0));
    }

    // Test full upgrade flow with timelock
    function testTreasuryUpgradeWithTimelock() public {
        deployTreasuryUpgrade();
    }

    // Test cancelling an upgrade
    function test_CancelUpgrade() public {
        address mockImplementation = address(0xABCD);

        // Schedule an upgrade first
        vm.prank(gnosisSafe); // Has UPGRADER_ROLE
        treasuryInstance.scheduleUpgrade(mockImplementation);

        // Verify upgrade is scheduled
        (address impl,, bool exists) = treasuryInstance.pendingUpgrade();
        assertTrue(exists);
        assertEq(impl, mockImplementation);

        // Now cancel it
        vm.expectEmit(true, true, false, false);
        emit UpgradeCancelled(gnosisSafe, mockImplementation);

        vm.prank(gnosisSafe);
        treasuryInstance.cancelUpgrade();

        // Verify upgrade was cancelled
        (,, exists) = treasuryInstance.pendingUpgrade();
        assertFalse(exists);
    }

    // Test error when trying to cancel non-existent upgrade
    function testRevert_CancelUpgradeNoScheduledUpgrade() public {
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSignature("UpgradeNotScheduled()"));
        treasuryInstance.cancelUpgrade();
    }

    // Test emergency withdrawal of ETH always goes to timelock
    function testEmergencyWithdrawETHToTimelock() public {
        uint256 initialBalance = address(timelockInstance).balance;
        uint256 treasuryBalance = address(treasuryInstance).balance; // Get the actual balance

        vm.prank(address(timelockInstance));
        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdrawal(ethereum, address(timelockInstance), treasuryBalance); // Use actual balance
        treasuryInstance.emergencyWithdrawEther();

        assertEq(address(timelockInstance).balance, initialBalance + treasuryBalance, "ETH should be sent to timelock");
        assertEq(address(treasuryInstance).balance, 0, "Treasury should have no ETH left");
    }

    // Test emergency withdrawal of tokens always goes to timelock
    function testEmergencyWithdrawTokensToTimelock() public {
        uint256 initialBalance = tokenInstance.balanceOf(address(timelockInstance));
        uint256 treasuryTokenBalance = tokenInstance.balanceOf(address(treasuryInstance)); // Get actual balance

        vm.prank(address(timelockInstance));
        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdrawal(address(tokenInstance), address(timelockInstance), treasuryTokenBalance); // Use actual balance
        treasuryInstance.emergencyWithdrawToken(address(tokenInstance));

        assertEq(
            tokenInstance.balanceOf(address(timelockInstance)),
            initialBalance + treasuryTokenBalance,
            "Tokens should be sent to timelock"
        );
        assertEq(tokenInstance.balanceOf(address(treasuryInstance)), 0, "Treasury should have no tokens left");
    }

    // Test timelock address getter
    function testTimelockAddress() public {
        assertEq(treasuryInstance.timelockAddress(), address(timelockInstance), "Timelock address should match");
    }
}
