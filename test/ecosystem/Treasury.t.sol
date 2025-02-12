// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BasicDeploy} from "../BasicDeploy.sol";

contract TreasuryTest is BasicDeploy {
    uint256 internal vmprimer = 365 days;

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

        (bool success,) = payable(address(treasuryInstance)).call{value: 500 ether}("");
        require(success, "ERR_ETH_TRANSFER_FAILED");
        assertEq(address(treasuryInstance).balance, 500 ether);

        vm.prank(guardian);
        treasuryInstance.grantRole(MANAGER_ROLE, managerAdmin);
    }

    function test_Pause() public {
        vm.prank(guardian);
        treasuryInstance.grantRole(PAUSER_ROLE, pauser);
        assertEq(treasuryInstance.paused(), false);
        vm.startPrank(pauser);
        treasuryInstance.pause();
        assertEq(treasuryInstance.paused(), true);
        treasuryInstance.unpause();
        assertEq(treasuryInstance.paused(), false);
        vm.stopPrank();
    }

    function test_Revert_Initialize() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        treasuryInstance.initialize(guardian, address(timelockInstance));
    }

    function test_ReleaseEther() public {
        uint256 startBal = address(treasuryInstance).balance;
        uint256 vested = treasuryInstance.releasable();
        vm.startPrank(managerAdmin);
        vm.expectEmit(address(treasuryInstance));
        emit EtherReleased(managerAdmin, vested);
        treasuryInstance.release(managerAdmin, vested);
        vm.stopPrank();
        assertEq(managerAdmin.balance, vested);
        assertEq(address(treasuryInstance).balance, startBal - vested);
    }

    function test_Revert_ReleaseEther_Branch1() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError); // access control violation
        treasuryInstance.release(guardian, 100 ether);
    }

    function test_Revert_ReleaseEther_Branch2() public {
        assertEq(treasuryInstance.paused(), false);
        vm.prank(guardian);
        treasuryInstance.grantRole(PAUSER_ROLE, pauser);
        vm.prank(pauser);
        treasuryInstance.pause();
        assertEq(treasuryInstance.paused(), true);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // contract paused
        treasuryInstance.release(assetRecipient, 100 ether);
    }

    function test_Revert_ReleaseEther_Branch3() public {
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "NOT_ENOUGH_VESTED");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        treasuryInstance.release(assetRecipient, 101 ether);
    }

    function test_Revert_ReleaseEther_Branch4() public {
        vm.warp(vmprimer + 1095 days); // fully vested
        uint256 startingBal = address(this).balance;

        vm.prank(managerAdmin);
        treasuryInstance.release(address(this), 200 ether);
        assertEq(address(this).balance, startingBal + 200 ether);
        assertEq(guardian.balance, 0);
    }

    function test_ReleaseTokens() public {
        uint256 vested = treasuryInstance.releasable(address(tokenInstance));
        vm.prank(managerAdmin);
        treasuryInstance.release(address(tokenInstance), assetRecipient, vested);
        assertEq(tokenInstance.balanceOf(assetRecipient), vested);
    }

    function test_Revert_ReleaseTokens_Branch1() public {
        vm.warp(vmprimer + 548 days); // half-vested
        uint256 vested = treasuryInstance.releasable(address(tokenInstance));
        assertTrue(vested > 0);
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError); // access control violation
        treasuryInstance.release(address(tokenInstance), assetRecipient, vested);
    }

    function test_Revert_ReleaseTokens_Branch2() public {
        vm.warp(vmprimer + 548 days); // half-vested
        uint256 vested = treasuryInstance.releasable(address(tokenInstance));
        assertTrue(vested > 0);
        assertEq(ecoInstance.paused(), false);
        vm.prank(guardian);
        treasuryInstance.grantRole(PAUSER_ROLE, pauser);
        vm.prank(pauser);
        treasuryInstance.pause();
        assertEq(treasuryInstance.paused(), true);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // contract paused
        treasuryInstance.release(address(tokenInstance), assetRecipient, vested);
    }

    function test_Revert_ReleaseTokens_Branch3() public {
        vm.warp(vmprimer + 548 days); // half-vested
        uint256 vested = treasuryInstance.releasable(address(tokenInstance));
        assertTrue(vested > 0);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "NOT_ENOUGH_VESTED");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // not enough vested violation
        treasuryInstance.release(address(tokenInstance), assetRecipient, vested + 1 ether);
    }
}
