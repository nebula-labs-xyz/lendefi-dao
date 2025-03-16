// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
import {TeamManager} from "../../contracts/ecosystem/TeamManager.sol";
import {ITEAMMANAGER} from "../../contracts/interfaces/ITeamManager.sol";

contract TeamManagerTest is BasicDeploy {
    uint256 internal vmprimer = 365 days;

    event EtherReleased(address indexed to, uint256 amount);
    event ERC20Released(address indexed token, address indexed to, uint256 amount);

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

        // deploy Team Manager
        bytes memory data = abi.encodeCall(
            TeamManager.initialize, (address(tokenInstance), address(timelockInstance), guardian, gnosisSafe)
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implementation);
    }

    //Test: RevertReceive
    function testRevert_Receive() public returns (bool success) {
        vm.expectRevert(abi.encodeWithSignature("ValidationFailed(string)", "NO_ETHER_ACCEPTED")); // contract does not receive ether
        (success,) = payable(address(ecoInstance)).call{value: 100 ether}("");
    }

    function testReceiveFunction() public {
        // Test direct ETH transfer
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(tmInstance).call{value: 1 ether}("");
        assertFalse(success);

        // Verify no ETH was transferred
        assertEq(address(tmInstance).balance, 0);
        assertEq(alice.balance, 1 ether);

        // Test zero value transfer
        vm.prank(alice);
        (success,) = address(tmInstance).call{value: 0}("");
        assertFalse(success);

        // Test transfer with data
        vm.prank(alice);
        (success,) = address(tmInstance).call{value: 1 ether}("0x");
        assertFalse(success);
    }

    function testReceiveFallback() public {
        // Setup test accounts with ETH
        vm.deal(alice, 2 ether);

        vm.startPrank(alice);

        // Test sending ETH with empty calldata (calls receive)
        (bool success,) = address(tmInstance).call{value: 1 ether}("");
        assertFalse(success);

        // Test sending ETH with non-empty calldata (calls fallback)
        (success,) = address(tmInstance).call{value: 1 ether}(hex"dead");
        assertFalse(success);

        // Test sending with no ETH but with data
        (success,) = address(tmInstance).call(hex"dead");
        assertFalse(success);

        vm.stopPrank();

        // Verify contract has no ETH
        assertEq(address(tmInstance).balance, 0);
    }

    function testMultipleReceiveAttempts() public {
        // Setup multiple accounts
        address[] memory senders = new address[](3);
        senders[0] = alice;
        senders[1] = bob;
        senders[2] = charlie;

        // Give each account some ETH
        for (uint256 i = 0; i < senders.length; i++) {
            vm.deal(senders[i], 1 ether);

            // Try to send ETH
            vm.prank(senders[i]);
            (bool success,) = address(tmInstance).call{value: 0.5 ether}("");
            assertFalse(success);

            // Verify balances remained unchanged
            assertEq(address(senders[i]).balance, 1 ether);
        }

        // Verify contract has no ETH
        assertEq(address(tmInstance).balance, 0);
    }

    //Test: RevertInitialize
    function testRevert_Initialize() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        tmInstance.initialize(address(timelockInstance), address(timelockInstance), guardian, gnosisSafe);
    }

    function testInitializeWithZeroAddressesViaProxy() public {
        // Create new TeamManager implementation
        TeamManager teamManagerImpl = new TeamManager();

        // Test with zero token address
        bytes memory data =
            abi.encodeCall(TeamManager.initialize, (address(0), address(timelockInstance), guardian, gnosisSafe));
        vm.expectRevert(ITEAMMANAGER.ZeroAddress.selector);
        ERC1967Proxy proxy = new ERC1967Proxy(address(teamManagerImpl), data);
        TeamManager(payable(address(proxy)));

        // Test with zero timelock address
        data = abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(0), guardian, gnosisSafe));
        vm.expectRevert(ITEAMMANAGER.ZeroAddress.selector);
        ERC1967Proxy proxy1 = new ERC1967Proxy(address(teamManagerImpl), data);
        TeamManager(payable(address(proxy1)));

        // Test with zero guardian address
        data = abi.encodeCall(
            TeamManager.initialize, (address(tokenInstance), address(timelockInstance), address(0), gnosisSafe)
        );
        vm.expectRevert(ITEAMMANAGER.ZeroAddress.selector);
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(teamManagerImpl), data);
        TeamManager(payable(address(proxy2)));

        // Test with zero multisig address
        data = abi.encodeCall(
            TeamManager.initialize, (address(tokenInstance), address(timelockInstance), guardian, address(0))
        );
        vm.expectRevert(ITEAMMANAGER.ZeroAddress.selector);
        ERC1967Proxy proxy3 = new ERC1967Proxy(address(teamManagerImpl), data);
        TeamManager(payable(address(proxy3)));
    }

    //Test: testPause
    function testPause() public {
        vm.startPrank(guardian);
        assertEq(tmInstance.paused(), false);
        tmInstance.pause();
        assertEq(tmInstance.paused(), true);
        tmInstance.unpause();
        assertEq(tmInstance.paused(), false);
        vm.stopPrank();
    }

    function testRevert_PauseUnpauseAccess() public {
        // Verify initial state
        assertFalse(tmInstance.paused());

        // Should revert when non-pauser tries to pause
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, PAUSER_ROLE)
        );
        tmInstance.pause();

        // Pauser should be able to pause
        vm.prank(guardian);
        tmInstance.pause();
        assertTrue(tmInstance.paused());

        // Should revert when trying to pause twice
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(guardian);
        vm.expectRevert(expError);
        tmInstance.pause();

        // Should revert when non-pauser tries to unpause
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, PAUSER_ROLE)
        );
        tmInstance.unpause();

        // Pauser should be able to unpause
        vm.prank(guardian);
        tmInstance.unpause();
        assertFalse(tmInstance.paused());

        // Should revert when trying to unpause again
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSignature("ExpectedPause()"));
        tmInstance.unpause();
    }

    function testPauseBlocksOperations() public {
        // Pause the contract
        vm.prank(guardian);
        tmInstance.pause();
        assertTrue(tmInstance.paused());

        // Try to add team member while paused
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError);
        tmInstance.addTeamMember(alice, 100 ether, 365 days, 730 days);

        // Unpause and verify operations resume
        vm.prank(guardian);
        tmInstance.unpause();
        assertFalse(tmInstance.paused());

        // Setup treasury release
        // vm.roll(block.timestamp + 365 days);
        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(tmInstance), 100 ether);

        // Should now be able to add team member
        tmInstance.addTeamMember(alice, 100 ether, 365 days, 730 days);
        vm.stopPrank();

        // Verify allocation was successful
        assertEq(tmInstance.allocations(alice), 100 ether);
    }

    function test_PauserRoleManagement() public {
        // Should revert when non-admin tries to grant PAUSER_ROLE
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, DEFAULT_ADMIN_ROLE)
        );
        tmInstance.grantRole(PAUSER_ROLE, bob);

        // Admin should be able to grant PAUSER_ROLE
        vm.prank(address(timelockInstance));
        tmInstance.grantRole(PAUSER_ROLE, alice);
        assertTrue(tmInstance.hasRole(PAUSER_ROLE, alice));

        // Admin should be able to revoke PAUSER_ROLE
        vm.prank(address(timelockInstance));
        tmInstance.revokeRole(PAUSER_ROLE, alice);
        assertFalse(tmInstance.hasRole(PAUSER_ROLE, alice));
    }

    //Test: RevertAddTeamMemberBranch2
    function testRevert_AddTeamMemberBranch1() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError); // access control violation
        tmInstance.addTeamMember(managerAdmin, 100 ether, 365 days, 730 days);
    }

    //Test: RevertAddTeamMemberBranch2
    function testRevert_AddTeamMemberBranch2() public {
        assertEq(tmInstance.paused(), false);
        vm.prank(guardian);
        tmInstance.pause();
        assertEq(tmInstance.paused(), true);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError); // contract paused
        tmInstance.addTeamMember(managerAdmin, 100 ether, 365 days, 730 days);
    }

    // Test: RevertAddTeamMemberBranch3
    function testRevert_AddTeamMemberBranch3() public {
        vm.expectRevert(
            abi.encodeWithSelector(ITEAMMANAGER.SupplyExceeded.selector, 10_000_000 ether, tmInstance.supply())
        );
        vm.prank(address(timelockInstance));
        tmInstance.addTeamMember(managerAdmin, 10_000_000 ether, 365 days, 730 days);
    }

    // Test: AddTeamMember Success
    function testAddTeamMember() public {
        // execute a DAO proposal adding team member
        // get some tokens to vote with
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;

        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(MANAGER_ROLE, managerAdmin);
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 200_000 ether);
        assertEq(tokenInstance.balanceOf(alice), 200_000 ether);

        vm.prank(alice);
        tokenInstance.delegate(alice);
        vm.prank(bob);
        tokenInstance.delegate(bob);
        vm.prank(charlie);
        tokenInstance.delegate(charlie);

        vm.roll(365 days);
        uint256 votes = govInstance.getVotes(alice, block.timestamp - 1 days);
        assertEq(votes, 200_000 ether);

        // create proposal
        // part1 - move amount from treasury to TeamManager instance
        // part2 - call TeamManager to addTeamMember
        bytes memory callData1 = abi.encodeWithSignature(
            "release(address,address,uint256)", address(tokenInstance), address(tmInstance), 500_000 ether
        );
        bytes memory callData2 = abi.encodeWithSignature(
            "addTeamMember(address,uint256,uint256,uint256)", managerAdmin, 500_000 ether, 365 days, 730 days
        );
        address[] memory to = new address[](2);
        to[0] = address(treasuryInstance);
        to[1] = address(tmInstance);
        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = callData1;
        calldatas[1] = callData2;

        vm.prank(alice);
        uint256 proposalId = govInstance.propose(to, values, calldatas, "Proposal #2: add managerAdmin as team member");

        vm.roll(365 days + 7200 + 1);
        IGovernor.ProposalState state1 = govInstance.state(proposalId);
        assertTrue(state1 == IGovernor.ProposalState.Active); //proposal active

        vm.prank(alice);
        govInstance.castVote(proposalId, 1);
        vm.prank(bob);
        govInstance.castVote(proposalId, 1);
        vm.prank(charlie);
        govInstance.castVote(proposalId, 1);

        vm.roll(365 days + 7200 + 50400 + 1);

        IGovernor.ProposalState state4 = govInstance.state(proposalId);
        assertTrue(state4 == IGovernor.ProposalState.Succeeded); //proposal succeded

        bytes32 descHash = keccak256(abi.encodePacked("Proposal #2: add managerAdmin as team member"));
        uint256 proposalId2 = govInstance.hashProposal(to, values, calldatas, descHash);
        assertEq(proposalId, proposalId2);

        govInstance.queue(to, values, calldatas, descHash);

        IGovernor.ProposalState state5 = govInstance.state(proposalId);
        assertTrue(state5 == IGovernor.ProposalState.Queued); //proposal queued

        uint256 eta = govInstance.proposalEta(proposalId);
        vm.warp(eta + 1);
        vm.roll(eta + 1);
        govInstance.execute(to, values, calldatas, descHash);
        IGovernor.ProposalState state7 = govInstance.state(proposalId);

        assertTrue(state7 == IGovernor.ProposalState.Executed); //proposal executed

        address vestingContract = tmInstance.vestingContracts(managerAdmin);
        assertEq(tokenInstance.balanceOf(vestingContract), 500_000 ether);
        assertEq(tokenInstance.balanceOf(address(treasuryInstance)), 27_400_000 ether - 500_000 ether);
    }

    function testRevert_AddTeamMemberZeroAddress() public {
        // Test invalid cliff period
        vm.startPrank(address(timelockInstance));

        // Test zero address beneficiary
        vm.expectRevert(ITEAMMANAGER.ZeroAddress.selector);
        tmInstance.addTeamMember(address(0), 100 ether, 180 days, 730 days);
        vm.stopPrank();
    }

    function testRevert_AddTeamMemberZeroAmount() public {
        // Test invalid cliff period
        vm.startPrank(address(timelockInstance));

        // Test zero address beneficiary
        vm.expectRevert(ITEAMMANAGER.ZeroAmount.selector);
        tmInstance.addTeamMember(alice, 0, 180 days, 730 days);
        vm.stopPrank();
    }

    function testRevert_AddTeamMember_CliffTooShort() public {
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(tmInstance), 100 ether);

        // Test specifically for cliff being too short
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(ITEAMMANAGER.InvalidCliff.selector, 80 days, 90 days, 365 days));
        tmInstance.addTeamMember(alice, 100 ether, 80 days, 730 days);
    }

    function testRevert_AddTeamMember_CliffTooLong() public {
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(tmInstance), 100 ether);

        // Test specifically for cliff being too long
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(ITEAMMANAGER.InvalidCliff.selector, 366 days, 90 days, 365 days));
        tmInstance.addTeamMember(alice, 100 ether, 366 days, 730 days);
    }

    function testRevert_AddTeamMember_DurationTooShort() public {
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(tmInstance), 100 ether);

        // Test specifically for duration being too short
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(ITEAMMANAGER.InvalidDuration.selector, 364 days, 365 days, 1460 days));
        tmInstance.addTeamMember(alice, 100 ether, 90 days, 364 days);
    }

    function testRevert_AddTeamMember_DurationTooLong() public {
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(tmInstance), 100 ether);

        // Test specifically for duration being too long
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(ITEAMMANAGER.InvalidDuration.selector, 1461 days, 365 days, 1460 days));
        tmInstance.addTeamMember(alice, 100 ether, 90 days, 1461 days);
    }

    function testRevert_PreventDoubleAllocation() public {
        // Setup roles and initial allocation

        // Setup treasury release
        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(tmInstance), 200 ether);

        // First allocation should succeed
        tmInstance.addTeamMember(alice, 100 ether, 180 days, 730 days);

        // Second allocation to same beneficiary should fail
        vm.expectRevert(abi.encodeWithSelector(ITEAMMANAGER.BeneficiaryAlreadyExists.selector, alice));
        tmInstance.addTeamMember(alice, 100 ether, 180 days, 730 days);
        vm.stopPrank();
    }

    function testRevert_ZeroAmount() public {
        // Setup treasury release for token availability
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(tmInstance), 100 ether);

        // Try to add team member with zero amount
        vm.prank(address(timelockInstance));
        vm.expectRevert(ITEAMMANAGER.ZeroAmount.selector);
        tmInstance.addTeamMember(alice, 0, 180 days, 730 days);
    }

    function testRevert_UpgradeTimelockActive() public {
        // Schedule an upgrade
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(address(0x1234));

        // Try to upgrade immediately (without waiting for timelock)
        uint256 remainingTime = tmInstance.upgradeTimelockRemaining();
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(ITEAMMANAGER.UpgradeTimelockActive.selector, remainingTime));

        // This is a mock call - in actual code the upgrade happens through upgradeToAndCall
        // but we want to test the _authorizeUpgrade internal function that throws UpgradeTimelockActive
        bytes memory upgradeCalldata =
            abi.encodeWithSelector(bytes4(keccak256("upgradeToAndCall(address,bytes)")), address(0x1234), "");
        (bool success,) = address(tmInstance).call(upgradeCalldata);
        assertFalse(success);
    }

    function testRevert_UpgradeNotScheduled() public {
        // Try to upgrade without scheduling first
        vm.prank(address(timelockInstance));
        vm.expectRevert(ITEAMMANAGER.UpgradeNotScheduled.selector);

        // This is a mock call since we can't directly call _authorizeUpgrade
        bytes memory upgradeCalldata =
            abi.encodeWithSelector(bytes4(keccak256("upgradeToAndCall(address,bytes)")), address(0x1234), "");
        (bool success,) = address(tmInstance).call(upgradeCalldata);
        assertFalse(success);
    }

    function testRevert_ImplementationMismatch() public {
        // Schedule upgrade to one implementation
        address scheduledImpl = address(0x1234);
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(scheduledImpl);

        // Warp past timelock period (3 days is the typical duration)
        vm.warp(block.timestamp + 3 days + 1);

        // Try to upgrade to a different implementation
        address differentImpl = address(0x5678);
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSelector(ITEAMMANAGER.ImplementationMismatch.selector, scheduledImpl, differentImpl)
        );

        // This is a mock call
        bytes memory upgradeCalldata =
            abi.encodeWithSelector(bytes4(keccak256("upgradeToAndCall(address,bytes)")), differentImpl, "");
        (bool success,) = address(tmInstance).call(upgradeCalldata);
        assertFalse(success);
    }

    function testUpgradeTimelockExpired() public {
        // Schedule an upgrade
        address newImpl = address(0x1234);
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(newImpl);

        // Verify timelock is active
        uint256 remaining = tmInstance.upgradeTimelockRemaining();
        assertTrue(remaining > 0, "Timelock should be active");

        // Warp past timelock expiration
        vm.warp(block.timestamp + 3 days + 1);

        // Check remaining time after expiration
        remaining = tmInstance.upgradeTimelockRemaining();
        assertEq(remaining, 0, "Timelock should have expired");
    }

    function testUpgradeTimelockActive() public {
        // Schedule an upgrade
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(address(0x1234));

        // Check when timelock is active but not yet expired
        uint256 remaining = tmInstance.upgradeTimelockRemaining();

        // Should return non-zero value
        assertEq(remaining, 3 days, "Should return exactly the remaining time");

        // Warp to middle of timelock period
        vm.warp(block.timestamp + 1 days);

        // Check again - should be less now
        remaining = tmInstance.upgradeTimelockRemaining();
        assertEq(remaining, 2 days, "Should return updated remaining time");
    }

    function testReschedulingUpgrade() public {
        // Schedule first upgrade
        address firstImpl = address(0x1234);
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(firstImpl);

        // Verify it was scheduled
        (address impl,, bool exists) = tmInstance.pendingUpgrade();
        assertTrue(exists);
        assertEq(impl, firstImpl);

        // Schedule second upgrade (should replace first)
        address secondImpl = address(0x5678);
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(secondImpl);

        // Verify second one replaced first
        (impl,, exists) = tmInstance.pendingUpgrade();
        assertTrue(exists);
        assertEq(impl, secondImpl, "Second implementation should replace first");
    }

    function testRevert_OnlyUpgraderCanSchedule() public {
        address mockImplementation = address(0xABCD);

        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, UPGRADER_ROLE);

        vm.prank(guardian);
        vm.expectRevert(expError);
        tmInstance.scheduleUpgrade(mockImplementation);
    }

    function testRevert_UpgradeUnauthorizedAccount() public {
        // Deploy a mockImplementation for the upgrade
        address mockImplementation = address(0x1234);

        // Schedule upgrade with proper permissions
        vm.prank(gnosisSafe);
        tmInstance.scheduleUpgrade(mockImplementation);

        // Wait for timelock to pass
        vm.warp(block.timestamp + 3 days + 1);

        // The actual upgradeToAndCall would fail with AccessControl error
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, UPGRADER_ROLE)
        );

        vm.prank(alice);
        (bool success,) = address(tmInstance).call(abi.encodeWithSignature("upgradeTo(address)", address(0x1234)));
        // Since we're expecting a revert, success should be false
        assertFalse(success);
    }

    function testFullUpgradeProcess() public {
        deployTeamManagerUpgrade();
    }
}
