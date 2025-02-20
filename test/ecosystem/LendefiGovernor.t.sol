// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
// import {console2} from "forge-std/console2.sol";
import {LendefiGovernor} from "../../contracts/ecosystem/LendefiGovernor.sol"; // Path to your contract
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

contract LendefiGovernorTest is BasicDeploy {
    // TimelockControllerUpgradeable public timelock;
    // Set up initial conditions before each test

    function setUp() public {
        vm.warp(365 days);
        deployToken();
        deployEcosystem();
        deployTimelock();
        deployGovernor();
        setupTimelockRoles();
        deployTreasury();
        setupInitialTokenDistribution();
        setupEcosystemRoles();
    }

    // Test: RevertInitialization
    function testRevertInitialization() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        govInstance.initialize(tokenInstance, timelockInstance, guardian);
    }

    // Test: RightOwner
    function testRightOwner() public {
        assertTrue(govInstance.owner() == guardian);
    }

    // Test: CreateProposal
    function testCreateProposal() public {
        // get enough gov tokens to make proposal (20K)
        vm.deal(alice, 1 ether);
        address[] memory winners = new address[](1);
        winners[0] = alice;
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 20001 ether);
        assertEq(tokenInstance.balanceOf(alice), 20001 ether);

        vm.prank(alice);
        tokenInstance.delegate(alice);

        vm.roll(365 days);
        uint256 votes = govInstance.getVotes(alice, block.timestamp - 1 days);
        assertEq(votes, 20001 ether);

        //create proposal
        bytes memory callData = abi.encodeWithSignature("transfer(address,uint256)", managerAdmin, 1 ether);
        address[] memory to = new address[](1);
        to[0] = address(tokenInstance);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = callData;

        vm.prank(alice);
        uint256 proposalId = govInstance.propose(to, values, calldatas, "Proposal #1: send 1 token to managerAdmin");

        vm.roll(365 days + 7201);
        IGovernor.ProposalState state = govInstance.state(proposalId);
        assertTrue(state == IGovernor.ProposalState.Active); //proposal active
    }

    // Test: CastVote
    function testCastVote() public {
        // get enough gov tokens to make proposal (20K)
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
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

        //create proposal
        bytes memory callData = abi.encodeWithSignature("transfer(address,uint256)", managerAdmin, 1 ether);
        address[] memory to = new address[](1);
        to[0] = address(tokenInstance);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = callData;

        vm.prank(alice);
        uint256 proposalId = govInstance.propose(to, values, calldatas, "Proposal #1: send 1 token to managerAdmin");

        vm.roll(365 days + 7201);
        IGovernor.ProposalState state = govInstance.state(proposalId);
        assertTrue(state == IGovernor.ProposalState.Active); //proposal active

        vm.prank(alice);
        govInstance.castVote(proposalId, 1);
        vm.prank(bob);
        govInstance.castVote(proposalId, 1);
        vm.prank(charlie);
        govInstance.castVote(proposalId, 1);

        vm.roll(365 days + 7201 + 50401);

        // (uint256 against, uint256 forvotes, uint256 abstain) = govInstance
        //     .proposalVotes(proposalId);
        // console.log(against, forvotes, abstain);
        IGovernor.ProposalState state1 = govInstance.state(proposalId);
        assertTrue(state1 == IGovernor.ProposalState.Succeeded); //proposal succeeded
    }

    // Test: QueProposal
    function testQueProposal() public {
        // get enough gov tokens to make proposal (20K)
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
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

        //create proposal
        bytes memory callData = abi.encodeWithSignature("transfer(address,uint256)", managerAdmin, 1 ether);
        address[] memory to = new address[](1);
        to[0] = address(tokenInstance);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = callData;

        vm.prank(alice);
        uint256 proposalId = govInstance.propose(to, values, calldatas, "Proposal #1: send 1 token to managerAdmin");

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

        IGovernor.ProposalState state2 = govInstance.state(proposalId);
        assertTrue(state2 == IGovernor.ProposalState.Succeeded); //proposal succeded

        bytes32 descHash = keccak256(abi.encodePacked("Proposal #1: send 1 token to managerAdmin"));
        uint256 proposalId2 = govInstance.hashProposal(to, values, calldatas, descHash);

        assertEq(proposalId, proposalId2);

        govInstance.queue(to, values, calldatas, descHash);
        IGovernor.ProposalState state3 = govInstance.state(proposalId);
        assertTrue(state3 == IGovernor.ProposalState.Queued); //proposal queued
    }

    // Test: ExecuteProposal
    function testExecuteProposal() public {
        // get enough gov tokens to meet the quorum requirement (500K)
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
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

        //create proposal
        bytes memory callData =
            abi.encodeWithSignature("release(address,address,uint256)", address(tokenInstance), managerAdmin, 1 ether);

        address[] memory to = new address[](1);
        to[0] = address(treasuryInstance);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = callData;

        vm.prank(alice);
        uint256 proposalId = govInstance.propose(to, values, calldatas, "Proposal #1: send 1 token to managerAdmin");

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

        bytes32 descHash = keccak256(abi.encodePacked("Proposal #1: send 1 token to managerAdmin"));
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
        assertEq(tokenInstance.balanceOf(managerAdmin), 1 ether);
        assertEq(tokenInstance.balanceOf(address(treasuryInstance)), 28_000_000 ether - 1 ether);
    }

    // Test: ProposeQuorumDefeat
    function testProposeQuorumDefeat() public {
        // quorum at 1% is 500_000
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 30_000 ether);
        assertEq(tokenInstance.balanceOf(alice), 30_000 ether);

        vm.prank(alice);
        tokenInstance.delegate(alice);
        vm.prank(bob);
        tokenInstance.delegate(bob);
        vm.prank(charlie);
        tokenInstance.delegate(charlie);

        vm.roll(365 days);
        uint256 votes = govInstance.getVotes(alice, block.timestamp - 1 days);
        assertEq(votes, 30_000 ether);

        //create proposal
        bytes memory callData = abi.encodeWithSignature("transfer(address,uint256)", managerAdmin, 1 ether);
        address[] memory to = new address[](1);
        to[0] = address(tokenInstance);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = callData;

        vm.prank(alice);
        uint256 proposalId = govInstance.propose(to, values, calldatas, "Proposal #1: send 1 token to managerAdmin");

        vm.roll(365 days + 7201);
        IGovernor.ProposalState state = govInstance.state(proposalId);
        assertTrue(state == IGovernor.ProposalState.Active); //proposal active

        vm.prank(alice);
        govInstance.castVote(proposalId, 1);
        vm.prank(bob);
        govInstance.castVote(proposalId, 1);
        vm.prank(charlie);
        govInstance.castVote(proposalId, 1);

        vm.roll(365 days + 7201 + 50400);

        IGovernor.ProposalState state1 = govInstance.state(proposalId);
        assertTrue(state1 == IGovernor.ProposalState.Defeated); //proposal defeated
    }

    // Test: RevertCreateProposalBranch1
    function testRevertCreateProposalBranch1() public {
        bytes memory callData = abi.encodeWithSignature("transfer(address,uint256)", managerAdmin, 1 ether);
        address[] memory to = new address[](1);
        to[0] = address(tokenInstance);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = callData;

        bytes memory expError = abi.encodeWithSignature(
            "GovernorInsufficientProposerVotes(address,uint256,uint256)", managerAdmin, 0, 20000 ether
        );
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        govInstance.propose(to, values, calldatas, "Proposal #1: send 1 token to managerAdmin");
    }

    // Test: State_NonexistentProposal
    function testState_NonexistentProposal() public {
        bytes memory expError = abi.encodeWithSignature("GovernorNonexistentProposal(uint256)", 1);

        vm.expectRevert(expError);
        govInstance.state(1);
    }

    // Test: Executor
    function testExecutor() public {
        assertEq(govInstance.timelock(), address(timelockInstance));
    }

    // Test: UpdateVotingDelay
    function testUpdateVotingDelay() public {
        // Get enough gov tokens to meet the proposal threshold
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
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

        //create proposal
        bytes memory callData = abi.encodeWithSelector(govInstance.setVotingDelay.selector, 14400);

        address[] memory to = new address[](1);
        to[0] = address(govInstance);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = callData;

        string memory description = "Proposal #1: set voting delay to 14400";
        vm.prank(alice);
        uint256 proposalId = govInstance.propose(to, values, calldatas, description);

        vm.roll(365 days + 7201);
        IGovernor.ProposalState state = govInstance.state(proposalId);
        assertTrue(state == IGovernor.ProposalState.Active); //proposal active

        // Cast votes for alice
        vm.prank(alice);
        govInstance.castVote(proposalId, 1);

        // Cast votes for bob
        vm.prank(bob);
        govInstance.castVote(proposalId, 1);

        // Cast votes for charlie
        vm.prank(charlie);
        govInstance.castVote(proposalId, 1);

        vm.roll(365 days + 7200 + 50400 + 1);

        IGovernor.ProposalState state4 = govInstance.state(proposalId);
        assertTrue(state4 == IGovernor.ProposalState.Succeeded); //proposal succeded

        bytes32 descHash = keccak256(abi.encodePacked(description));
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
        assertEq(govInstance.votingDelay(), 14400);
    }

    // Test: RevertUpdateVotingDelay_Unauthorized
    function testRevertUpdateVotingDelay_Unauthorized() public {
        bytes memory expError = abi.encodeWithSignature("GovernorOnlyExecutor(address)", alice);

        vm.prank(alice);
        vm.expectRevert(expError);
        govInstance.setVotingDelay(14400);
    }

    //Test: VotingDelay
    function testVotingDelay() public {
        // Retrieve voting delay
        uint256 delay = govInstance.votingDelay();
        assertEq(delay, 7200);
    }

    //Test: VotingPeriod
    function testVotingPeriod() public {
        // Retrieve voting period
        uint256 period = govInstance.votingPeriod();
        assertEq(period, 50400);
    }

    //Test: Quorum
    function testQuorum() public {
        // Ensure the block number is valid and not in the future
        vm.roll(block.number + 1);
        // Retrieve quorum
        uint256 quorum = govInstance.quorum(block.number - 1);
        assertEq(quorum, 500000e18);
    }

    //Test: ProposalThreshold
    function testProposalThreshold() public {
        // Retrieve proposal threshold
        uint256 threshold = govInstance.proposalThreshold();
        assertEq(threshold, 20000e18);
    }

    //Test: InitialOwner
    function testInitialOwner() public {
        assertEq(govInstance.owner(), guardian);
        assertEq(govInstance.pendingOwner(), address(0));
    }

    //Test: TransferOwnership
    function testTransferOwnership() public {
        vm.prank(guardian);
        govInstance.transferOwnership(alice);

        // Check pending owner is set
        assertEq(govInstance.pendingOwner(), alice);
        // Check current owner hasn't changed
        assertEq(govInstance.owner(), guardian);
    }

    //Test: TransferOwnershipUnauthorized
    function testTransferOwnershipUnauthorized() public {
        // Try to transfer ownership from non-owner account
        vm.prank(address(0x9999));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x9999)));
        govInstance.transferOwnership(alice);
    }

    // Test: AcceptOwnership
    function testAcceptOwnership() public {
        // Set up pending ownership transfer
        vm.prank(guardian);
        govInstance.transferOwnership(alice);

        // Accept ownership as new owner
        vm.prank(alice);
        govInstance.acceptOwnership();

        // Verify ownership changed
        assertEq(govInstance.owner(), alice);
        assertEq(govInstance.pendingOwner(), address(0));
    }

    //Test: AcceptOwnershipUnauthorized
    function testAcceptOwnershipUnauthorized() public {
        // Set up pending ownership transfer
        vm.prank(guardian);
        govInstance.transferOwnership(alice);

        // Try to accept ownership from unauthorized account
        address unauthorized = address(0x9999);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", unauthorized));
        govInstance.acceptOwnership();
    }

    // Test: CancelTransferOwnership
    function testCancelTransferOwnership() public {
        // Set up pending ownership transfer
        vm.prank(guardian);
        govInstance.transferOwnership(alice);

        // Cancel transfer by setting pending owner to zero address
        vm.prank(guardian);
        govInstance.transferOwnership(address(0));

        // Verify pending owner is cleared
        assertEq(govInstance.pendingOwner(), address(0));
        // Verify current owner hasn't changed
        assertEq(govInstance.owner(), guardian);
    }

    // Test: Ownership Transfer
    function testOwnershipTransfer() public {
        // Transfer ownership to a new address
        address newOwner = address(0x123);
        vm.prank(guardian);
        govInstance.transferOwnership(newOwner);

        // Verify the new owner
        vm.prank(newOwner);
        govInstance.acceptOwnership();
        assertEq(govInstance.owner(), newOwner);

        // Attempt unauthorized ownership transfer and expect a revert
        vm.startPrank(address(0x9999991));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x9999991)));
        govInstance.transferOwnership(alice);
        vm.stopPrank();
    }

    // Test: Ownership Renouncement
    function testOwnershipRenouncement() public {
        // Renounce ownership
        vm.prank(guardian);
        govInstance.renounceOwnership();

        // Verify that the owner is set to the zero address
        assertEq(govInstance.owner(), address(0));

        // Attempt unauthorized ownership renouncement and expect a revert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        govInstance.renounceOwnership();
    }

    // Test: RevertDeployGovernor
    function testRevertDeployGovernorERC1967Proxy() public {
        TimelockControllerUpgradeable timelockContract;

        // Deploy implementation first
        LendefiGovernor implementation = new LendefiGovernor();

        // Create initialization data with zero address timelock
        bytes memory data = abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelockContract, guardian));

        // Expect revert with zero address error
        vm.expectRevert(abi.encodeWithSignature("CustomError(string)", "ZERO_ADDRESS_DETECTED"));

        // Try to deploy proxy with zero address timelock
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), data);
        assertFalse(address(proxy) == address(implementation));
    }

    function deployToken() internal {
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
    }

    function deployEcosystem() internal {
        bytes memory data = abi.encodeCall(Ecosystem.initialize, (address(tokenInstance), guardian, pauser));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Ecosystem.sol", data));
        ecoInstance = Ecosystem(proxy);
        address ecoImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(ecoInstance) == ecoImplementation);
    }

    function deployTimelock() internal {
        // ---- timelock deploy
        uint256 timelockDelay = 24 * 60 * 60;
        address[] memory temp = new address[](1);
        temp[0] = ethereum;
        TimelockControllerUpgradeable timelock = new TimelockControllerUpgradeable();

        bytes memory initData = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, timelockDelay, temp, temp, guardian
        );

        ERC1967Proxy proxy1 = new ERC1967Proxy(address(timelock), initData);
        timelockInstance = TimelockControllerUpgradeable(payable(address(proxy1)));
    }

    function deployGovernor() internal {
        bytes memory data = abi.encodeCall(
            LendefiGovernor.initialize,
            (tokenInstance, TimelockControllerUpgradeable(payable(address(timelockInstance))), guardian)
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", data));
        govInstance = LendefiGovernor(proxy);
        address govImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(govInstance) == govImplementation);
    }

    function setupTimelockRoles() internal {
        vm.startPrank(guardian);
        timelockInstance.revokeRole(PROPOSER_ROLE, ethereum);
        timelockInstance.revokeRole(EXECUTOR_ROLE, ethereum);
        timelockInstance.revokeRole(CANCELLER_ROLE, ethereum);
        timelockInstance.grantRole(PROPOSER_ROLE, address(govInstance));
        timelockInstance.grantRole(EXECUTOR_ROLE, address(govInstance));
        timelockInstance.grantRole(CANCELLER_ROLE, address(govInstance));
        vm.stopPrank();
    }

    function deployTreasury() internal {
        bytes memory data = abi.encodeCall(Treasury.initialize, (guardian, address(timelockInstance)));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Treasury.sol", data));
        treasuryInstance = Treasury(proxy);
        address tImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(treasuryInstance) == tImplementation);
        assertEq(tokenInstance.totalSupply(), 0);
    }

    function setupInitialTokenDistribution() internal {
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        uint256 ecoBal = tokenInstance.balanceOf(address(ecoInstance));
        uint256 treasuryBal = tokenInstance.balanceOf(address(treasuryInstance));

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 28_000_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal);
    }

    function setupEcosystemRoles() internal {
        vm.prank(guardian);
        ecoInstance.grantRole(MANAGER_ROLE, managerAdmin);
        assertEq(govInstance.uupsVersion(), 1);
    }
}
