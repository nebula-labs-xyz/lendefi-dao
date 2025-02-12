// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
import {InvestmentManager} from "../../contracts/ecosystem/InvestmentManager.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IINVESTOR} from "../../contracts/interfaces/IInvestmentManager.sol";

contract InvestmentManagerTest is BasicDeploy {
    uint256 internal vmprimer = 365 days;
    InvestmentManager internal imInstance;

    event EtherReleased(address indexed to, uint256 amount);
    event ERC20Released(address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        deployComplete();
        assertEq(tokenInstance.totalSupply(), 0);
        // this is the TGE
        vm.startPrank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        uint256 ecoBal = tokenInstance.balanceOf(address(ecoInstance));
        uint256 treasuryBal = tokenInstance.balanceOf(address(treasuryInstance));

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 28_000_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal);

        usdcInstance = new USDC();
        wethInstance = new WETH9();
        // deploy Investment Manager
        bytes memory data = abi.encodeCall(
            InvestmentManager.initialize,
            (
                address(tokenInstance),
                address(timelockInstance),
                address(treasuryInstance),
                address(wethInstance),
                guardian
            )
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", data));
        imInstance = InvestmentManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(imInstance) == implementation);

        treasuryInstance.grantRole(MANAGER_ROLE, address(timelockInstance));
        //imInstance.grantRole(MANAGER_ROLE, address(guardian));//
        vm.stopPrank();
    }

    function test_Revert_Initialize() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        imInstance.initialize(
            address(tokenInstance),
            address(timelockInstance),
            address(treasuryInstance),
            address(wethInstance),
            guardian
        );
    }

    function test_Pause() public {
        assertEq(imInstance.paused(), false);
        vm.startPrank(guardian);
        imInstance.pause();
        assertEq(imInstance.paused(), true);
        imInstance.unpause();
        assertEq(imInstance.paused(), false);
        vm.stopPrank();
    }

    function test_createRound() public {
        createRound(100 ether, 500_000 ether);
    }

    function test_addInvestorAllocation() public {
        createRound(100 ether, 500_000 ether);
        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, alice, 10 ether, 50_000 ether);
        IINVESTOR.Investment memory investment = imInstance.getInvestorAllocation(0, alice);
        assertEq(investment.etherAmount, 10 ether);
        assertEq(investment.tokenAmount, 50_000 ether);
    }

    function test_investEth() public returns (bool success) {
        createRound(100 ether, 500_000 ether);
        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, alice, 10 ether, 50_000 ether);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (success,) = payable(address(imInstance)).call{value: 10 ether}("");

        IINVESTOR.Round memory roundInfo = imInstance.getRoundInfo(0);
        assertEq(roundInfo.etherTarget, 100 ether);
        assertEq(roundInfo.tokenAllocation, 500_000 ether);
        assertEq(roundInfo.etherInvested, 10 ether);
        assertEq(roundInfo.participants, 1);
    }

    function test_investWETH() public returns (bool success) {
        createRound(100 ether, 500_000 ether);
        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, alice, 10 ether, 50_000 ether);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        (success,) = payable(address(wethInstance)).call{value: 10 ether}("");
        wethInstance.approve(address(imInstance), 10 ether);
        imInstance.investWETH(0, 10 ether);
        vm.stopPrank();

        IINVESTOR.Round memory roundInfo = imInstance.getRoundInfo(0);
        assertEq(roundInfo.etherTarget, 100 ether);
        assertEq(roundInfo.tokenAllocation, 500_000 ether);
        assertEq(roundInfo.etherInvested, 10 ether);
        assertEq(roundInfo.participants, 1);
    }

    function test_cancelInvestment() public returns (bool success) {
        createRound(100 ether, 500_000 ether);
        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, alice, 10 ether, 50_000 ether);
        uint256 amount = 10 ether;
        vm.deal(alice, amount);
        vm.prank(alice);
        (success,) = payable(address(imInstance)).call{value: amount}("");

        IINVESTOR.Round memory roundInfo = imInstance.getRoundInfo(0);
        assertEq(roundInfo.etherTarget, 100 ether);
        assertEq(roundInfo.tokenAllocation, 500_000 ether);
        assertEq(roundInfo.etherInvested, amount);
        assertEq(roundInfo.participants, 1);

        vm.prank(alice);
        imInstance.cancelInvestment(0);

        roundInfo = imInstance.getRoundInfo(0);
        assertEq(wethInstance.balanceOf(alice), amount);
        assertEq(roundInfo.etherTarget, 100 ether);
        assertEq(roundInfo.tokenAllocation, 500_000 ether);
        assertEq(roundInfo.etherInvested, 0);
        assertEq(roundInfo.participants, 0);
    }

    function test_Revert_cancelRound_Branch1() public returns (bool success) {
        createRound(100 ether, 500_000 ether);
        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, alice, 10 ether, 50_000 ether);
        uint256 amount = 10 ether;
        vm.deal(alice, amount);
        vm.prank(alice);
        (success,) = payable(address(imInstance)).call{value: amount}("");

        IINVESTOR.Round memory roundInfo = imInstance.getRoundInfo(0);
        assertEq(roundInfo.etherTarget, 100 ether);
        assertEq(roundInfo.tokenAllocation, 500_000 ether);
        assertEq(roundInfo.etherInvested, amount);
        assertEq(roundInfo.participants, 1);
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        vm.prank(guardian); // access control
        vm.expectRevert(expError);
        imInstance.cancelRound(0);
    }

    function test_Revert_cancelRound_Branch2() public returns (bool success) {
        createRound(100 ether, 500_000 ether);
        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, alice, 100 ether, 500_000 ether);

        uint256 amount = 100 ether;
        vm.deal(alice, amount);
        vm.prank(alice);
        (success,) = payable(address(imInstance)).call{value: amount}("");

        IINVESTOR.Round memory roundInfo = imInstance.getRoundInfo(0);
        assertEq(roundInfo.etherTarget, 100 ether);
        assertEq(roundInfo.tokenAllocation, 500_000 ether);
        assertEq(roundInfo.etherInvested, amount);
        assertEq(roundInfo.participants, 1);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "ROUND_CLOSED");
        vm.prank(address(timelockInstance)); // round closed
        vm.expectRevert(expError);
        imInstance.cancelRound(0);
    }

    function test_Revert_cancelRound_Branch3() public returns (bool success) {
        createRound(100 ether, 500_000 ether);
        uint256 amount = 10 ether;
        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, alice, amount, 50_000 ether);

        vm.deal(alice, amount);
        vm.prank(alice);
        (success,) = payable(address(imInstance)).call{value: amount}("");

        IINVESTOR.Round memory roundInfo = imInstance.getRoundInfo(0);
        assertEq(roundInfo.etherTarget, 100 ether);
        assertEq(roundInfo.tokenAllocation, 500_000 ether);
        assertEq(roundInfo.etherInvested, amount);
        assertEq(roundInfo.participants, 1);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "CANT_CANCEL_ROUND");
        vm.prank(address(timelockInstance)); // can't delete the zero round
        vm.expectRevert(expError);
        imInstance.cancelRound(0);
    }

    function test_cancelRound() public returns (bool success) {
        uint256 raiseAmount = 100 ether;
        uint256 roundAllocation = 500_000 ether;
        createRound(raiseAmount, roundAllocation);
        uint256 amount = raiseAmount / 10;
        uint256 allocation = roundAllocation / 10;
        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, alice, amount, allocation);

        vm.deal(alice, amount * 2);
        vm.prank(alice);
        (success,) = payable(address(imInstance)).call{value: amount}("");

        IINVESTOR.Round memory roundInfo = imInstance.getRoundInfo(0);
        assertEq(roundInfo.etherTarget, 100 ether);
        assertEq(roundInfo.tokenAllocation, roundAllocation);
        assertEq(roundInfo.etherInvested, amount);
        assertEq(roundInfo.participants, 1);

        createRound(400 ether, roundAllocation);
        vm.prank(guardian);
        imInstance.addInvestorAllocation(1, alice, amount, allocation);
        vm.startPrank(alice);
        (success,) = payable(address(wethInstance)).call{value: amount}("");
        wethInstance.approve(address(imInstance), amount);
        imInstance.investWETH(1, amount);
        vm.stopPrank();

        uint256 balBefore = tokenInstance.balanceOf(address(treasuryInstance));
        vm.prank(address(timelockInstance));
        imInstance.cancelRound(1);
        uint256 balAfter = tokenInstance.balanceOf(address(treasuryInstance));
        uint256 aliceBal = wethInstance.balanceOf(alice);
        uint256 imBal = tokenInstance.balanceOf(address(imInstance));

        assertEq(imBal, roundAllocation);
        assertEq(aliceBal, amount);
        assertEq(balAfter, balBefore + roundAllocation);
    }

    function createRound(uint256 target, uint256 allocation) public {
        // execute a DAO proposal that
        // 1. moves token allocation from treasury to the InvestmentManager
        // 2. initializes the investment round

        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;

        vm.prank(guardian);
        ecoInstance.grantRole(MANAGER_ROLE, managerAdmin);
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 200_000 ether);
        // assertEq(tokenInstance.balanceOf(alice), 200_000 ether);

        vm.prank(alice);
        tokenInstance.delegate(alice);
        vm.prank(bob);
        tokenInstance.delegate(bob);
        vm.prank(charlie);
        tokenInstance.delegate(charlie);

        vm.roll(365 days);

        // create proposal
        // part1 - move round allocation from treasury to InvestmentManager instance
        bytes memory callData1 = abi.encodeWithSignature(
            "release(address,address,uint256)", address(tokenInstance), address(imInstance), allocation
        );
        // part2 - call InvestmentManager to createRound
        bytes memory callData2 = abi.encodeWithSignature(
            "createRound(uint64,uint64,uint256,uint256)",
            uint64(block.timestamp - 100),
            uint64(90 * 24 * 60 * 60),
            target,
            allocation
        );
        address[] memory to = new address[](2);
        to[0] = address(treasuryInstance);
        to[1] = address(imInstance);
        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = callData1;
        calldatas[1] = callData2;

        vm.prank(alice);
        uint256 proposalId = govInstance.propose(to, values, calldatas, "Proposal #2: create funding round 1");

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

        bytes32 descHash = keccak256(abi.encodePacked("Proposal #2: create funding round 1"));

        govInstance.queue(to, values, calldatas, descHash);

        IGovernor.ProposalState state5 = govInstance.state(proposalId);
        assertTrue(state5 == IGovernor.ProposalState.Queued); //proposal queued

        uint256 eta = govInstance.proposalEta(proposalId);
        vm.warp(eta + 1);
        vm.roll(eta + 1);
        govInstance.execute(to, values, calldatas, descHash);
        IGovernor.ProposalState state7 = govInstance.state(proposalId);

        assertTrue(state7 == IGovernor.ProposalState.Executed); //proposal executed
    }
}
