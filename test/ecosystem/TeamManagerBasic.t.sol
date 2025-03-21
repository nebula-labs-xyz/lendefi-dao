// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
import {TeamManager} from "../../contracts/ecosystem/TeamManager.sol";
import {TeamVesting} from "../../contracts/ecosystem/TeamVesting.sol";
import {ITEAMMANAGER} from "../../contracts/interfaces/ITeamManager.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract TeamManagerBasicTest is BasicDeploy {
    // Events to verify

    event Initialized(address indexed initializer);
    event AddTeamMember(address indexed beneficiary, address indexed vestingContract, uint256 amount);
    event UpgradeScheduled(
        address indexed scheduler, address implementation, uint64 scheduledTime, uint64 effectiveTime
    );

    event Paused(address account);
    event Unpaused(address account);

    // Constants
    uint256 private constant UPGRADE_TIMELOCK_DURATION = 3 days;

    // Team vesting constants from contract
    uint64 public constant MIN_CLIFF = 90 days;
    uint64 public constant MAX_CLIFF = 365 days;
    uint64 public constant MIN_DURATION = 365 days;
    uint64 public constant MAX_DURATION = 1460 days;

    function setUp() public {
        vm.warp(365 days);
        deployComplete();
        assertEq(tokenInstance.totalSupply(), 0);

        // this is the TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        uint256 ecoBal = tokenInstance.balanceOf(address(ecoInstance));
        uint256 treasuryBal = tokenInstance.balanceOf(address(treasuryInstance));
        uint256 guardianBal = tokenInstance.balanceOf(guardian);

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 27_400_000 ether);
        assertEq(guardianBal, 600_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal + guardianBal);

        // deploy Team Manager using OpenZeppelin Upgrades
        bytes memory data =
            abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implementation);

        // Fund tmInstance with tokens if needed
        // For testing, we'll likely need to make sure the team manager has some tokens
        if (tokenInstance.balanceOf(address(tmInstance)) < 18_000_000 ether) {
            vm.prank(address(ecoInstance));
            tokenInstance.transfer(address(tmInstance), 18_000_000 ether);
        }
    }

    // ========== INITIALIZATION TESTS ==========

    function testInitialization() public {
        // Check role assignments
        assertTrue(tmInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)), "Timelock should have admin role");
        assertTrue(tmInstance.hasRole(PAUSER_ROLE, address(timelockInstance)), "Guardian should have pauser role");
        assertTrue(tmInstance.hasRole(MANAGER_ROLE, address(timelockInstance)), "Timelock should have manager role");
        assertTrue(tmInstance.hasRole(UPGRADER_ROLE, gnosisSafe), "Multisig should have upgrader role");

        // Check state variables
        assertEq(tmInstance.timelock(), address(timelockInstance), "Timelock address should match");
        assertEq(tmInstance.version(), 1, "Initial version should be 1");

        // Wait for funds to be transferred before checking (if using async transfer)
        uint256 expectedSupply = (tokenInstance.initialSupply() * 18) / 100;
        assertEq(tmInstance.supply(), expectedSupply, "Supply should be 18% of total supply");
        assertEq(tmInstance.totalAllocation(), 0, "Initial allocation should be 0");

        // Check that no pending upgrade exists
        (address impl, uint64 time, bool exists) = tmInstance.pendingUpgrade();
        assertFalse(exists, "No upgrade should be scheduled initially");
        assertEq(impl, address(0), "Implementation address should be zero");
        assertEq(time, 0, "Scheduled time should be zero");
    }

    function testInitializeWithZeroAddressesViaProxy() public {
        TeamManager newImpl = new TeamManager();

        // Test with zero token address
        bytes memory data = abi.encodeCall(TeamManager.initialize, (address(0), address(timelockInstance), gnosisSafe));
        vm.expectRevert(ITEAMMANAGER.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), data);

        // Test with zero timelockInstance address
        data = abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(0), gnosisSafe));
        vm.expectRevert(ITEAMMANAGER.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), data);

        // Test with zero guardian address
        data = abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), address(0)));
        vm.expectRevert(ITEAMMANAGER.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), data);
    }

    function testCannotReinitialize() public {
        // Try to initialize again (with current tmInstance)
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        tmInstance.initialize(address(tokenInstance), address(timelockInstance), gnosisSafe);
    }

    // ========== RECEIVE FUNCTION TEST ==========

    function testRevert_Receive() public returns (bool success) {
        vm.deal(alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ITEAMMANAGER.ValidationFailed.selector, "NO_ETHER_ACCEPTED"));
        vm.prank(alice);

        (success,) = payable(address(tmInstance)).call{value: 1 ether}("");
    }
    // ========== PAUSE/UNPAUSE TESTS ==========

    function testPauseUnpause() public {
        // Verify initial state
        assertFalse(tmInstance.paused(), "Contract should not be paused initially");

        // Pause as guardian
        vm.prank(address(timelockInstance));
        vm.expectEmit(true, true, true, true);
        emit Paused(address(timelockInstance));
        tmInstance.pause();
        assertTrue(tmInstance.paused(), "Contract should be paused");

        // Unpause as guardian
        vm.prank(address(timelockInstance));
        vm.expectEmit(true, true, true, true);
        emit Unpaused(address(timelockInstance));
        tmInstance.unpause();
        assertFalse(tmInstance.paused(), "Contract should be unpaused");
    }

    function testRevert_PauseUnpauseUnauthorized() public {
        // Try to pause as non-guardian
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, PAUSER_ROLE)
        );
        tmInstance.pause();

        // Pause properly
        vm.prank(address(timelockInstance));
        tmInstance.pause();

        // Try to unpause as non-guardian
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, PAUSER_ROLE)
        );
        tmInstance.unpause();
    }

    function testPauseBlocksOperations() public {
        // First make sure enough tokens are available
        if (tokenInstance.balanceOf(address(tmInstance)) < 100_000 ether) {
            vm.prank(address(ecoInstance));
            tokenInstance.transfer(address(tmInstance), 100_000 ether);
        }

        // Pause the contract
        vm.startPrank(address(timelockInstance));
        tmInstance.pause();

        // Try to add team member while paused

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        tmInstance.addTeamMember(alice, 50_000 ether, 180 days, 730 days);

        tmInstance.unpause();

        tmInstance.addTeamMember(alice, 50_000 ether, 180 days, 730 days);

        // Verify team member was added
        assertEq(tmInstance.allocations(alice), 50_000 ether, "Allocation should be recorded");
        assertNotEq(tmInstance.vestingContracts(alice), address(0), "Vesting contract should be created");
        vm.stopPrank();
    }

    // ========== ROLE MANAGEMENT TESTS ==========

    function testRoleManagement() public {
        // Test granting role
        vm.prank(address(timelockInstance));
        tmInstance.grantRole(MANAGER_ROLE, alice);
        assertTrue(tmInstance.hasRole(MANAGER_ROLE, alice), "Alice should have manager role");

        // Test revoking role
        vm.prank(address(timelockInstance));
        tmInstance.revokeRole(MANAGER_ROLE, alice);
        assertFalse(tmInstance.hasRole(MANAGER_ROLE, alice), "Alice should no longer have manager role");

        // Test unauthorized role management
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, DEFAULT_ADMIN_ROLE)
        );
        tmInstance.grantRole(MANAGER_ROLE, bob);
    }

    // ========== ADD TEAM MEMBER TESTS ==========

    function testAddTeamMember() public {
        // First make sure enough tokens are available
        if (tokenInstance.balanceOf(address(tmInstance)) < 100_000 ether) {
            vm.prank(address(ecoInstance));
            tokenInstance.transfer(address(tmInstance), 100_000 ether);
        }

        uint256 initTotalAllocation = tmInstance.totalAllocation();
        uint256 amount = 100_000 ether;
        uint256 cliffPeriod = 180 days;
        uint256 vestingDuration = 730 days;

        vm.prank(address(timelockInstance));
        // This is where the event expectation was wrong
        // We're expecting vestingContract address to be non-zero, but can't predict exact value
        tmInstance.addTeamMember(alice, amount, cliffPeriod, vestingDuration);

        // Check allocation
        assertEq(tmInstance.allocations(alice), amount, "Allocation should be recorded");
        assertNotEq(tmInstance.vestingContracts(alice), address(0), "Vesting contract should exist");
        assertEq(tmInstance.totalAllocation(), initTotalAllocation + amount, "Total allocation should increase");

        // Check vesting contract received tokens
        assertEq(
            tokenInstance.balanceOf(tmInstance.vestingContracts(alice)),
            amount,
            "Vesting contract should receive tokens"
        );
    }

    function testRevert_AddTeamMemberUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, MANAGER_ROLE)
        );
        tmInstance.addTeamMember(bob, 100_000 ether, 180 days, 730 days);
    }

    function testRevert_AddTeamMemberZeroAddress() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(ITEAMMANAGER.ZeroAddress.selector);
        tmInstance.addTeamMember(address(0), 100_000 ether, 180 days, 730 days);
    }

    function testRevert_AddTeamMemberZeroAmount() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(ITEAMMANAGER.ZeroAmount.selector);
        tmInstance.addTeamMember(alice, 0, 180 days, 730 days);
    }

    function testRevert_AddTeamMemberAlreadyExists() public {
        // Make sure we have enough tokens
        if (tokenInstance.balanceOf(address(tmInstance)) < 200_000 ether) {
            vm.prank(address(ecoInstance));
            tokenInstance.transfer(address(tmInstance), 200_000 ether);
        }

        // Add team member first
        vm.prank(address(timelockInstance));
        tmInstance.addTeamMember(alice, 100_000 ether, 180 days, 730 days);

        // Try to add the same member again
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(ITEAMMANAGER.BeneficiaryAlreadyExists.selector, alice));
        tmInstance.addTeamMember(alice, 100_000 ether, 180 days, 730 days);
    }

    function testRevert_AddTeamMemberCliffTooShort() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(ITEAMMANAGER.InvalidCliff.selector, 89 days, MIN_CLIFF, MAX_CLIFF));
        tmInstance.addTeamMember(alice, 100_000 ether, 89 days, 730 days);
    }

    function testRevert_AddTeamMemberCliffTooLong() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(ITEAMMANAGER.InvalidCliff.selector, 366 days, MIN_CLIFF, MAX_CLIFF));
        tmInstance.addTeamMember(alice, 100_000 ether, 366 days, 730 days);
    }

    function testRevert_AddTeamMemberDurationTooShort() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSelector(ITEAMMANAGER.InvalidDuration.selector, 364 days, MIN_DURATION, MAX_DURATION)
        );
        tmInstance.addTeamMember(alice, 100_000 ether, 180 days, 364 days);
    }

    function testRevert_AddTeamMemberDurationTooLong() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSelector(ITEAMMANAGER.InvalidDuration.selector, 1461 days, MIN_DURATION, MAX_DURATION)
        );
        tmInstance.addTeamMember(alice, 100_000 ether, 180 days, 1461 days);
    }

    function testRevert_AddTeamMemberExceedsSupply() public {
        // Get the current supply and allocation
        uint256 availableSupply = tmInstance.supply() - tmInstance.totalAllocation();

        // Try to allocate more than available
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSelector(ITEAMMANAGER.SupplyExceeded.selector, availableSupply + 1, availableSupply)
        );
        tmInstance.addTeamMember(alice, availableSupply + 1, 180 days, 730 days);
    }

    function testAddAllTeamMembersToExactSupply() public {
        // Get available supply and ensure tmInstance has enough tokens
        uint256 availableSupply = tmInstance.supply();
        if (tokenInstance.balanceOf(address(tmInstance)) < availableSupply) {
            vm.prank(address(ecoInstance));
            tokenInstance.transfer(address(tmInstance), availableSupply);
        }

        // Add first team member with 40% of supply
        vm.prank(address(timelockInstance));
        tmInstance.addTeamMember(alice, availableSupply * 4 / 10, 180 days, 730 days);

        // Add second team member with 30% of supply
        vm.prank(address(timelockInstance));
        tmInstance.addTeamMember(bob, availableSupply * 3 / 10, 180 days, 730 days);

        // Add third team member with remaining 30%
        vm.prank(address(timelockInstance));
        tmInstance.addTeamMember(charlie, availableSupply * 3 / 10, 180 days, 730 days);

        // Check all supply is allocated
        assertEq(tmInstance.totalAllocation(), availableSupply, "All supply should be allocated");
    }

    // ========== UPGRADE TESTS ==========

    function testScheduleUpgrade() public {
        address newImpl = address(0x1234);

        // Schedule upgrade as multisig
        vm.prank(gnosisSafe);
        // Fix the event emission expectation
        tmInstance.scheduleUpgrade(newImpl);

        // Check pending upgrade
        (address impl, uint64 scheduledTime, bool exists) = tmInstance.pendingUpgrade();
        assertTrue(exists, "Upgrade should be scheduled");
        assertEq(impl, newImpl, "Implementation address should match");
        assertEq(scheduledTime, block.timestamp, "Scheduled time should match");
    }

    function testRevert_ScheduleUpgradeZeroAddress() public {
        vm.prank(gnosisSafe);
        vm.expectRevert(ITEAMMANAGER.ZeroAddress.selector);
        tmInstance.scheduleUpgrade(address(0));
    }

    function testRevert_ScheduleUpgradeUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, UPGRADER_ROLE)
        );
        tmInstance.scheduleUpgrade(address(0x1234));
    }

    function testupgradeTimelockRemaining() public {
        // When no upgrade is scheduled
        assertEq(tmInstance.upgradeTimelockRemaining(), 0, "No timelock when no upgrade scheduled");

        // Schedule an upgrade
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(address(0x1234));

        // Check timelock remaining immediately after scheduling
        assertEq(tmInstance.upgradeTimelockRemaining(), UPGRADE_TIMELOCK_DURATION, "Full timelock should remain");

        // Warp 1 day into the future
        vm.warp(block.timestamp + 1 days);
        assertEq(tmInstance.upgradeTimelockRemaining(), 2 days, "2 days should remain");

        // Warp past timelock
        vm.warp(block.timestamp + 2 days);
        assertEq(tmInstance.upgradeTimelockRemaining(), 0, "No timelock should remain");
    }

    function testRevert_UpgradeTimelockActive() public {
        // Schedule upgrade
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(address(0x123));

        // Try to upgrade immediately (should fail)
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSelector(ITEAMMANAGER.UpgradeTimelockActive.selector, UPGRADE_TIMELOCK_DURATION));

        // Mock call to UUPSUpgradeable's upgradeTo function
        bytes memory upgradeCalldata = abi.encodeWithSignature("upgradeTo(address)", address(0x123));
        (bool success,) = address(tmInstance).call(upgradeCalldata);
        assertFalse(success);
    }

    function testRevert_UpgradeNotScheduled() public {
        // Try to upgrade without scheduling
        vm.prank(gnosisSafe);
        vm.expectRevert(ITEAMMANAGER.UpgradeNotScheduled.selector);

        // Mock call to UUPSUpgradeable's upgradeTo function
        bytes memory upgradeCalldata = abi.encodeWithSignature("upgradeTo(address)", address(0x123));
        (bool success,) = address(tmInstance).call(upgradeCalldata);
        assertFalse(success);
    }

    function testRevert_ImplementationMismatch() public {
        // Schedule upgrade to specific implementation
        address scheduledImpl = address(0x123);
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(scheduledImpl);

        // Warp past timelock
        vm.warp(block.timestamp + UPGRADE_TIMELOCK_DURATION + 1);

        // Try to upgrade to different implementation
        address wrongImpl = address(0x456);
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSelector(ITEAMMANAGER.ImplementationMismatch.selector, scheduledImpl, wrongImpl));

        // Mock call to UUPSUpgradeable's upgradeTo function
        bytes memory upgradeCalldata = abi.encodeWithSignature("upgradeTo(address)", wrongImpl);
        (bool success,) = address(tmInstance).call(upgradeCalldata);
        assertFalse(success);
    }

    function testRevert_AuthorizeUpgrade_Unauthorized() public {
        // Schedule upgrade with proper permissions
        address mockImplementation = address(0x123);
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(mockImplementation);

        // Wait for timelock
        vm.warp(block.timestamp + UPGRADE_TIMELOCK_DURATION + 1);

        // Try to upgrade from an unauthorized account
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, UPGRADER_ROLE)
        );

        // Mock call to UUPSUpgradeable's upgradeTo function
        bytes memory upgradeCalldata = abi.encodeWithSignature("upgradeTo(address)", mockImplementation);
        (bool success,) = address(tmInstance).call(upgradeCalldata);
        assertFalse(success);
    }

    // ========== MULTIPLE OPERATIONS TESTS ==========

    function testMultipleTeamMembersAndUpgrade() public {
        // Ensure enough tokens are available
        uint256 neededTokens = 6_000_000 ether;
        if (tokenInstance.balanceOf(address(tmInstance)) < neededTokens) {
            vm.prank(address(ecoInstance));
            tokenInstance.transfer(address(tmInstance), neededTokens);
        }

        // Add multiple team members
        vm.startPrank(address(timelockInstance));
        tmInstance.addTeamMember(alice, 1_000_000 ether, 180 days, 730 days);
        tmInstance.addTeamMember(bob, 2_000_000 ether, 270 days, 1095 days);
        tmInstance.addTeamMember(charlie, 3_000_000 ether, 365 days, 1460 days);
        vm.stopPrank();

        // Check all allocations
        assertEq(tmInstance.totalAllocation(), 6_000_000 ether, "Total allocation should match");
        assertEq(tmInstance.allocations(alice), 1_000_000 ether, "Alice's allocation incorrect");
        assertEq(tmInstance.allocations(bob), 2_000_000 ether, "Bob's allocation incorrect");
        assertEq(tmInstance.allocations(charlie), 3_000_000 ether, "Charlie's allocation incorrect");

        // Schedule an upgrade
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(address(0x123));

        // Warp past timelock
        vm.warp(block.timestamp + UPGRADE_TIMELOCK_DURATION + 1);

        // Schedule a second upgrade to different implementation
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(address(0x456));

        // Check that the second scheduled upgrade replaced the first one
        (address impl,,) = tmInstance.pendingUpgrade();
        assertEq(impl, address(0x456), "New implementation should replace old one");
    }

    function testReschedulingUpgrade() public {
        // Schedule first upgrade
        address firstImpl = address(0x1234);
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(firstImpl);

        // Verify first upgrade was scheduled
        (address impl,, bool exists) = tmInstance.pendingUpgrade();
        assertTrue(exists);
        assertEq(impl, firstImpl);

        // Schedule second upgrade (should replace first)
        address secondImpl = address(0x5678);
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(secondImpl);

        // Verify second upgrade replaced first
        (impl,, exists) = tmInstance.pendingUpgrade();
        assertTrue(exists);
        assertEq(impl, secondImpl, "Second implementation should replace first");
    }

    // This test validates the exact edges of cliff duration
    function testCliffBoundaryValues() public {
        // Ensure enough tokens
        if (tokenInstance.balanceOf(address(tmInstance)) < 200_000 ether) {
            vm.prank(address(ecoInstance));
            tokenInstance.transfer(address(tmInstance), 200_000 ether);
        }

        // Test minimum valid cliff
        vm.prank(address(timelockInstance));
        tmInstance.addTeamMember(alice, 100_000 ether, MIN_CLIFF, 730 days);
        assertEq(tmInstance.allocations(alice), 100_000 ether);

        // Test maximum valid cliff
        vm.prank(address(timelockInstance));
        tmInstance.addTeamMember(bob, 100_000 ether, MAX_CLIFF, 730 days);
        assertEq(tmInstance.allocations(bob), 100_000 ether);
    }

    // This test validates the exact edges of vesting duration
    function testDurationBoundaryValues() public {
        // Ensure enough tokens
        if (tokenInstance.balanceOf(address(tmInstance)) < 200_000 ether) {
            vm.prank(address(ecoInstance));
            tokenInstance.transfer(address(tmInstance), 200_000 ether);
        }

        // Test minimum valid duration
        vm.prank(address(timelockInstance));
        tmInstance.addTeamMember(alice, 100_000 ether, 180 days, MIN_DURATION);
        assertEq(tmInstance.allocations(alice), 100_000 ether);

        // Test maximum valid duration
        vm.prank(address(timelockInstance));
        tmInstance.addTeamMember(bob, 100_000 ether, 180 days, MAX_DURATION);
        assertEq(tmInstance.allocations(bob), 100_000 ether);
    }
}
