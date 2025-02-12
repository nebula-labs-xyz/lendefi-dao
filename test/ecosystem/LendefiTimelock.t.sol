// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BasicDeploy} from "../BasicDeploy.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract YodaTimelockTest is BasicDeploy {
    address internal govImplementation;

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
        vm.prank(guardian);
        ecoInstance.grantRole(MANAGER_ROLE, managerAdmin);
        govImplementation = Upgrades.getImplementationAddress(address(govInstance));
    }

    function test_Revert_Initialization() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        uint256 timelockDelay = 24 * 60 * 60;
        address[] memory temp = new address[](1);
        temp[0] = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        timelockInstance.initialize(timelockDelay, temp, temp, guardian);
    }

    function test_AdminRole() public {
        assertTrue(timelockInstance.hasRole(DEFAULT_ADMIN_ROLE, guardian) == true);
        assertTrue(timelockInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)) == true);
    }

    function test_ProposerRole() public {
        assertTrue(timelockInstance.hasRole(PROPOSER_ROLE, address(govInstance)) == true);
    }

    function test_ExecutorRole() public {
        assertTrue(timelockInstance.hasRole(EXECUTOR_ROLE, address(govInstance)) == true);
    }

    function test_CancellerRole() public {
        assertTrue(timelockInstance.hasRole(CANCELLER_ROLE, address(govInstance)) == true);
    }
}
