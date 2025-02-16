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

    // Test: RevertInitialize
    function testRevertInitialize() public {
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

    // Test: Pause
    function testPause() public {
        assertEq(imInstance.paused(), false);
        vm.startPrank(guardian);
        imInstance.pause();
        assertEq(imInstance.paused(), true);
        imInstance.unpause();
        assertEq(imInstance.paused(), false);
        vm.stopPrank();
    }

    // Test: RevertPauseBranch1
    function testRevertPauseBranch1() public {
        vm.prank(guardian);
        imInstance.pause();
        assertTrue(imInstance.paused());

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(alice);
        vm.expectRevert(expError); // contract paused
        imInstance.investEther(0);
    }

    // Test: CreateRound Propoer via Governor
    function testCreateRound() public {
        createRound(100 ether, 500_000 ether);
    }

    // Test: CreateRoundSpoof
    function testCreateRoundSpoof() public {
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(imInstance), 1000 ether);
        vm.prank(address(timelockInstance));
        imInstance.createRound(uint64(block.timestamp), 1 weeks, 100 ether, 1000 ether);
        IINVESTOR.Round memory item = imInstance.getRoundInfo(0);

        assertEq(item.start, uint64(block.timestamp));
        assertEq(item.end, uint64(block.timestamp + 1 weeks));
        assertEq(item.etherTarget, 100 ether);
        assertEq(item.tokenAllocation, 1000 ether);
    }

    // Test: Multiple Rounds Creation
    function testMultipleRoundsCreation() public {
        vm.startPrank(address(timelockInstance));

        uint64 startTime = uint64(block.timestamp);
        for (uint64 i = 0; i < 3; i++) {
            treasuryInstance.release(address(tokenInstance), address(imInstance), 1000 ether * (i + 1));
            imInstance.createRound(startTime + (i * 1 weeks), 1 weeks, 100 ether * (i + 1), 1000 ether * (i + 1));
        }
        vm.stopPrank();

        for (uint32 i = 0; i < 3; i++) {
            IINVESTOR.Round memory item = imInstance.getRoundInfo(i);
            assertEq(item.start, startTime + (i * 1 weeks));
            assertEq(item.end, startTime + (i * 1 weeks) + 1 weeks);
            assertEq(item.etherTarget, 100 ether * (i + 1));
            assertEq(item.tokenAllocation, 1000 ether * (i + 1));
        }
    }

    // Test: CreateRound Insufficient Token Balance
    function testCreateRoundInsufficientBalance() public {
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "NO_SUPPLY");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError);
        imInstance.createRound(uint64(block.timestamp), 1 weeks, 100 ether, 1000 ether);
    }

    // Test: CreateRound Invalid Ether Target
    function testCreateRoundInvalidEtherTarget() public {
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(imInstance), 1000 ether);

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_ETH_ALLOCATION");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError);
        imInstance.createRound(uint64(block.timestamp), 1 weeks, 0, 1000 ether);
    }

    // Test: CreateRound Invalid Token Allocation
    function testCreateRoundInvalidTokenAllocation() public {
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(imInstance), 1000 ether);

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_TOKEN_ALLOCATION");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError);
        imInstance.createRound(uint64(block.timestamp), 1 weeks, 100 ether, 0);
    }

    // Test: CloseRound
    function testCloseRound() public {
        // Setup round
        createRound(100 ether, 1000 ether);

        // Setup allocations
        vm.startPrank(guardian);
        imInstance.addInvestorAllocation(0, alice, 50 ether, 500 ether);
        imInstance.addInvestorAllocation(0, bob, 50 ether, 500 ether);
        vm.stopPrank();

        // Investments
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.startPrank(alice);
        wethInstance.deposit{value: 50 ether}();
        IERC20(address(wethInstance)).approve(address(imInstance), 50 ether);
        imInstance.investWETH(0, 50 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        wethInstance.deposit{value: 50 ether}();
        IERC20(address(wethInstance)).approve(address(imInstance), 50 ether);
        imInstance.investWETH(0, 50 ether);
        vm.stopPrank();

        uint256 treasuryBalanceBefore = address(treasuryInstance).balance;
        imInstance.closeRound(0);
        uint256 treasuryBalanceAfter = address(treasuryInstance).balance;

        assertEq(treasuryBalanceAfter - treasuryBalanceBefore, 100 ether);
    }

    // Test: AddInvestorAllocation
    function testAddInvestorAllocation() public {
        createRound(100 ether, 500_000 ether);
        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, alice, 10 ether, 50_000 ether);
        IINVESTOR.Investment memory investment = imInstance.getInvestorAllocation(0, alice);
        assertEq(investment.etherAmount, 10 ether);
        assertEq(investment.tokenAmount, 50_000 ether);
    }

    // Test: AddInvestorAllocationInvalidRound
    function testAddInvestorAllocationInvalidRound() public {
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_ROUND");
        vm.prank(guardian);
        vm.expectRevert(expError);
        imInstance.addInvestorAllocation(1, alice, 1 ether, 10 ether);
    }

    // Test: AddInvestorAllocationExceedsRoundLimit
    function testAddInvestorAllocationExceedsRoundLimit() public {
        createRound(100 ether, 1000 ether);
        vm.startPrank(guardian);
        imInstance.addInvestorAllocation(0, alice, 10 ether, 900 ether);

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "ALLOCATION_EXCEEDS_ROUND_LIMIT");
        vm.expectRevert(expError);
        imInstance.addInvestorAllocation(0, bob, 10 ether, 200 ether);
        vm.stopPrank();
    }

    // Test: AddInvestorAllocationUnauthorizedAccess
    function testAddInvestorAllocationUnauthorizedAccess() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, ALLOCATOR_ROLE);
        vm.prank(alice);
        vm.expectRevert(expError);
        imInstance.addInvestorAllocation(0, bob, 1 ether, 10 ether);
    }

    // Test Fuzz: FuzzAddInvestorAllocation
    function testFuzzAddInvestorAllocation(uint256 amountETH, uint256 amountToken) public {
        createRound(100 ether, 1000 ether);
        vm.assume(amountETH > 0 && amountToken > 0 && amountToken <= 1000 ether);

        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, alice, amountETH, amountToken);

        IINVESTOR.Investment memory item = imInstance.getInvestorAllocation(0, alice);
        assertEq(item.etherAmount, amountETH);
        assertEq(item.tokenAmount, amountToken);
    }

    // Test: AddInvestorAllocationZeroAddress
    function testAddInvestorAllocationZeroAddress() public {
        createRound(100 ether, 1000 ether);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_ADDRESS");
        vm.prank(guardian);
        vm.expectRevert(expError);
        imInstance.addInvestorAllocation(0, address(0), 1 ether, 10 ether);
    }

    // Test: AddInvestorAllocationZeroEthAmount
    function testAddInvestorAllocationZeroEthAmount() public {
        createRound(100 ether, 1000 ether);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_ETH_AMOUNT");
        vm.prank(guardian);
        vm.expectRevert(expError);
        imInstance.addInvestorAllocation(0, alice, 0, 10 ether);
    }

    // Test: AddInvestorAllocationZeroTokenAmount
    function testAddInvestorAllocationZeroTokenAmount() public {
        createRound(100 ether, 1000 ether);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_TOKEN_AMOUNT");
        vm.prank(guardian);
        vm.expectRevert(expError);
        imInstance.addInvestorAllocation(0, alice, 1 ether, 0);
    }

    // Test: AddInvestorAllocationMultipleAllocations
    function testAddInvestorAllocationMultipleAllocations() public {
        createRound(100 ether, 1000 ether);
        vm.startPrank(guardian);

        imInstance.addInvestorAllocation(0, alice, 1 ether, 400 ether);
        imInstance.addInvestorAllocation(0, bob, 1 ether, 400 ether);

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "ALLOCATION_EXCEEDS_ROUND_LIMIT");
        vm.expectRevert(expError);
        imInstance.addInvestorAllocation(0, charlie, 1 ether, 201 ether);

        vm.stopPrank();
    }

    // Test: AddInvestorAllocationUpdateExisting
    function testAddInvestorAllocationUpdateExisting() public {
        createRound(100 ether, 1000 ether);
        vm.startPrank(guardian);
        imInstance.addInvestorAllocation(0, alice, 1 ether, 400 ether);
        imInstance.addInvestorAllocation(0, alice, 2 ether, 400 ether);
        vm.stopPrank();

        IINVESTOR.Investment memory investment = imInstance.getInvestorAllocation(0, alice);
        assertEq(investment.etherAmount, 3 ether);
        assertEq(investment.tokenAmount, 800 ether);
    }

    // Test: RevertAddInvestorAllocationUpdateExisting
    function testRevertAddInvestorAllocationUpdateExisting() public {
        createRound(100 ether, 1000 ether);
        vm.startPrank(guardian);
        imInstance.addInvestorAllocation(0, alice, 1 ether, 400 ether);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "ALLOCATION_EXCEEDS_ROUND_LIMIT");
        vm.expectRevert(expError);
        imInstance.addInvestorAllocation(0, alice, 2 ether, 700 ether);
        vm.stopPrank();
    }

    // Test Fuzz: FuzzAddInvestorAllocationBoundaries
    function testFuzzAddInvestorAllocationBoundaries(uint256 amountETH, uint256 amountToken, address investor_)
        public
    {
        createRound(100 ether, 1000 ether);
        vm.assume(amountETH > 0);
        vm.assume(amountToken > 0);
        vm.assume(amountToken <= 1000 ether);
        vm.assume(investor_ != address(0));

        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, investor_, amountETH, amountToken);

        IINVESTOR.Investment memory investment = imInstance.getInvestorAllocation(0, investor_);
        assertEq(investment.etherAmount, amountETH);
        assertEq(investment.tokenAmount, amountToken);
    }

    // Test: RemoveInvestorAllocation Invalid Round
    function testRemoveInvestorAllocationInvalidRound() public {
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_ROUND");
        vm.prank(guardian);
        vm.expectRevert(expError);
        imInstance.removeInvestorAllocation(999, alice);
    }

    // Test: RemoveInvestorAllocation Unauthorized
    function testRemoveInvestorAllocationUnauthorized() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, ALLOCATOR_ROLE);
        vm.prank(alice);
        vm.expectRevert(expError);
        imInstance.removeInvestorAllocation(0, alice);
    }

    // Test: RemoveInvestorAllocation Success
    function testRemoveInvestorAllocationSuccess() public {
        createRound(100 ether, 1000 ether);

        // First add an allocation
        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, alice, 1 ether, 10 ether);

        // Verify allocation exists
        IINVESTOR.Investment memory item = imInstance.getInvestorAllocation(0, alice);
        assertEq(item.etherAmount, 1 ether);
        assertEq(item.tokenAmount, 10 ether);

        // Remove allocation
        vm.prank(guardian);
        imInstance.removeInvestorAllocation(0, alice);

        // Verify allocation is removed
        item = imInstance.getInvestorAllocation(0, alice);
        assertEq(item.etherAmount, 0);
        assertEq(item.tokenAmount, 0);
    }

    // Test: RemoveInvestorAllocation Non-Existent
    function testRemoveInvestorAllocationNonExistent() public {
        createRound(100 ether, 1000 ether);

        // Remove non-existent allocation
        vm.prank(guardian);
        imInstance.removeInvestorAllocation(0, alice);

        // Verify zero values
        IINVESTOR.Investment memory item = imInstance.getInvestorAllocation(0, alice);
        assertEq(item.etherAmount, 0);
        assertEq(item.tokenAmount, 0);
    }

    // Test: GetRoundInfo Invalid Round
    function testGetRoundInfoInvalidRound() public {
        vm.expectRevert();
        imInstance.getRoundInfo(0);
    }

    // Test: CreateRound Invalid Duration
    function testCreateRoundInvalidDuration() public {
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(imInstance), 1000 ether);

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_DURATION");
        vm.prank(address(timelockInstance));
        vm.expectRevert(expError);
        imInstance.createRound(uint64(block.timestamp), 0, 100 ether, 1000 ether);
    }

    // Test: InvestEth
    function testInvestEth() public returns (bool success) {
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

    // Test: InvestEther Invalid Round
    function testInvestEtherInvalidRound() public {
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_ROUND");
        vm.expectRevert(expError);
        imInstance.investEther{value: 1 ether}(999);
    }

    // Test: InvestEther No Allocation
    function testInvestEtherNoAllocation() public {
        createRound(100 ether, 1000 ether);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        vm.expectRevert(expError);
        imInstance.investEther{value: 1 ether}(0);
    }

    // Test: InvestWETH
    function testInvestWETH() public returns (bool success) {
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

    // Test: RevertInvestWETHBranch1
    function testRevertInvestWETHBranch1() public returns (bool success) {
        createRound(100 ether, 500_000 ether);
        vm.prank(guardian);
        imInstance.addInvestorAllocation(0, alice, 5 ether, 50_000 ether);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        (success,) = payable(address(wethInstance)).call{value: 10 ether}("");
        wethInstance.approve(address(imInstance), 10 ether);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");
        vm.expectRevert(expError);
        imInstance.investWETH(0, 10 ether);
        vm.stopPrank();

        IINVESTOR.Round memory roundInfo = imInstance.getRoundInfo(0);
        assertEq(roundInfo.etherTarget, 100 ether);
        assertEq(roundInfo.tokenAllocation, 500_000 ether);
        assertEq(roundInfo.etherInvested, 0 ether);
        assertEq(roundInfo.participants, 0);
    }

    // Test: CancelInvestment
    function testCancelInvestment() public returns (bool success) {
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

    // Test: CancelInvestment Invalid Round
    function testCancelInvestmentInvalidRound() public {
        createRound(100 ether, 500_000 ether);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_ROUND");
        vm.expectRevert(expError);
        imInstance.cancelInvestment(1);
    }

    // Test: CancelInvestment Round Closed
    function testCancelInvestmentRoundClosed() public {
        createRound(100 ether, 1000 ether);

        // Setup: Add allocation and invest
        vm.startPrank(guardian);
        imInstance.addInvestorAllocation(0, alice, 100 ether, 1000 ether);
        vm.stopPrank();

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        imInstance.investEther{value: 100 ether}(0);

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "ROUND_CLOSED");
        vm.prank(alice);
        vm.expectRevert(expError);
        imInstance.cancelInvestment(0);
    }

    // Test: CancelInvestment Investor Not Exist
    function testCancelInvestmentInvestorNotExist() public {
        createRound(100 ether, 1000 ether);

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVESTOR_NOT_EXIST");
        vm.prank(alice);
        vm.expectRevert(expError);
        imInstance.cancelInvestment(0);
    }

    // Test: CancelInvestment Multiple Investors
    function testCancelInvestmentMultipleInvestors() public {
        createRound(100 ether, 1000 ether);

        // Setup: Add allocations and investments
        vm.startPrank(guardian);
        imInstance.addInvestorAllocation(0, alice, 1 ether, 10 ether);
        imInstance.addInvestorAllocation(0, bob, 2 ether, 20 ether);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        imInstance.investEther{value: 1 ether}(0);

        vm.deal(bob, 2 ether);
        vm.prank(bob);
        imInstance.investEther{value: 2 ether}(0);

        // Cancel alice's investment
        vm.prank(alice);
        imInstance.cancelInvestment(0);

        // Verify alice's investment is cancelled
        IINVESTOR.Investment memory item = imInstance.getInvestorAllocation(0, alice);
        assertEq(item.etherAmount, 0);
        assertEq(item.tokenAmount, 0);
        assertEq(wethInstance.balanceOf(alice), 1 ether); //refunds are sent via WETH

        // Verify bob's investment remains
        IINVESTOR.Investment memory item2 = imInstance.getInvestorAllocation(0, bob);
        assertEq(item2.etherAmount, 2 ether);
        assertEq(item2.tokenAmount, 20 ether);
    }

    // Test: Can't CancelInvestment Twice
    function testCancelInvestmentTwice() public {
        createRound(100 ether, 1000 ether);

        // Setup: Add allocation and invest
        vm.startPrank(guardian);
        imInstance.addInvestorAllocation(0, address(this), 1 ether, 10 ether);
        vm.stopPrank();

        vm.deal(address(this), 1 ether);
        imInstance.investEther{value: 1 ether}(0);

        imInstance.cancelInvestment(0);
        // Verify alice's investment is cancelled
        IINVESTOR.Investment memory item = imInstance.getInvestorAllocation(0, address(this));
        assertEq(item.etherAmount, 0);
        assertEq(item.tokenAmount, 0);
        assertEq(wethInstance.balanceOf(address(this)), 1 ether); //refunds are sent via WETH

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVESTOR_NOT_EXIST");
        vm.expectRevert(expError);
        imInstance.cancelInvestment(0);
    }

    // Test: RevertCancelRoundBranch1
    function testRevertCancelRoundBranch1() public returns (bool success) {
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

    // Test: RevertCancelRoundBranch2
    function testRevertCancelRoundBranch2() public returns (bool success) {
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

    // Test: RevertCancelRoundBranch3
    function testRevertCancelRoundBranch3() public returns (bool success) {
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

    // Test: CancelRound
    function testCancelRound() public returns (bool success) {
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

    function testFuzz_InvestmentAmount(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 100 ether);

        // Setup round
        createRound(100 ether, 1000 ether);

        // Setup allocations
        vm.startPrank(guardian);
        imInstance.addInvestorAllocation(0, alice, amount, amount * 10);
        vm.stopPrank();

        // Invest
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        wethInstance.deposit{value: amount}();
        IERC20(address(wethInstance)).approve(address(imInstance), amount);
        imInstance.investWETH(0, amount);
        vm.stopPrank();

        IINVESTOR.Round memory roundInfo = imInstance.getRoundInfo(0);
        assertEq(roundInfo.etherInvested, amount);
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
            uint64(block.timestamp),
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
