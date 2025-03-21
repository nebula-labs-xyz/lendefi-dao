// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, Vm} from "forge-std/Test.sol";
import {Treasury} from "../../contracts/ecosystem/Treasury.sol";
import {TreasuryV2} from "../../contracts/upgrades/TreasuryV2.sol";
import {ITREASURY} from "../../contracts/interfaces/ITreasury.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DefenderOptions} from "openzeppelin-foundry-upgrades/Options.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract TreasuryBasicTest is Test {
    // Events
    event Initialized(address indexed initializer, uint256 start, uint256 duration);
    event VestingScheduleUpdated(address indexed updater, uint256 newStart, uint256 newDuration);
    event EthReleased(address indexed to, uint256 amount, uint256 remaining);
    event TokenReleased(address indexed token, address indexed to, uint256 amount);
    event Received(address indexed sender, uint256 amount);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);
    event UpgradeScheduled(
        address indexed scheduler, address implementation, uint64 scheduledTime, uint64 effectiveTime
    );
    event Upgraded(address indexed upgrader, address indexed implementation, uint32 version);
    event Paused(address account);
    event Unpaused(address account);

    // Constants
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    uint256 private constant UPGRADE_TIMELOCK_DURATION = 3 days;

    // Ethereum special address
    address constant ethereum = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Test accounts
    address timelock = address(0x2222);
    address multisig = address(0x3333);
    address recipient = address(0x4444);
    address alice = address(0x5555);

    // Contract instances
    TokenMock tokenProxy;
    Treasury treasuryImpl;
    Treasury treasuryProxy;

    // Vesting parameters
    uint256 startOffset = 0; // Start vesting now
    uint256 vestingDuration = 3 * 365 days; // 3 years
    uint256 startTimestamp;

    function setUp() public {
        // Deploy mock token
        tokenProxy = new TokenMock("Test Token", "TEST");

        // Deploy Treasury implementation
        treasuryImpl = new Treasury();

        // Deploy proxy with implementation
        bytes memory initData = abi.encodeCall(Treasury.initialize, (timelock, multisig, startOffset, vestingDuration));

        ERC1967Proxy proxy = new ERC1967Proxy(address(treasuryImpl), initData);
        treasuryProxy = Treasury(payable(address(proxy)));

        // Fund the Treasury with ETH
        vm.deal(address(treasuryProxy), 100 ether);

        // Fund the Treasury with tokens
        tokenProxy.mint(address(treasuryProxy), 1_000_000e18);

        // Record the starting timestamp
        startTimestamp = block.timestamp;
    }

    // Test initialization parameters
    function test_Initialization() public {
        assertEq(treasuryProxy.start(), block.timestamp, "Start timestamp incorrect");
        assertEq(treasuryProxy.duration(), vestingDuration, "Duration incorrect");
        assertEq(treasuryProxy.end(), block.timestamp + vestingDuration, "End timestamp incorrect");
        assertEq(treasuryProxy.released(), 0, "Initial released amount should be 0");
        assertEq(treasuryProxy.released(address(tokenProxy)), 0, "Initial token released amount should be 0");
        assertTrue(treasuryProxy.hasRole(DEFAULT_ADMIN_ROLE, timelock), "Timelock should have DEFAULT_ADMIN_ROLE");
        assertTrue(treasuryProxy.hasRole(MANAGER_ROLE, timelock), "Timelock should have MANAGER_ROLE");
        assertTrue(treasuryProxy.hasRole(PAUSER_ROLE, timelock), "Guardian should have PAUSER_ROLE");
        assertTrue(treasuryProxy.hasRole(UPGRADER_ROLE, multisig), "Multisig should have UPGRADER_ROLE");
        assertEq(treasuryProxy.version(), 1, "Initial version should be 1");
        assertEq(treasuryProxy.timelockAddress(), timelock, "Timelock address incorrect");
    }

    // Test initialization reverts with zero addresses
    function test_Revert_InitializeRevertsWithZeroAddresses() public {
        Treasury newImpl = new Treasury();

        // Test with zero timelock
        bytes memory data = abi.encodeCall(Treasury.initialize, (address(0), multisig, startOffset, vestingDuration));
        vm.expectRevert(ITREASURY.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), data);

        // Test with zero multisig
        data = abi.encodeCall(Treasury.initialize, (timelock, address(0), startOffset, vestingDuration));
        vm.expectRevert(ITREASURY.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), data);

        // Test with invalid duration
        data = abi.encodeCall(Treasury.initialize, (timelock, multisig, startOffset, 729 days));
        vm.expectRevert(abi.encodeWithSelector(ITREASURY.InvalidDuration.selector, 730 days));
        new ERC1967Proxy(address(newImpl), data);
    }

    // Test pause and unpause
    function test_PauseUnpause() public {
        // Initial state should be unpaused
        assertFalse(treasuryProxy.paused(), "Treasury should start unpaused");

        // Guardian should be able to pause
        vm.prank(timelock);
        vm.expectEmit(true, true, true, true);
        emit Paused(timelock);
        treasuryProxy.pause();
        assertTrue(treasuryProxy.paused(), "Treasury should be paused");

        // Guardian should be able to unpause
        vm.prank(timelock);
        vm.expectEmit(true, true, true, true);
        emit Unpaused(timelock);
        treasuryProxy.unpause();
        assertFalse(treasuryProxy.paused(), "Treasury should be unpaused");

        // Non-guardian should not be able to pause
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), alice, PAUSER_ROLE
            )
        );
        treasuryProxy.pause();
    }

    // Test releasing ETH
    function test_ReleaseEth() public {
        // Warp to 25% through vesting period
        vm.warp(startTimestamp + vestingDuration / 4);

        // Check releasable amount
        uint256 expectedReleasable = 25 ether; // 25% of 100 ether
        assertEq(treasuryProxy.releasable(), expectedReleasable, "Releasable ETH should be 25%");

        // Release ETH
        uint256 recipientInitialBalance = recipient.balance;
        vm.prank(timelock);
        vm.expectEmit(true, true, true, true);
        emit EthReleased(recipient, 10 ether, 15 ether); // 10 ETH released, 15 ETH remaining
        treasuryProxy.release(recipient, 10 ether);

        // Verify release
        assertEq(recipient.balance, recipientInitialBalance + 10 ether, "Recipient should receive ETH");
        assertEq(treasuryProxy.released(), 10 ether, "Released amount should update");
        assertEq(treasuryProxy.releasable(), 15 ether, "Releasable should be updated");

        // Try to release more than available
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ITREASURY.InsufficientVestedAmount.selector, 20 ether, 15 ether));
        treasuryProxy.release(recipient, 20 ether);

        // Non-manager should not be able to release

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), alice, MANAGER_ROLE
            )
        );
        vm.prank(alice);
        treasuryProxy.release(recipient, 1 ether);

        // Test release when paused
        vm.startPrank(timelock);
        treasuryProxy.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        treasuryProxy.release(recipient, 1 ether);

        // Unpause and continue testing
        treasuryProxy.unpause();

        // Test with invalid parameters
        vm.expectRevert(ITREASURY.ZeroAddress.selector);
        treasuryProxy.release(address(0), 1 ether);

        vm.expectRevert(ITREASURY.ZeroAmount.selector);
        treasuryProxy.release(recipient, 0);
        vm.stopPrank();
    }

    // Test releasing ERC20 tokens
    function test_ReleaseTokens() public {
        // Warp to 25% through vesting period
        vm.warp(startTimestamp + vestingDuration / 4);

        // Check releasable token amount
        uint256 expectedReleasable = 250_000e18; // 25% of 1,000,000
        assertEq(treasuryProxy.releasable(address(tokenProxy)), expectedReleasable, "Releasable tokens should be 25%");

        // Release tokens
        vm.prank(timelock);
        vm.expectEmit(true, true, true, true);
        emit TokenReleased(address(tokenProxy), recipient, 100_000e18);
        treasuryProxy.release(address(tokenProxy), recipient, 100_000e18);

        // Verify release
        assertEq(tokenProxy.balanceOf(recipient), 100_000e18, "Recipient should receive tokens");
        assertEq(treasuryProxy.released(address(tokenProxy)), 100_000e18, "Released amount should update");
        assertEq(treasuryProxy.releasable(address(tokenProxy)), 150_000e18, "Releasable should be updated");

        // Try to release more than available
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ITREASURY.InsufficientVestedAmount.selector, 200_000e18, 150_000e18));
        treasuryProxy.release(address(tokenProxy), recipient, 200_000e18);

        // Test with invalid parameters
        vm.prank(timelock);
        vm.expectRevert(ITREASURY.ZeroAddress.selector);
        treasuryProxy.release(address(0), recipient, 100e18);

        vm.prank(timelock);
        vm.expectRevert(ITREASURY.ZeroAddress.selector);
        treasuryProxy.release(address(tokenProxy), address(0), 100e18);

        vm.prank(timelock);
        vm.expectRevert(ITREASURY.ZeroAmount.selector);
        treasuryProxy.release(address(tokenProxy), recipient, 0);
    }

    // Test vesting schedule calculation
    function test_VestedAmountCalculation() public {
        // Before start - should be 0
        vm.warp(startTimestamp - 1);
        assertEq(treasuryProxy.vestedAmount(block.timestamp), 0, "Nothing should be vested before start");
        assertEq(
            treasuryProxy.vestedAmount(address(tokenProxy), block.timestamp),
            0,
            "No tokens should be vested before start"
        );

        // At start - should be 0
        vm.warp(startTimestamp);
        assertEq(treasuryProxy.vestedAmount(block.timestamp), 0, "Nothing should be vested at start");
        assertEq(
            treasuryProxy.vestedAmount(address(tokenProxy), block.timestamp), 0, "No tokens should be vested at start"
        );

        // At 50% of vesting period
        vm.warp(startTimestamp + vestingDuration / 2);
        assertEq(treasuryProxy.vestedAmount(block.timestamp), 50 ether, "50% of ETH should be vested");
        assertEq(
            treasuryProxy.vestedAmount(address(tokenProxy), block.timestamp),
            500_000e18,
            "50% of tokens should be vested"
        );

        // After end - should be 100%
        vm.warp(startTimestamp + vestingDuration + 1);
        assertEq(treasuryProxy.vestedAmount(block.timestamp), 100 ether, "100% of ETH should be vested");
        assertEq(
            treasuryProxy.vestedAmount(address(tokenProxy), block.timestamp),
            1_000_000e18,
            "100% of tokens should be vested"
        );
    }

    // Test updating vesting schedule
    function test_UpdateVestingSchedule() public {
        uint256 newStart = startTimestamp + 30 days;
        uint256 newDuration = 2 * 365 days;

        vm.prank(timelock);
        vm.expectEmit(true, true, true, true);
        emit VestingScheduleUpdated(timelock, newStart, newDuration);
        treasuryProxy.updateVestingSchedule(newStart, newDuration);

        assertEq(treasuryProxy.start(), newStart, "Start should be updated");
        assertEq(treasuryProxy.duration(), newDuration, "Duration should be updated");
        assertEq(treasuryProxy.end(), newStart + newDuration, "End should be updated");

        // Non-admin should not be able to update schedule
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), alice, DEFAULT_ADMIN_ROLE
            )
        );
        treasuryProxy.updateVestingSchedule(newStart, newDuration);

        // Zero duration should revert
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ITREASURY.InvalidDuration.selector, 0));
        treasuryProxy.updateVestingSchedule(newStart, 0);

        // Check vesting calculation with updated schedule
        vm.warp(newStart + newDuration / 4); // 25% through new schedule
        assertEq(treasuryProxy.vestedAmount(block.timestamp), 25 ether, "25% of ETH should be vested with new schedule");
        assertEq(
            treasuryProxy.vestedAmount(address(tokenProxy), block.timestamp),
            250_000e18,
            "25% of tokens should be vested with new schedule"
        );
    }

    function test_EmergencyWithdrawETH() public {
        uint256 initialBalance = timelock.balance;

        vm.prank(timelock);
        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdrawal(ethereum, timelock, address(treasuryProxy).balance);
        treasuryProxy.emergencyWithdrawEther();

        // Verify all ETH was sent to timelock
        assertEq(timelock.balance, initialBalance + 100 ether, "ETH should be sent to timelock");
        assertEq(address(treasuryProxy).balance, 0, "Treasury should have no ETH left");

        // Non-manager should not be able to withdraw
        vm.deal(address(treasuryProxy), 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), alice, MANAGER_ROLE
            )
        );
        treasuryProxy.emergencyWithdrawEther();

        // Zero balance should revert
        vm.prank(timelock);
        treasuryProxy.emergencyWithdrawEther();

        vm.prank(timelock);
        vm.expectRevert(ITREASURY.ZeroBalance.selector);
        treasuryProxy.emergencyWithdrawEther();
    }

    function test_Revert_EmergencyWithdrawTokens() public {
        uint256 initialBalance = tokenProxy.balanceOf(timelock);
        uint256 treasuryBalance = tokenProxy.balanceOf(address(treasuryProxy));

        vm.prank(timelock);
        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdrawal(address(tokenProxy), timelock, treasuryBalance);
        treasuryProxy.emergencyWithdrawToken(address(tokenProxy));

        assertEq(tokenProxy.balanceOf(timelock), initialBalance + treasuryBalance, "Tokens should be sent to timelock");
        assertEq(tokenProxy.balanceOf(address(treasuryProxy)), 0, "Treasury should have no tokens left");

        // Transfer some tokens back for additional testing
        vm.prank(timelock);
        tokenProxy.transfer(address(treasuryProxy), 100_000e18);

        // Non-manager should not be able to withdraw
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), alice, MANAGER_ROLE
            )
        );
        vm.prank(alice);
        treasuryProxy.emergencyWithdrawToken(address(tokenProxy));
    }

    // Test receive function
    function test_ReceiveFunction() public {
        uint256 initialBalance = address(treasuryProxy).balance;

        // Send ETH directly to the contract
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        (bool success,) = address(treasuryProxy).call{value: 5 ether}("");
        assertTrue(success, "Should accept ETH transfers");

        assertEq(address(treasuryProxy).balance, initialBalance + 5 ether, "Should receive ETH");
    }

    // Test upgrade scheduling and execution
    function test_ScheduleAndExecuteUpgrade() public {
        vm.warp(365 days);

        bytes memory data = abi.encodeCall(Treasury.initialize, (timelock, multisig, startOffset, vestingDuration));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Treasury.sol", data));
        treasuryProxy = Treasury(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(treasuryProxy) == implAddressV1);

        // Verify gnosis multisig has the required role
        assertTrue(treasuryProxy.hasRole(treasuryProxy.UPGRADER_ROLE(), multisig));

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "Treasury.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("TreasuryV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(multisig);
        treasuryProxy.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for Treasury)
        vm.warp(block.timestamp + UPGRADE_TIMELOCK_DURATION + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        TreasuryV2 treasuryProxyV2 = TreasuryV2(proxy);
        assertEq(treasuryProxyV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(treasuryProxyV2.hasRole(treasuryProxyV2.UPGRADER_ROLE(), multisig), "Lost UPGRADER_ROLE");
    }

    // Test upgrade scheduling failures
    function test_ScheduleUpgradeFailures() public {
        // Non-upgrader should not be able to schedule
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), alice, UPGRADER_ROLE
            )
        );
        treasuryProxy.scheduleUpgrade(address(0x1234));

        // Zero address should revert
        vm.prank(multisig);
        vm.expectRevert(ITREASURY.ZeroAddress.selector);
        treasuryProxy.scheduleUpgrade(address(0));

        // Test upgrade without scheduling
        Treasury newImpl = new Treasury();
        vm.prank(multisig);
        vm.expectRevert(ITREASURY.UpgradeNotScheduled.selector);
        treasuryProxy.upgradeToAndCall(address(newImpl), "");
    }

    // Test fuzz: releasable amount at different timestamps
    function test_FuzzReleasableAmount(uint256 timeElapsed) public {
        // Bound time to reasonable range (0 to 10 years)
        timeElapsed = bound(timeElapsed, 0, 3650 days);

        // Warp to the test time
        vm.warp(startTimestamp + timeElapsed);

        // Calculate expected amount based on vesting formula
        uint256 expectedEth;
        uint256 expectedTokens;

        if (timeElapsed == 0) {
            expectedEth = 0;
            expectedTokens = 0;
        } else if (timeElapsed >= vestingDuration) {
            expectedEth = 100 ether;
            expectedTokens = 1_000_000e18;
        } else {
            expectedEth = (100 ether * timeElapsed) / vestingDuration;
            expectedTokens = (1_000_000e18 * timeElapsed) / vestingDuration;
        }

        assertEq(treasuryProxy.releasable(), expectedEth, "ETH releasable calculation incorrect");
        assertEq(
            treasuryProxy.releasable(address(tokenProxy)), expectedTokens, "Token releasable calculation incorrect"
        );
    }

    // Test precise vesting calculation at 1/3 of vesting period
    function test_PreciseVestingCalculation() public {
        // Warp to 1/3 through vesting period
        vm.warp(startTimestamp + vestingDuration / 3);

        // Calculate exact expected amounts
        uint256 expectedEth = (100 ether * vestingDuration / 3) / vestingDuration;
        uint256 expectedTokens = (1_000_000e18 * vestingDuration / 3) / vestingDuration;

        // Check releasable
        assertEq(treasuryProxy.releasable(), expectedEth, "ETH releasable calculation incorrect at 1/3 vesting");
        assertEq(
            treasuryProxy.releasable(address(tokenProxy)),
            expectedTokens,
            "Token releasable calculation incorrect at 1/3 vesting"
        );
    }

    // Test upgradeTimelockRemaining with no upgrade scheduled
    function test_UpgradeTimelockRemainingNoUpgrade() public {
        assertEq(treasuryProxy.upgradeTimelockRemaining(), 0, "Should be 0 with no scheduled upgrade");
    }

    // Test upgradeToAndCall without timelock
    function test_UpgradeToAndCallRevertOnNoUpgrade() public {
        Treasury newImpl = new Treasury();
        vm.prank(multisig);
        vm.expectRevert(ITREASURY.UpgradeNotScheduled.selector);
        treasuryProxy.upgradeToAndCall(address(newImpl), "");
    }

    // Test: RevertInitializeTwice
    function test_Revert_CantInitializeTwice() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        treasuryProxy.initialize(timelock, multisig, startOffset, vestingDuration);
    }

    function test_Revert_EmergencyWithdrawWithZeroToken() public {
        vm.prank(timelock);
        vm.expectRevert(ITREASURY.ZeroAddress.selector);
        treasuryProxy.emergencyWithdrawToken(address(0));
    }

    function test_Revert_EmergencyWithdrawTokenZeroBalance() public {
        // Deploy a new token that the treasury doesn't have any balance of
        TokenMock emptyToken = new TokenMock("Empty Token", "EMPTY");

        vm.prank(timelock);
        vm.expectRevert(ITREASURY.ZeroBalance.selector);
        treasuryProxy.emergencyWithdrawToken(address(emptyToken));
    }

    function test_EmergencyWithdrawWhenPaused() public {
        // Pause the contract
        vm.startPrank(timelock);
        treasuryProxy.pause();

        // Emergency withdraw should still work when paused
        uint256 balance = address(treasuryProxy).balance;

        treasuryProxy.emergencyWithdrawEther();

        assertEq(address(treasuryProxy).balance, 0, "Treasury should have no ETH left");
        assertEq(timelock.balance, balance, "Timelock should receive the ETH");

        // Token withdrawal should also work when paused
        tokenProxy.mint(timelock, 1000e18); // Add this line to mint tokens to timelock

        tokenProxy.transfer(address(treasuryProxy), 1000e18);

        treasuryProxy.emergencyWithdrawToken(address(tokenProxy));

        assertEq(tokenProxy.balanceOf(address(treasuryProxy)), 0, "Treasury should have no tokens left");
        vm.stopPrank();
    }

    function test_MultipleEmergencyWithdrawals() public {
        // First withdraw all ETH
        vm.prank(timelock);
        treasuryProxy.emergencyWithdrawEther();

        // Add some ETH back to the contract
        vm.deal(address(treasuryProxy), 5 ether);

        // Withdraw again
        vm.prank(timelock);
        treasuryProxy.emergencyWithdrawEther();

        // Verify all ETH is gone
        assertEq(address(treasuryProxy).balance, 0, "Treasury should have no ETH left");

        // Similar test with tokens
        vm.prank(timelock);
        treasuryProxy.emergencyWithdrawToken(address(tokenProxy));

        // Transfer tokens back
        vm.prank(timelock);
        tokenProxy.transfer(address(treasuryProxy), 500e18);

        // Withdraw again
        vm.prank(timelock);
        treasuryProxy.emergencyWithdrawToken(address(tokenProxy));

        // Verify all tokens are gone
        assertEq(tokenProxy.balanceOf(address(treasuryProxy)), 0, "Treasury should have no tokens left");
    }

    function test_VestingAtExactStartTime() public {
        // Warp to exact start time
        vm.warp(startTimestamp);

        // At start time, vestedAmount should be 0
        assertEq(treasuryProxy.vestedAmount(block.timestamp), 0, "Vesting at start time should be 0");

        // Warp to exactly 1 second after start
        vm.warp(startTimestamp + 1);

        // Calculate expected tiny vested amount for 1 second
        uint256 expectedETH = (100 ether * 1) / vestingDuration;
        uint256 expectedTokens = (1_000_000e18 * 1) / vestingDuration;

        assertEq(treasuryProxy.vestedAmount(block.timestamp), expectedETH, "Exact calculation at start+1 incorrect");
        assertEq(
            treasuryProxy.vestedAmount(address(tokenProxy), block.timestamp),
            expectedTokens,
            "Exact token calculation at start+1 incorrect"
        );
    }

    function test_UpgradeTimelockExpired() public {
        // Deploy a new implementation
        Treasury newImpl = new Treasury();

        // Schedule upgrade
        vm.prank(multisig);
        treasuryProxy.scheduleUpgrade(address(newImpl));

        // Verify timelock is active
        assertGt(treasuryProxy.upgradeTimelockRemaining(), 0, "Timelock should be active");

        // Warp past the timelock period
        vm.warp(block.timestamp + UPGRADE_TIMELOCK_DURATION + 1);

        // Verify timelock has expired (branch we're missing)
        assertEq(treasuryProxy.upgradeTimelockRemaining(), 0, "Timelock should have expired");
    }

    function test_PendingUpgradeFullVerification() public {
        // Before any upgrade is scheduled
        (address impl, uint64 scheduledTime, bool exists) = treasuryProxy.pendingUpgrade();
        assertEq(impl, address(0), "Implementation should be zero when no upgrade scheduled");
        assertEq(scheduledTime, 0, "Schedule time should be zero when no upgrade scheduled");
        assertFalse(exists, "Exists should be false when no upgrade scheduled");

        // After scheduling
        Treasury newImpl = new Treasury();
        vm.prank(multisig);
        uint64 currentTime = uint64(block.timestamp);
        treasuryProxy.scheduleUpgrade(address(newImpl));

        (impl, scheduledTime, exists) = treasuryProxy.pendingUpgrade();
        assertEq(impl, address(newImpl), "Implementation address should match");
        assertEq(scheduledTime, currentTime, "Scheduled time should match");
        assertTrue(exists, "Exists should be true");
    }

    function test_UpgradeImplementationMismatch() public {
        // Schedule an upgrade to one implementation
        Treasury scheduledImpl = new Treasury();

        vm.prank(multisig);
        treasuryProxy.scheduleUpgrade(address(scheduledImpl));

        // Warp past the timelock
        vm.warp(block.timestamp + UPGRADE_TIMELOCK_DURATION + 1);

        // Try to upgrade to a DIFFERENT implementation
        Treasury differentImpl = new Treasury();

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITREASURY.ImplementationMismatch.selector, address(scheduledImpl), address(differentImpl)
            )
        );
        treasuryProxy.upgradeToAndCall(address(differentImpl), "");
    }

    function test_UpgradeTimelockActive() public {
        // Schedule an upgrade
        Treasury newImpl = new Treasury();

        vm.prank(multisig);
        treasuryProxy.scheduleUpgrade(address(newImpl));

        // Try to upgrade immediately (without warping past the timelock)
        uint256 remainingTime = treasuryProxy.upgradeTimelockRemaining();

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ITREASURY.UpgradeTimelockActive.selector, remainingTime));
        treasuryProxy.upgradeToAndCall(address(newImpl), "");

        // Verify we can upgrade after waiting
        vm.warp(block.timestamp + UPGRADE_TIMELOCK_DURATION + 1);

        vm.prank(multisig);
        treasuryProxy.upgradeToAndCall(address(newImpl), "");
        assertEq(treasuryProxy.version(), 2, "Version should be 2 after upgrade");
    }
}
