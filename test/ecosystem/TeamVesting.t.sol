// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line
import {TeamVesting} from "../../contracts/ecosystem/TeamVesting.sol";
import {TeamManager} from "../../contracts/ecosystem/TeamManager.sol";

contract TeamVestingTest is BasicDeploy {
    uint256 internal vmprimer = 365 days;
    address internal vestingAddr;
    uint256 internal amount;
    TeamManager internal tmInstance;

    event ERC20Released(address indexed token, uint256 amount);
    event AddPartner(address account, address vesting, uint256 amount);

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

        // deploy Team Manager
        bytes memory data =
            abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implementation);

        amount = 500_000 ether;
        vm.startPrank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), address(tmInstance), amount);
        tmInstance.addTeamMember(alice, amount);
        vm.stopPrank();

        vestingAddr = tmInstance.vestingContracts(alice);
        uint256 bal = tokenInstance.balanceOf(vestingAddr);
        assertEq(bal, amount);
    }

    function test_Release() public {
        TeamVesting instance = TeamVesting(payable(vestingAddr));
        uint256 vested;
        vm.warp(vmprimer + 365 days); // cliff
        vested = instance.releasable();
        assertEq(vested, 0);
        vm.warp(vmprimer + 730 days); // half-way
        vested = instance.releasable();
        assertEq(vested, amount / 2);
        vm.warp(vmprimer + 1095 days); // fully vested
        vested = instance.releasable();
        assertEq(vested, amount);

        vm.expectEmit(address(instance));
        emit ERC20Released(address(tokenInstance), vested);
        instance.release();

        uint256 aliceBal = tokenInstance.balanceOf(alice);
        uint256 bal = tokenInstance.balanceOf(vestingAddr);
        assertEq(aliceBal, amount);
        assertEq(bal, 0);
    }
}
