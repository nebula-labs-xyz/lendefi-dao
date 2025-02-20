// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
import {TeamManager} from "../../contracts/ecosystem/TeamManager.sol";

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

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 28_000_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal);

        // deploy Team Manager
        bytes memory data =
            abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implementation);
        vm.prank(guardian);
        treasuryInstance.grantRole(MANAGER_ROLE, address(timelockInstance));
    }

    //Test: RevertReceive
    function testRevertReceive() public returns (bool success) {
        vm.expectRevert(); // contract does not receive ether
        (success,) = payable(address(tmInstance)).call{value: 100 ether}("");
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
    function testRevertInitialize() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        tmInstance.initialize(address(timelockInstance), address(timelockInstance), guardian);
    }

    //Test: testPause
    function testPause() public {
        vm.prank(guardian);
        tmInstance.grantRole(PAUSER_ROLE, pauser);
        assertEq(tmInstance.paused(), false);
        vm.startPrank(pauser);
        tmInstance.pause();
        assertEq(tmInstance.paused(), true);
        tmInstance.unpause();
        assertEq(tmInstance.paused(), false);
        vm.stopPrank();
    }

    function testPauseUnpauseAccess() public {
        // Verify initial state
        assertFalse(tmInstance.paused());

        // Should revert when non-pauser tries to pause
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, PAUSER_ROLE)
        );
        tmInstance.pause();

        // Grant PAUSER_ROLE to pauser
        vm.prank(guardian);
        tmInstance.grantRole(PAUSER_ROLE, pauser);

        // Pauser should be able to pause
        vm.prank(pauser);
        tmInstance.pause();
        assertTrue(tmInstance.paused());

        // Should revert when trying to pause twice
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(pauser);
        vm.expectRevert(expError);
        tmInstance.pause();

        // Should revert when non-pauser tries to unpause
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, PAUSER_ROLE)
        );
        tmInstance.unpause();

        // Pauser should be able to unpause
        vm.prank(pauser);
        tmInstance.unpause();
        assertFalse(tmInstance.paused());

        // Should revert when trying to unpause again
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSignature("ExpectedPause()"));
        tmInstance.unpause();
    }

    function testPauseBlocksOperations() public {
        // Grant roles
        vm.startPrank(guardian);
        tmInstance.grantRole(PAUSER_ROLE, pauser);
        tmInstance.grantRole(MANAGER_ROLE, address(timelockInstance));
        vm.stopPrank();

        // Pause the contract
        vm.prank(pauser);
        tmInstance.pause();
        assertTrue(tmInstance.paused());

        // Try to add team member while paused
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError);
        tmInstance.addTeamMember(alice, 100 ether, 365 days, 730 days);

        // Unpause and verify operations resume
        vm.prank(pauser);
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

    function testPauserRoleManagement() public {
        // Should revert when non-admin tries to grant PAUSER_ROLE
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, DEFAULT_ADMIN_ROLE)
        );
        tmInstance.grantRole(PAUSER_ROLE, bob);

        // Admin should be able to grant PAUSER_ROLE
        vm.prank(guardian);
        tmInstance.grantRole(PAUSER_ROLE, alice);
        assertTrue(tmInstance.hasRole(PAUSER_ROLE, alice));

        // Admin should be able to revoke PAUSER_ROLE
        vm.prank(guardian);
        tmInstance.revokeRole(PAUSER_ROLE, alice);
        assertFalse(tmInstance.hasRole(PAUSER_ROLE, alice));
    }

    //Test: RevertAddTeamMemberBranch2
    function testRevertAddTeamMemberBranch1() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError); // access control violation
        tmInstance.addTeamMember(managerAdmin, 100 ether, 365 days, 730 days);
    }

    //Test: RevertAddTeamMemberBranch2
    function testRevertAddTeamMemberBranch2() public {
        assertEq(tmInstance.paused(), false);
        vm.prank(guardian);
        tmInstance.grantRole(PAUSER_ROLE, pauser);
        vm.prank(pauser);
        tmInstance.pause();
        assertEq(tmInstance.paused(), true);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError); // contract paused
        tmInstance.addTeamMember(managerAdmin, 100 ether, 365 days, 730 days);
    }

    // Test: RevertAddTeamMemberBranch3
    function testRevertAddTeamMemberBranch3() public {
        vm.prank(address(timelockInstance));
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "SUPPLY_LIMIT");
        vm.expectRevert(expError);
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

        vm.prank(guardian);
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
        assertEq(tokenInstance.balanceOf(address(treasuryInstance)), 28_000_000 ether - 500_000 ether);
    }

    function testAddTeamMemberValidations() public {
        // Setup roles
        vm.startPrank(guardian);
        tmInstance.grantRole(PAUSER_ROLE, pauser);
        tmInstance.grantRole(MANAGER_ROLE, address(timelockInstance));
        vm.stopPrank();

        // Test invalid cliff period
        vm.startPrank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("CustomError(string)", "INVALID_CLIFF"));
        tmInstance.addTeamMember(alice, 100 ether, 30 days, 730 days); // Too short cliff

        vm.expectRevert(abi.encodeWithSignature("CustomError(string)", "INVALID_CLIFF"));
        tmInstance.addTeamMember(alice, 100 ether, 400 days, 730 days); // Too long cliff

        // Test invalid duration period
        vm.expectRevert(abi.encodeWithSignature("CustomError(string)", "INVALID_DURATION"));
        tmInstance.addTeamMember(alice, 100 ether, 180 days, 180 days); // Too short duration

        vm.expectRevert(abi.encodeWithSignature("CustomError(string)", "INVALID_DURATION"));
        tmInstance.addTeamMember(alice, 100 ether, 180 days, 1500 days); // Too long duration

        // Test zero address beneficiary
        vm.expectRevert(abi.encodeWithSignature("CustomError(string)", "INVALID_BENEFICIARY"));
        tmInstance.addTeamMember(address(0), 100 ether, 180 days, 730 days);
        vm.stopPrank();
    }

    function testPreventDoubleAllocation() public {
        // Setup roles and initial allocation
        vm.prank(guardian);
        tmInstance.grantRole(MANAGER_ROLE, address(timelockInstance));

        // Setup treasury release
        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(tmInstance), 200 ether);

        // First allocation should succeed
        tmInstance.addTeamMember(alice, 100 ether, 180 days, 730 days);

        // Second allocation to same beneficiary should fail
        vm.expectRevert(abi.encodeWithSignature("CustomError(string)", "ALREADY_ADDED"));
        tmInstance.addTeamMember(alice, 100 ether, 180 days, 730 days);
        vm.stopPrank();
    }
}
