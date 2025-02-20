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
    uint256 public totalDuration;

    event EtherReleased(address indexed to, uint256 amount);
    event ERC20Released(address indexed token, address indexed to, uint256 amount);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event Received(address indexed src, uint256 amount);

    receive() external payable {
        if (msg.sender == address(treasuryInstance)) {
            // extends test_Revert_ReleaseEther_Branch4()
            bytes memory expError = abi.encodeWithSignature("ReentrancyGuardReentrantCall()");
            vm.prank(address(timelockInstance));
            vm.expectRevert(expError); // reentrancy
            treasuryInstance.release(guardian, 100 ether);
        }
    }

    function setUp() public {
        vm.warp(block.timestamp + 365 days);
        startTime = uint64(block.timestamp - 180 days);
        totalDuration = uint64(1095 days);
        deployComplete();
        _setupToken();

        vm.prank(guardian);
        treasuryInstance.grantRole(PAUSER_ROLE, pauser);
        vm.deal(address(treasuryInstance), vestingAmount);
    }

    // ============ Initialization Tests ============

    function testCannotInitializeTwice() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        treasuryInstance.initialize(guardian, address(timelockInstance));
    }

    // ============ Initialization Tests ============
    // Test: InitializeSuccess
    function testInitializeSuccess() public {
        assertEq(treasuryInstance.hasRole(DEFAULT_ADMIN_ROLE, guardian), true);
        assertEq(treasuryInstance.hasRole(PAUSER_ROLE, pauser), true);
        assertEq(treasuryInstance.hasRole(MANAGER_ROLE, address(timelockInstance)), true);
        assertEq(treasuryInstance.start(), block.timestamp - 180 days);
        assertEq(treasuryInstance.duration(), 1095 days);
        assertEq(treasuryInstance.version(), 1);
    }

    // Test: RevertInitializeTwice
    function testRevertInitializeTwice() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        treasuryInstance.initialize(guardian, address(timelockInstance));
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

    function testOnlyPauserCanPause() public {
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
    function testOnlyPauserCanUnpause() public {
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
    function testCannotReleaseWhenPaused() public {
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
    function testCannotReleaseERC20WhenPaused() public {
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

    function testOnlyManagerCanRelease() public {
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
        uint256 expectedVested = (INIT_BALANCE_USDC * elapsed) / totalDuration;
        uint256 releasable = treasuryInstance.releasable(address(newUsdc));

        assertEq(releasable, expectedVested, "Incorrect releasable amount");
    }

    // Test: ReleasableETH
    function testReleasableETH() public {
        _moveToVestingTime(50); // Move to 50% vesting time

        uint256 vested = treasuryInstance.releasable();
        uint256 elapsed = block.timestamp - treasuryInstance.start();
        uint256 expectedVested = (vestingAmount * elapsed) / totalDuration;

        assertEq(vested, expectedVested, "Incorrect releasable ETH amount");
    }

    // Test: ReleasableERC20
    function testReleasableERC20() public {
        _moveToVestingTime(50); // Move to 50% vesting time

        uint256 totalBalance = tokenInstance.balanceOf(address(treasuryInstance));
        uint256 elapsed = block.timestamp - treasuryInstance.start();
        uint256 expectedVested = (totalBalance * elapsed) / totalDuration;
        uint256 vested = treasuryInstance.releasable(address(tokenInstance));

        assertEq(vested, expectedVested, "Incorrect releasable token amount");
    }

    // Fuzz Test: Releasing Tokens with Randomized Timing
    function testFuzzRelease(uint256 warpTime) public {
        // Bound warpTime between start + cliff and end of vesting
        warpTime = bound(warpTime, startTime, startTime + totalDuration);
        vm.warp(warpTime);

        uint256 elapsed = warpTime - startTime;
        uint256 expectedRelease = (elapsed * vestingAmount) / totalDuration;

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
        if (caller != pauser) {
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

    // Test: RevertInitialize
    function testRevertInitialize() public {
        vm.warp(startTime + 219 days);
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        treasuryInstance.initialize(guardian, address(timelockInstance));
    }

    // Test: ReleaseEther
    function testReleaseEther() public {
        vm.warp(startTime + 219 days);
        uint256 startBal = address(treasuryInstance).balance;
        uint256 vested = treasuryInstance.releasable();
        vm.startPrank(address(timelockInstance));
        vm.expectEmit(address(treasuryInstance));
        emit EtherReleased(managerAdmin, vested);
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
        vm.prank(guardian);
        treasuryInstance.grantRole(PAUSER_ROLE, pauser);
        vm.prank(pauser);
        treasuryInstance.pause();
        assertEq(treasuryInstance.paused(), true);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError); // contract paused
        treasuryInstance.release(assetRecipient, 100 ether);
    }

    // Test: RevertReleaseEtherBranch3
    function testRevertReleaseEtherBranch3() public {
        vm.warp(startTime + 10 days);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "NOT_ENOUGH_VESTED");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError);
        treasuryInstance.release(assetRecipient, 101 ether);
    }

    // Test: RevertReleaseEtherBranch4
    function testRevertReleaseEtherBranch4() public {
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
        vm.prank(guardian);
        treasuryInstance.grantRole(PAUSER_ROLE, pauser);
        vm.prank(pauser);
        treasuryInstance.pause();
        assertEq(treasuryInstance.paused(), true);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError); // contract paused
        treasuryInstance.release(address(tokenInstance), assetRecipient, vested);
    }

    // Test: RevertReleaseTokensBranch3
    function testRevertReleaseTokensBranch3() public {
        vm.warp(startTime + 219 days);
        uint256 vested = treasuryInstance.releasable(address(tokenInstance));
        assertTrue(vested > 0);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "NOT_ENOUGH_VESTED");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError); // not enough vested violation
        treasuryInstance.release(address(tokenInstance), assetRecipient, vested + 1 ether);
    }

    // Test: RevertReleaseTokensZeroToken
    function testRevertReleaseTokensZeroToken() public {
        _moveToVestingTime(50);
        uint256 amount = 100 ether;

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "ZERO_ADDRESS");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError);
        treasuryInstance.release(address(tokenInstance), address(0), amount);
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
    // Additional test cases

    function testRoleManagement() public {
        address newManager = address(0xABC);

        vm.startPrank(guardian);
        vm.expectEmit(true, true, true, true);
        emit RoleGranted(MANAGER_ROLE, newManager, guardian);
        treasuryInstance.grantRole(MANAGER_ROLE, newManager);

        vm.expectEmit(true, true, true, true);
        emit RoleRevoked(MANAGER_ROLE, newManager, guardian);
        treasuryInstance.revokeRole(MANAGER_ROLE, newManager);
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

    function testReleaseToZeroAddress() public {
        _moveToVestingTime(100);
        vm.prank(address(timelockInstance));
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "ZERO_ADDRESS");
        vm.expectRevert(expError);
        treasuryInstance.release(address(0), 100 ether);
        assertEq(address(0).balance, 0);
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

    // Additional helper functions

    function _grantManagerRole(address account) internal {
        vm.prank(guardian);
        treasuryInstance.grantRole(MANAGER_ROLE, account);
    }

    function _revokeManagerRole(address account) internal {
        vm.prank(guardian);
        treasuryInstance.revokeRole(MANAGER_ROLE, account);
    }

    function _moveToVestingTime(uint256 percentage) internal {
        require(percentage <= 100, "Invalid percentage");
        uint256 timeToMove = (totalDuration * percentage) / 100;
        vm.warp(startTime + timeToMove);
    }

    function _setupToken() private {
        assertEq(tokenInstance.totalSupply(), 0);
        vm.startPrank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        uint256 ecoBal = tokenInstance.balanceOf(address(ecoInstance));
        uint256 treasuryBal = tokenInstance.balanceOf(address(treasuryInstance));

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 28_000_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal);
        vm.stopPrank();
    }
}
