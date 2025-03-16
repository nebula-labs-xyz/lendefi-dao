// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
// import {console2} from "forge-std/console2.sol";
import {LendefiGovernor} from "../../contracts/ecosystem/LendefiGovernor.sol"; // Path to your contract
import {LendefiGovernorV2} from "../../contracts/upgrades/LendefiGovernorV2.sol"; // Path to your contract
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

contract LendefiGovernorTest is BasicDeploy {
    event Initialized(address indexed src);

    event GovernanceSettingsUpdated(
        address indexed caller, uint256 votingDelay, uint256 votingPeriod, uint256 proposalThreshold
    );
    event GnosisSafeUpdated(address indexed oldGnosisSafe, address indexed newGnosisSafe);
    event UpgradeScheduled(
        address indexed scheduler, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );

    function setUp() public {
        vm.warp(365 days);
        deployTimelock();
        deployToken();

        deployEcosystem();
        deployGovernor();
        setupTimelockRoles();
        deployTreasury();
        setupInitialTokenDistribution();
        setupEcosystemRoles();
    }

    // Test: RevertInitialization
    function testRevertInitialization() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(gnosisSafe);
        vm.expectRevert(expError); // contract already initialized
        govInstance.initialize(tokenInstance, timelockInstance, guardian);
    }

    // Test: RightOwner
    function test_RightOwner() public {
        assertTrue(govInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)) == true);
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
        assertEq(tokenInstance.balanceOf(address(treasuryInstance)), 27_400_000 ether - 1 ether);
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

    // Test: RevertDeployGovernor
    function testRevertDeployGovernorERC1967Proxy() public {
        TimelockControllerUpgradeable timelockContract;

        // Deploy implementation first
        LendefiGovernor implementation = new LendefiGovernor();

        // Create initialization data with zero address timelock
        bytes memory data = abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelockContract, guardian));

        // Expect revert with zero address error
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));

        // Try to deploy proxy with zero address timelock
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), data);
        assertFalse(address(proxy) == address(implementation));
    }

    // Test: _authorizeUpgrade with gnosisSafe permission
    function test_AuthorizeUpgrade() public {
        // upgrade Governor
        address proxy = address(govInstance);

        // First prepare the upgrade but don't apply it yet
        Options memory opts = Options({
            referenceContract: "LendefiGovernor.sol",
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

        // Get the implementation address without upgrading
        address newImpl = Upgrades.prepareUpgrade("LendefiGovernorV2.sol", opts);

        vm.startPrank(gnosisSafe);

        // Schedule the upgrade with our timelock mechanism
        govInstance.scheduleUpgrade(newImpl);

        // Wait for the timelock period to expire
        vm.warp(block.timestamp + 3 days + 1);

        // Now perform the actual upgrade
        govInstance.upgradeToAndCall(newImpl, "");

        // Verify the upgrade was successful
        LendefiGovernorV2 govInstanceV2 = LendefiGovernorV2(payable(proxy));
        assertEq(govInstanceV2.uupsVersion(), 2);
        vm.stopPrank();
    }

    // Test: _authorizeUpgrade unauthorized
    // Test: _authorizeUpgrade unauthorized
    function testRevert_UpgradeUnauthorized() public {
        // Create a new implementation contract directly
        LendefiGovernor newImplementation = new LendefiGovernor();

        // Update to use standard AccessControlUnauthorizedAccount error
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, UPGRADER_ROLE);
        vm.expectRevert(expError);
        vm.prank(alice);
        // Use a low-level call with the correct function selector
        (bool success,) = address(govInstance).call(
            abi.encodeWithSelector(0x3659cfe6, address(newImplementation)) // upgradeTo(address)
        );
        assertFalse(success);
    }

    // Test: Default constants match expected values
    function testDefaultConstants() public {
        assertEq(govInstance.DEFAULT_VOTING_DELAY(), 7200);
        assertEq(govInstance.DEFAULT_VOTING_PERIOD(), 50400);
        assertEq(govInstance.DEFAULT_PROPOSAL_THRESHOLD(), 20_000 ether);
    }

    // Test: Schedule upgrade with zero address
    function testRevert_ScheduleUpgradeZeroAddress() public {
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        govInstance.scheduleUpgrade(address(0));
    }

    // Test: Schedule upgrade unauthorized
    function testRevert_ScheduleUpgradeUnauthorized() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, UPGRADER_ROLE);
        vm.prank(alice);
        vm.expectRevert(expError);
        govInstance.scheduleUpgrade(address(0x1234));
    }

    // Test: Upgrade timelock remaining with no upgrade scheduled
    function testUpgradeTimelockRemainingNoUpgrade() public {
        assertEq(govInstance.upgradeTimelockRemaining(), 0, "Should be 0 with no scheduled upgrade");
    }

    // Test: Upgrade timelock remaining after scheduling
    function testUpgradeTimelockRemaining() public {
        address newImplementation = address(0x1234);

        // Schedule upgrade
        vm.prank(gnosisSafe);
        govInstance.scheduleUpgrade(newImplementation);

        // Check remaining time right after scheduling
        uint256 timelock = govInstance.UPGRADE_TIMELOCK_DURATION();
        assertEq(govInstance.upgradeTimelockRemaining(), timelock, "Full timelock should remain");

        // Warp forward 1 day and check again
        vm.warp(block.timestamp + 1 days);
        assertEq(govInstance.upgradeTimelockRemaining(), timelock - 1 days, "Should have 2 days remaining");

        // Warp past timelock
        vm.warp(block.timestamp + 2 days);
        assertEq(govInstance.upgradeTimelockRemaining(), 0, "Should be 0 after timelock expires");
    }

    // Test: Attempt upgrade when timelock is active
    function testRevert_UpgradeTimelockActive() public {
        address newImplementation = address(0x1234);

        // Schedule upgrade
        vm.prank(gnosisSafe);
        govInstance.scheduleUpgrade(newImplementation);

        // Try to upgrade immediately
        vm.prank(gnosisSafe);
        uint256 remaining = govInstance.upgradeTimelockRemaining();
        vm.expectRevert(abi.encodeWithSelector(LendefiGovernor.UpgradeTimelockActive.selector, remaining));

        // Use low-level call to attempt upgrade
        (bool success,) = address(govInstance).call(
            abi.encodeWithSelector(0x3659cfe6, newImplementation) // upgradeTo(address)
        );
        assertFalse(success);
    }

    // Test: Attempt upgrade without scheduling
    function testRevert_UpgradeNotScheduled() public {
        address newImplementation = address(0x1234);

        // Try to upgrade without scheduling
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSelector(LendefiGovernor.UpgradeNotScheduled.selector));

        // Use low-level call to attempt upgrade
        (bool success,) = address(govInstance).call(
            abi.encodeWithSelector(0x3659cfe6, newImplementation) // upgradeTo(address)
        );
        assertFalse(success);
    }

    // Test: Attempt upgrade with implementation mismatch
    function testRevert_ImplementationMismatch() public {
        address scheduledImpl = address(0x1234);
        address wrongImpl = address(0x5678);

        // Schedule upgrade
        vm.prank(gnosisSafe);
        govInstance.scheduleUpgrade(scheduledImpl);

        // Wait for timelock to expire
        vm.warp(block.timestamp + govInstance.UPGRADE_TIMELOCK_DURATION() + 1);

        // Try to upgrade with different implementation
        vm.prank(gnosisSafe);
        vm.expectRevert(
            abi.encodeWithSelector(LendefiGovernor.ImplementationMismatch.selector, scheduledImpl, wrongImpl)
        );

        // Use low-level call to attempt upgrade
        (bool success,) = address(govInstance).call(
            abi.encodeWithSelector(0x3659cfe6, wrongImpl) // upgradeTo(address)
        );
        assertFalse(success);
    }

    function test_UpgradeTimelockPeriod() public {
        address newImplementation = address(0x1234);

        vm.prank(gnosisSafe);
        govInstance.scheduleUpgrade(newImplementation);

        assertEq(govInstance.upgradeTimelockRemaining(), 3 days);

        // Move forward one day
        vm.warp(block.timestamp + 1 days);
        assertEq(govInstance.upgradeTimelockRemaining(), 2 days);

        // Move past timelock
        vm.warp(block.timestamp + 2 days);
        assertEq(govInstance.upgradeTimelockRemaining(), 0);
    }
    // Test: Complete successful timelock upgrade process

    function testSuccessfulTimelockUpgrade() public {
        deployGovernorUpgrade();
    }

    // Test: Reschedule an upgrade
    function testRescheduleUpgrade() public {
        address firstImpl = address(0x1234);
        address secondImpl = address(0x5678);

        // Schedule first upgrade
        vm.prank(gnosisSafe);
        govInstance.scheduleUpgrade(firstImpl);

        // Verify first implementation is scheduled
        (address scheduledImpl,, bool exists) = govInstance.pendingUpgrade();
        assertTrue(exists);
        assertEq(scheduledImpl, firstImpl);

        // Schedule second upgrade (should replace the first one)
        vm.prank(gnosisSafe);
        govInstance.scheduleUpgrade(secondImpl);

        // Verify second implementation replaced the first
        (scheduledImpl,, exists) = govInstance.pendingUpgrade();
        assertTrue(exists);
        assertEq(scheduledImpl, secondImpl, "Second implementation should replace first");
    }

    // Test: Schedule upgrade with proper permissions
    function test_ScheduleUpgrade() public {
        address newImplementation = address(0x1234);

        vm.expectEmit(true, true, true, true);
        emit UpgradeScheduled(
            gnosisSafe,
            newImplementation,
            uint64(block.timestamp),
            uint64(block.timestamp + govInstance.UPGRADE_TIMELOCK_DURATION())
        );
        vm.prank(gnosisSafe);
        govInstance.scheduleUpgrade(newImplementation);

        // Check the pending upgrade is properly set
        (address impl, uint64 scheduledTime, bool exists) = govInstance.pendingUpgrade();
        assertTrue(exists, "Upgrade should be scheduled");
        assertEq(impl, newImplementation, "Implementation address should match");
        assertEq(scheduledTime, block.timestamp, "Scheduled time should match current time");
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

    function deployToken() internal {
        bytes memory data =
            abi.encodeCall(GovernanceToken.initializeUUPS, (guardian, address(timelockInstance), gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
    }

    function deployEcosystem() internal {
        bytes memory data =
            abi.encodeCall(Ecosystem.initialize, (address(tokenInstance), address(timelockInstance), guardian, pauser));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Ecosystem.sol", data));
        ecoInstance = Ecosystem(proxy);
        address ecoImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(ecoInstance) == ecoImplementation);
    }

    function deployGovernor() internal {
        bytes memory data = abi.encodeCall(
            LendefiGovernor.initialize,
            (tokenInstance, TimelockControllerUpgradeable(payable(address(timelockInstance))), gnosisSafe)
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
        bytes memory data =
            abi.encodeCall(Treasury.initialize, (guardian, address(timelockInstance), gnosisSafe, 180 days, 1095 days));
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
        uint256 guardianBal = tokenInstance.balanceOf(guardian);

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 27_400_000 ether);
        assertEq(guardianBal, 600_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal + guardianBal);
    }

    function setupEcosystemRoles() internal {
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(MANAGER_ROLE, managerAdmin);
        assertEq(govInstance.uupsVersion(), 1);
    }
}
