// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BasicDeploy} from "../BasicDeploy.sol";

contract EcosystemTest is BasicDeploy {
    event Burn(address indexed src, uint256 amount);
    event Reward(address indexed src, address indexed to, uint256 amount);
    event AirDrop(address[] addresses, uint256 amount);
    event AddPartner(address indexed account, address indexed vesting, uint256 amount);

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
    }

    function test_Revert_Receive() public returns (bool success) {
        vm.expectRevert(); // contract does not receive ether
        (success,) = payable(address(ecoInstance)).call{value: 100 ether}("");
    }

    function test_Revert_Initialization() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        ecoInstance.initialize(address(tokenInstance), guardian, pauser);
    }

    function test_Pause() public {
        assertEq(ecoInstance.paused(), false);
        vm.startPrank(pauser);
        ecoInstance.pause();
        assertEq(ecoInstance.paused(), true);
        ecoInstance.unpause();
        assertEq(ecoInstance.paused(), false);
        vm.stopPrank();
    }

    function test_Revert_Pause_Branch1() public {
        assertEq(ecoInstance.paused(), false);

        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, PAUSER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError);
        ecoInstance.pause();
    }

    function test_Airdrop() public {
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(charlie, 1 ether);
        vm.startPrank(managerAdmin);
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
        bool verified = ecoInstance.verifyAirdrop(winners, 20 ether);
        require(verified, "AIRDROP_VERIFICATION");
        vm.expectEmit(address(ecoInstance));
        emit AirDrop(winners, 20 ether);
        ecoInstance.airdrop(winners, 20 ether);
        vm.stopPrank();
        for (uint256 i = 0; i < winners.length; ++i) {
            uint256 bal = tokenInstance.balanceOf(address(winners[i]));
            assertEq(bal, 20 ether);
        }
    }

    function test_Airdrop_GasLimit() public {
        vm.deal(alice, 1 ether);

        address[] memory winners = new address[](4000);
        for (uint256 i = 0; i < 4000; ++i) {
            winners[i] = alice;
        }

        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 20 ether);
        uint256 bal = tokenInstance.balanceOf(alice);
        assertEq(bal, 80000 ether);
    }

    function test_Revert_Airdrop_Branch1() public {
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", pauser, MANAGER_ROLE);
        vm.prank(pauser);
        vm.expectRevert(expError); // access control
        ecoInstance.airdrop(winners, 20 ether);
    }

    function test_Revert_Airdrop_Branch2() public {
        assertEq(ecoInstance.paused(), false);
        vm.prank(pauser);
        ecoInstance.pause();

        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // contract paused
        ecoInstance.airdrop(winners, 20 ether);
    }

    function test_Revert_Airdrop_Branch3() public {
        address[] memory winners = new address[](5001);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "GAS_LIMIT");
        vm.prank(managerAdmin);
        // vm.expectRevert("GAS_LIMIT");
        vm.expectRevert(expError); // array too large
        ecoInstance.airdrop(winners, 1 ether);
    }

    function test_Revert_Airdrop_Branch4() public {
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "AIRDROP_SUPPLY_LIMIT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // supply exceeded
        ecoInstance.airdrop(winners, 2_000_000 ether);
    }

    function test_Reward() public {
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, managerAdmin);
        vm.startPrank(managerAdmin);
        vm.expectEmit(address(ecoInstance));
        emit Reward(managerAdmin, assetRecipient, 20 ether);
        ecoInstance.reward(assetRecipient, 20 ether);
        vm.stopPrank();
        uint256 bal = tokenInstance.balanceOf(assetRecipient);
        assertEq(bal, 20 ether);
    }

    function test_Revert_Reward_Branch1() public {
        uint256 maxReward = ecoInstance.maxReward();
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, REWARDER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError);
        ecoInstance.reward(assetRecipient, maxReward);
    }

    function test_Revert_Reward_Branch2() public {
        assertEq(ecoInstance.paused(), false);
        vm.prank(pauser);
        ecoInstance.pause();

        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, managerAdmin);
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // contract paused
        ecoInstance.reward(assetRecipient, 1 ether);
    }

    function test_Revert_Reward_Branch3() public {
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, managerAdmin);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.reward(assetRecipient, 0);
    }

    function test_Revert_Reward_Branch4() public {
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, managerAdmin);

        uint256 maxReward = ecoInstance.maxReward();
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "REWARD_LIMIT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.reward(assetRecipient, maxReward + 1 ether);
    }

    function test_Revert_Reward_Branch5() public {
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, managerAdmin);
        uint256 maxReward = ecoInstance.maxReward();
        vm.startPrank(managerAdmin);
        for (uint256 i = 0; i < 1000; ++i) {
            ecoInstance.reward(assetRecipient, maxReward);
        }
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "REWARD_SUPPLY_LIMIT");
        vm.expectRevert(expError);
        ecoInstance.reward(assetRecipient, 1 ether);
        vm.stopPrank();
    }

    function test_Burn() public {
        vm.prank(guardian);
        ecoInstance.grantRole(BURNER_ROLE, managerAdmin);
        uint256 startBal = tokenInstance.totalSupply();
        vm.startPrank(managerAdmin);
        vm.expectEmit(address(ecoInstance));
        emit Burn(address(managerAdmin), 20 ether);
        ecoInstance.burn(20 ether);
        vm.stopPrank();
        uint256 endBal = tokenInstance.totalSupply();
        assertEq(startBal, endBal + 20 ether);
    }

    function test_Revert_Burn_Branch1() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, BURNER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError);
        ecoInstance.burn(1 ether);
    }

    function test_Revert_Burn_Branch2() public {
        assertEq(ecoInstance.paused(), false);
        vm.prank(pauser);
        ecoInstance.pause();

        vm.prank(guardian);
        ecoInstance.grantRole(BURNER_ROLE, managerAdmin);

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // contract paused
        ecoInstance.burn(1 ether);
    }

    function test_Revert_Burn_Branch3() public {
        vm.prank(guardian);
        ecoInstance.grantRole(BURNER_ROLE, managerAdmin);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.burn(0);
    }

    function test_Revert_Burn_Branch4() public {
        vm.prank(guardian);
        ecoInstance.grantRole(BURNER_ROLE, managerAdmin);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "BURN_SUPPLY_LIMIT");
        vm.startPrank(managerAdmin);
        uint256 rewardSupply = ecoInstance.rewardSupply();

        vm.expectRevert(expError);
        ecoInstance.burn(rewardSupply + 1 ether);
        vm.stopPrank();
    }

    function test_Revert_Burn_Branch5() public {
        vm.prank(guardian);
        ecoInstance.grantRole(BURNER_ROLE, managerAdmin);
        uint256 amount = ecoInstance.maxBurn();
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "MAX_BURN_LIMIT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.burn(amount + 1 ether);
    }

    function test_AddPartner() public {
        uint256 vmprimer = 365 days;
        vm.warp(vmprimer);
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 8;
        vm.prank(managerAdmin);
        ecoInstance.addPartner(partner, amount);
        address vestingAddr = ecoInstance.vestingContracts(partner);
        uint256 bal = tokenInstance.balanceOf(vestingAddr);
        assertEq(bal, amount);
    }

    function test_Revert_AddPartner_Branch1() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", pauser, MANAGER_ROLE);
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 4;

        vm.prank(pauser);
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, amount);
    }

    function test_Revert_AddPartner_Branch2() public {
        assertEq(ecoInstance.paused(), false);
        vm.prank(pauser);
        ecoInstance.pause();

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // contract paused
        ecoInstance.addPartner(partner, 100 ether);
    }

    function test_Revert_AddPartner_Branch3() public {
        vm.prank(managerAdmin);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_ADDRESS");
        vm.expectRevert(expError);
        ecoInstance.addPartner(address(0), 100 ether);
    }

    function test_Revert_AddPartner_Branch4() public {
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 4;
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "PARTNER_EXISTS");
        vm.startPrank(managerAdmin);
        ecoInstance.addPartner(alice, amount);
        vm.expectRevert(expError); // adding same partner
        ecoInstance.addPartner(alice, amount);
        vm.stopPrank();
    }

    function test_Revert_AddPartner_Branch5() public {
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 2;
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, amount + 1 ether);
    }

    function test_Revert_AddPartner_Branch6() public {
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, 50 ether);
    }

    function test_Revert_AddPartner_Branch7() public {
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 2;
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "AMOUNT_EXCEEDS_SUPPLY");
        vm.startPrank(managerAdmin);
        ecoInstance.addPartner(alice, amount);
        ecoInstance.addPartner(bob, amount);
        vm.expectRevert(expError);
        ecoInstance.addPartner(charlie, 100 ether);
        vm.stopPrank();
    }
}
