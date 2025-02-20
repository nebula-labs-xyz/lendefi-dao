// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BasicDeploy} from "../BasicDeploy.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

contract VestingWalletTest is BasicDeploy {
    uint256 internal vmprimer = 365 days;
    address internal vestingAddr;

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

        vm.warp(vmprimer);
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 8;

        vm.prank(guardian);
        ecoInstance.grantRole(MANAGER_ROLE, managerAdmin);
        vm.prank(managerAdmin);
        ecoInstance.addPartner(partner, amount, 365 days, 730 days);

        vestingAddr = ecoInstance.vestingContracts(partner);
        uint256 bal = tokenInstance.balanceOf(vestingAddr);
        assertEq(bal, amount);
    }

    function test_Release() public {
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 8;

        VestingWallet instance = VestingWallet(payable(vestingAddr));
        uint256 freeAmount;
        vm.warp(vmprimer + 365 days); // cliff
        freeAmount = instance.releasable(address(tokenInstance));
        assertEq(freeAmount, 0);
        vm.warp(vmprimer + 730 days); // half-way
        freeAmount = instance.releasable(address(tokenInstance));
        assertEq(freeAmount, amount / 2);
        vm.warp(vmprimer + 1095 days); // fully vested
        freeAmount = instance.releasable(address(tokenInstance));
        assertEq(freeAmount, amount);

        vm.expectEmit(address(instance));
        emit ERC20Released(address(tokenInstance), freeAmount);
        instance.release(address(tokenInstance));

        uint256 partnerBal = tokenInstance.balanceOf(partner);
        uint256 bal = tokenInstance.balanceOf(vestingAddr);
        assertEq(partnerBal, amount);
        assertEq(bal, 0);
    }
}
