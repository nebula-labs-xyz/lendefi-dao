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
    event UpgradeCancelled(address indexed canceller, address indexed implementation);
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
    function test__RightOwner() public {
        assertTrue(govInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)) == true);
    }

    // Test: CreateProposal
    function test_CreateProposal() public {
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
    function test_CastVote() public {
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
    function test_QueProposal() public {
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
    function test_ExecuteProposal() public {
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
    function test_ProposeQuorumDefeat() public {
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
    function test_State_NonexistentProposal() public {
        bytes memory expError = abi.encodeWithSignature("GovernorNonexistentProposal(uint256)", 1);

        vm.expectRevert(expError);
        govInstance.state(1);
    }

    // Test: Executor
    function test_Executor() public {
        assertEq(govInstance.timelock(), address(timelockInstance));
    }

    // Test: UpdateVotingDelay
    function test_UpdateVotingDelay() public {
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
    function test_VotingDelay() public {
        // Retrieve voting delay
        uint256 delay = govInstance.votingDelay();
        assertEq(delay, 7200);
    }

    //Test: VotingPeriod
    function test_VotingPeriod() public {
        // Retrieve voting period
        uint256 period = govInstance.votingPeriod();
        assertEq(period, 50400);
    }

    //Test: Quorum
    function test_Quorum() public {
        // Ensure the block number is valid and not in the future
        vm.roll(block.number + 1);
        // Retrieve quorum
        uint256 quorum = govInstance.quorum(block.number - 1);
        assertEq(quorum, 500000e18);
    }

    //Test: ProposalThreshold
    function test_ProposalThreshold() public {
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
    function test__AuthorizeUpgrade() public {
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
    function test_DefaultConstants() public {
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
    function test_UpgradeTimelockRemainingNoUpgrade() public {
        assertEq(govInstance.upgradeTimelockRemaining(), 0, "Should be 0 with no scheduled upgrade");
    }

    // Test: Upgrade timelock remaining after scheduling
    function test_UpgradeTimelockRemaining() public {
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

    function test__UpgradeTimelockPeriod() public {
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

    function test_SuccessfulTimelockUpgrade() public {
        deployGovernorUpgrade();
    }

    // Test: Reschedule an upgrade
    function test_RescheduleUpgrade() public {
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
    function test__ScheduleUpgrade() public {
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

    // Test for _authorizeUpgrade when upgrade not scheduled
    function testRevert_UpgradeNotScheduled() public {
        LendefiGovernorV2 implementation = new LendefiGovernorV2();

        // Don't schedule an upgrade first

        // Try upgrading directly - this should hit the internal _authorizeUpgrade function
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSelector(LendefiGovernor.UpgradeNotScheduled.selector));
        govInstance.upgradeToAndCall(address(implementation), "");
    }

    // Test for implementation mismatch in _authorizeUpgrade
    function testRevert_ImplementationMismatch() public {
        address scheduledImpl = address(0x1234);

        // Deploy a different implementation than what we'll schedule
        LendefiGovernorV2 wrongImplementation = new LendefiGovernorV2();

        // Schedule specific implementation
        vm.prank(gnosisSafe);
        govInstance.scheduleUpgrade(scheduledImpl);

        // But try to upgrade with a different one
        vm.warp(block.timestamp + govInstance.UPGRADE_TIMELOCK_DURATION() + 1);
        vm.prank(gnosisSafe);

        vm.expectRevert(
            abi.encodeWithSelector(
                LendefiGovernor.ImplementationMismatch.selector, scheduledImpl, address(wrongImplementation)
            )
        );
        govInstance.upgradeToAndCall(address(wrongImplementation), "");
    }

    // Test for timelock active in _authorizeUpgrade
    function testRevert_UpgradeTimelockActive() public {
        address newImpl = address(0x1234);

        // Schedule upgrade
        vm.prank(gnosisSafe);
        govInstance.scheduleUpgrade(newImpl);

        // Try upgrading immediately without waiting for timelock

        vm.expectRevert(
            abi.encodeWithSelector(
                LendefiGovernor.UpgradeTimelockActive.selector, govInstance.UPGRADE_TIMELOCK_DURATION()
            )
        );
        vm.prank(gnosisSafe);
        govInstance.upgradeToAndCall(newImpl, "");
    }

    // Test cancelling an upgrade
    function test_CancelUpgrade() public {
        address mockImplementation = address(0xABCD);

        // Schedule an upgrade first
        vm.prank(gnosisSafe); // Has UPGRADER_ROLE
        govInstance.scheduleUpgrade(mockImplementation);

        // Verify upgrade is scheduled
        (address impl,, bool exists) = govInstance.pendingUpgrade();
        assertTrue(exists);
        assertEq(impl, mockImplementation);

        // Now cancel it
        vm.expectEmit(true, true, false, false);
        emit UpgradeCancelled(gnosisSafe, mockImplementation);

        vm.prank(gnosisSafe);
        govInstance.cancelUpgrade();

        // Verify upgrade was cancelled
        (,, exists) = govInstance.pendingUpgrade();
        assertFalse(exists);
    }

    // Test error when trying to cancel non-existent upgrade
    function testRevert_CancelUpgradeNoScheduledUpgrade() public {
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSignature("UpgradeNotScheduled()"));
        govInstance.cancelUpgrade();
    }

    // Test for the uncovered supportsInterface function
    function test_SupportsInterface() public {
        // Test for IGovernor interface
        bytes4 governorInterfaceId = type(IGovernor).interfaceId;
        assertTrue(govInstance.supportsInterface(governorInterfaceId));

        // Test for ERC165 interface
        bytes4 erc165InterfaceId = 0x01ffc9a7;
        assertTrue(govInstance.supportsInterface(erc165InterfaceId));

        // Test for false case
        bytes4 invalidInterfaceId = 0xffffffff;
        assertFalse(govInstance.supportsInterface(invalidInterfaceId));
    }

    // Test proposalNeedsQueuing function
    function test_ProposalNeedsQueuing() public {
        // Create a proposal first
        address[] memory winners = new address[](1);
        winners[0] = alice;
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 200_000 ether);

        vm.prank(alice);
        tokenInstance.delegate(alice);
        vm.roll(block.number + 1);

        address[] memory targets = new address[](1);
        targets[0] = address(tokenInstance);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("transfer(address,uint256)", bob, 100);

        vm.prank(alice);
        uint256 proposalId = govInstance.propose(targets, values, calldatas, "Test proposal");

        // Now check if this proposal needs queuing
        bool needsQueuing = govInstance.proposalNeedsQueuing(proposalId);
        assertTrue(needsQueuing, "Proposal should need queuing");
    }

    // Test _cancel function
    function test_CancelProposal() public {
        // Set up proposal
        address[] memory winners = new address[](1);
        winners[0] = alice;
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 200_000 ether);

        vm.prank(alice);
        tokenInstance.delegate(alice);

        vm.roll(block.number + 1);

        address[] memory targets = new address[](1);
        targets[0] = address(tokenInstance);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("transfer(address,uint256)", bob, 100);
        string memory description = "Test proposal";

        vm.prank(alice);
        uint256 proposalId = govInstance.propose(targets, values, calldatas, description);

        // Cancel the proposal
        bytes32 descHash = keccak256(bytes(description));
        vm.prank(alice); // The proposer can cancel
        govInstance.cancel(targets, values, calldatas, descHash);

        // Verify it was cancelled
        assertEq(uint8(govInstance.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));
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
