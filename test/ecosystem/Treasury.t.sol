// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
import {Treasury} from "../../contracts/ecosystem/Treasury.sol"; // Path to your contract

contract TreasuryTest is BasicDeploy {
    Treasury internal treasuryContract;
    IERC20 public token;

    address public owner = guardian;
    address public beneficiary = address(0x456);
    address public nonOwner = address(0x789);

    uint256 public vestingAmount = 1000 ether;
    uint256 public startTime;
    uint256 public totalDuration;

    event EtherReleased(address indexed to, uint256 amount);
    event ERC20Released(address indexed token, address indexed to, uint256 amount);

    receive() external payable {
        if (msg.sender == address(treasuryInstance)) {
            // extends test_Revert_ReleaseEther_Branch4()
            bytes memory expError = abi.encodeWithSignature("ReentrancyGuardReentrantCall()");
            vm.prank(managerAdmin);
            vm.expectRevert(expError); // reentrancy
            treasuryInstance.release(guardian, 100 ether);
        }
    }

    function setUp() public {
        vm.warp(block.timestamp + 365 days);
        startTime = uint64(block.timestamp - 180 days);
        totalDuration = uint64(1095 days - 180 days);

        token = IERC20(address(new MockERC20()));
        // startTime = block.timestamp;

        //deploy Treasury
        bytes memory data4 = abi.encodeCall(Treasury.initialize, (guardian, managerAdmin));
        address payable proxy4 = payable(Upgrades.deployUUPSProxy("Treasury.sol", data4));
        treasuryContract = Treasury(proxy4);
        address tImplementation = Upgrades.getImplementationAddress(proxy4);
        assertFalse(address(treasuryContract) == tImplementation);
        vm.prank(guardian);
        treasuryContract.grantRole(PAUSER_ROLE, pauser);

        // Fund contract
        deal(address(token), address(treasuryContract), vestingAmount);
        vm.deal(address(treasuryContract), vestingAmount);
    }

    // Test: Only Pauser Can Pause
    function testOnlyPauserCanPause() public {
        assertEq(treasuryContract.paused(), false);
        vm.startPrank(pauser);
        treasuryContract.pause();
        assertEq(treasuryContract.paused(), true);
        treasuryContract.unpause();
        assertEq(treasuryContract.paused(), false);
        vm.stopPrank();

        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", nonOwner, PAUSER_ROLE);
        vm.prank(nonOwner);
        vm.expectRevert(expError); // access control violation
        treasuryContract.pause();

        vm.prank(pauser);
        treasuryContract.pause();
        assertTrue(treasuryContract.paused());
    }

    // Test: Only Pauser Can Unpause
    function testOnlyPauserCanUnpause() public {
        assertEq(treasuryContract.paused(), false);
        vm.prank(pauser);
        treasuryContract.pause();
        assertTrue(treasuryContract.paused());

        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", nonOwner, PAUSER_ROLE);
        vm.prank(nonOwner);
        vm.expectRevert(expError); // access control violation
        treasuryContract.unpause();

        vm.prank(pauser);
        treasuryContract.unpause();
        assertFalse(treasuryContract.paused());
    }

    // Test: Cannot Release Tokens When Paused
    function testCannotReleaseWhenPaused() public {
        vm.warp(startTime + 10 days);
        assertEq(treasuryContract.paused(), false);

        vm.prank(pauser);
        treasuryContract.pause();
        assertEq(treasuryContract.paused(), true);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // contract paused
        treasuryContract.release(assetRecipient, 10 ether);
    }

    // Test: Only Manager Can Release Tokens
    function testOnlyManagerCanRelease() public {
        vm.warp(block.timestamp + 548 days); // half-vested
        uint256 vested = treasuryContract.releasable(address(token));
        // console.log(vested);
        assertTrue(vested > 0);
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError); // access control violation
        treasuryContract.release(address(token), beneficiary, vested);
    }

    // Fuzz Test: Releasing Tokens with Randomized Timing
    function testFuzzRelease(uint256 warpTime) public {
        warpTime = bound(warpTime, startTime + 180 days, totalDuration);
        vm.warp(warpTime);

        uint256 elapsed = warpTime - startTime;
        uint256 expectedRelease = (elapsed * vestingAmount) / totalDuration;
        console.log(expectedRelease);

        uint256 beneficiaryBalanceBefore = beneficiary.balance;

        vm.prank(managerAdmin);
        treasuryContract.release(beneficiary, expectedRelease);

        assertEq(beneficiary.balance, beneficiaryBalanceBefore + expectedRelease);
    }

    // Fuzz Test: Only Pauser Can Pause or Unpause
    function testFuzzOnlyPauserCanPauseUnpause(address caller) public {
        vm.startPrank(caller);
        if (caller != pauser) {
            bytes memory expError =
                abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", caller, PAUSER_ROLE);

            vm.expectRevert(expError); // access control violation
            treasuryContract.pause();
        } else {
            treasuryContract.pause();
            assertTrue(treasuryContract.paused());

            treasuryContract.unpause();
            assertFalse(treasuryContract.paused());
        }
    }

    // Test: RevertInitialize
    function testRevertInitialize() public {
        vm.warp(startTime + 180 days);
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        treasuryContract.initialize(guardian, address(timelockInstance));
    }

    // Test: ReleaseEther
    function test_ReleaseEther() public {
        vm.warp(startTime + 180 days);
        uint256 startBal = address(treasuryContract).balance;
        uint256 vested = treasuryContract.releasable();
        vm.startPrank(managerAdmin);
        vm.expectEmit(address(treasuryContract));
        emit EtherReleased(managerAdmin, vested);
        treasuryContract.release(managerAdmin, vested);
        vm.stopPrank();
        assertEq(managerAdmin.balance, vested);
        assertEq(address(treasuryContract).balance, startBal - vested);
    }

    // Test: RevertReleaseEtherBranch1
    function testRevertReleaseEtherBranch1() public {
        vm.warp(startTime + 180 days);
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError); // access control violation
        treasuryContract.release(guardian, 100 ether);
    }

    // Test: RevertReleaseEtherBranch2
    function testRevertReleaseEtherBranch2() public {
        vm.warp(startTime + 180 days);
        assertEq(treasuryContract.paused(), false);
        vm.prank(guardian);
        treasuryContract.grantRole(PAUSER_ROLE, pauser);
        vm.prank(pauser);
        treasuryContract.pause();
        assertEq(treasuryContract.paused(), true);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // contract paused
        treasuryContract.release(assetRecipient, 100 ether);
    }

    // Test: RevertReleaseEtherBranch3
    function testRevertReleaseEtherBranch3() public {
        vm.warp(startTime + 10 days);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "NOT_ENOUGH_VESTED");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        treasuryContract.release(assetRecipient, 101 ether);
    }

    // Test: RevertReleaseEtherBranch4
    function testRevertReleaseEtherBranch4() public {
        vm.warp(startTime + 1095 days);
        uint256 startingBal = address(this).balance;

        vm.prank(managerAdmin);
        treasuryContract.release(address(this), 200 ether);
        assertEq(address(this).balance, startingBal + 200 ether);
        assertEq(guardian.balance, 0);
    }

    // Test: ReleaseTokens
    function testReleaseTokens() public {
        vm.warp(startTime + 180 days);
        uint256 vested = treasuryContract.releasable(address(token));
        vm.prank(managerAdmin);
        treasuryContract.release(address(token), assetRecipient, vested);
        assertEq(token.balanceOf(assetRecipient), vested);
    }

    // Test: RevertReleaseTokensBranch1
    function testRevertReleaseTokensBranch1() public {
        vm.warp(startTime + 700 days);
        uint256 vested = treasuryContract.releasable(address(token));
        assertTrue(vested > 0);
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError); // access control violation
        treasuryContract.release(address(token), assetRecipient, vested);
    }

    // Test: RevertReleaseTokensBranch2
    function testRevertReleaseTokensBranch2() public {
        vm.warp(startTime + 180 days);
        uint256 vested = treasuryContract.releasable(address(token));
        assertTrue(vested > 0);
        assertEq(treasuryContract.paused(), false);
        vm.prank(guardian);
        treasuryContract.grantRole(PAUSER_ROLE, pauser);
        vm.prank(pauser);
        treasuryContract.pause();
        assertEq(treasuryContract.paused(), true);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // contract paused
        treasuryContract.release(address(token), assetRecipient, vested);
    }

    // Test: RevertReleaseTokensBranch3
    function testRevertReleaseTokensBranch3() public {
        vm.warp(startTime + 180 days);
        uint256 vested = treasuryContract.releasable(address(token));
        assertTrue(vested > 0);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "NOT_ENOUGH_VESTED");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // not enough vested violation
        treasuryContract.release(address(token), assetRecipient, vested + 1 ether);
    }
}

// Mock ERC20 Token for Testing
contract MockERC20 is IERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    uint256 public totalSupply = 1e24; // 1M tokens

    constructor() {
        balances[msg.sender] = totalSupply;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        balances[recipient] += amount;
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        require(balances[sender] >= amount, "Insufficient balance");
        require(allowances[sender][msg.sender] >= amount, "Allowance exceeded");
        balances[sender] -= amount;
        balances[recipient] += amount;
        allowances[sender][msg.sender] -= amount;
        return true;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return allowances[owner][spender];
    }
}
