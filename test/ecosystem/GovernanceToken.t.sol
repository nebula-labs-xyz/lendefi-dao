// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BasicDeploy} from "../BasicDeploy.sol";

contract GovernanceTokenTest is BasicDeploy {
    uint256 internal vmprimer = 365 days;

    event WithdrawEther(address to, uint256 amount);
    event WithdrawTokens(address to, uint256 amount);
    event BridgeMint(address indexed src, address indexed to, uint256 amount);
    event TGE(uint256 amount);

    function setUp() public {
        deployComplete();
        assertEq(tokenInstance.totalSupply(), 0);

        vm.prank(guardian);
        ecoInstance.grantRole(MANAGER_ROLE, managerAdmin);
    }

    function test_TGE() public {
        _initializeTGE();
    }

    function testRevertInitializeTGE_ZeroAddress() public {
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "ZERO_ADDRESS");

        vm.startPrank(guardian);

        // Test zero ecosystem address
        vm.expectRevert(expError);
        tokenInstance.initializeTGE(address(0), address(treasuryInstance));

        // Test zero treasury address
        vm.expectRevert(expError);
        tokenInstance.initializeTGE(address(ecoInstance), address(0));

        // Test both zero addresses
        vm.expectRevert(expError);
        tokenInstance.initializeTGE(address(0), address(0));

        vm.stopPrank();
    }

    function testRevertInitializeTGE_AlreadyInitialized() public {
        vm.startPrank(guardian);
        // First initialization
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Attempt second initialization
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "TGE_ALREADY_INITIALIZED");
        vm.expectRevert(expError);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        vm.stopPrank();
    }

    function testRevertInitializeTGE_Unauthorized() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, DEFAULT_ADMIN_ROLE);

        vm.prank(alice);
        vm.expectRevert(expError);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
    }

    function test_Burn() public {
        _initializeTGE();
        // get some tokens
        vm.deal(alice, 1 ether);
        address[] memory winners = new address[](1);
        winners[0] = alice;
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 100 ether);

        vm.prank(alice);
        tokenInstance.burn(20 ether);
        assertEq(tokenInstance.balanceOf(alice), 80 ether);
    }

    function test_Revert_Receive() public returns (bool success) {
        vm.expectRevert(); // contract does not receive ether
        (success,) = payable(address(tokenInstance)).call{value: 100 ether}("");
    }

    function test_Revert_InitializeUUPS() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        tokenInstance.initializeUUPS(guardian);
    }

    function test_Pause() public {
        vm.prank(guardian);
        tokenInstance.grantRole(PAUSER_ROLE, pauser);
        assertEq(tokenInstance.paused(), false);
        vm.startPrank(pauser);
        tokenInstance.pause();
        assertEq(tokenInstance.paused(), true);
        tokenInstance.unpause();
        vm.stopPrank();
        assertEq(tokenInstance.paused(), false);
    }

    function test_Revert_Pause_Branch1() public {
        assertEq(tokenInstance.paused(), false);

        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", managerAdmin, PAUSER_ROLE);

        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        tokenInstance.pause();
    }

    function test_Revert_Transfer_Branch1() public {
        _initializeTGE();
        // get some tokens
        vm.deal(alice, 1 ether);
        address[] memory winners = new address[](1);
        winners[0] = alice;
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 20 ether);

        // pause the token contract
        vm.prank(guardian);
        tokenInstance.grantRole(PAUSER_ROLE, pauser);
        assertEq(tokenInstance.paused(), false);
        vm.prank(pauser);
        tokenInstance.pause();

        // try to make a transfer
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(alice);
        vm.expectRevert(expError); // contract paused
        tokenInstance.transfer(bob, 10 ether);
    }

    function test_BridgeMint() public {
        _initializeTGE();
        // get some tokens
        vm.deal(alice, 1 ether);
        address[] memory winners = new address[](1);
        winners[0] = alice;
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 100 ether);

        vm.prank(alice);
        tokenInstance.burn(20 ether);
        assertEq(tokenInstance.balanceOf(alice), 80 ether);

        vm.prank(guardian);
        tokenInstance.grantRole(BRIDGE_ROLE, bridge);
        vm.prank(bridge);
        vm.expectEmit();
        emit BridgeMint(bridge, alice, 20 ether);
        tokenInstance.bridgeMint(alice, 20 ether);
        assertEq(tokenInstance.balanceOf(alice), 100 ether);
    }

    function test_Revert_BridgeMint_Branch1() public {
        _initializeTGE();
        // get some tokens
        vm.deal(alice, 1 ether);
        address[] memory winners = new address[](1);
        winners[0] = alice;
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 100 ether);

        vm.prank(alice);
        tokenInstance.burn(20 ether);
        assertEq(tokenInstance.balanceOf(alice), 80 ether);

        vm.prank(guardian);
        tokenInstance.grantRole(BRIDGE_ROLE, bridge);
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", managerAdmin, BRIDGE_ROLE);
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        tokenInstance.bridgeMint(alice, 20 ether);
    }

    function test_Revert_BridgeMint_Branch2() public {
        _initializeTGE();
        // get some tokens
        vm.deal(alice, 1 ether);
        address[] memory winners = new address[](1);
        winners[0] = alice;
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 100 ether);
        vm.prank(alice);
        tokenInstance.burn(20 ether);
        assertEq(tokenInstance.balanceOf(alice), 80 ether);
        // give proper access and pause
        vm.startPrank(guardian);
        tokenInstance.grantRole(BRIDGE_ROLE, bridge);
        tokenInstance.grantRole(PAUSER_ROLE, pauser);
        assertEq(tokenInstance.paused(), false);
        vm.stopPrank();
        vm.prank(pauser);
        tokenInstance.pause();
        assertEq(tokenInstance.paused(), true);
        // try to bridge
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(bridge);
        vm.expectRevert(expError); // Contract paused
        tokenInstance.bridgeMint(alice, 20 ether);
    }

    function test_Revert_BridgeMint_Branch3() public {
        _initializeTGE();
        uint256 amount = 20_001 ether;
        // get some tokens
        vm.deal(alice, 1 ether);
        address[] memory winners = new address[](1);
        winners[0] = alice;
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, amount);

        // give proper access
        vm.prank(guardian);
        tokenInstance.grantRole(BRIDGE_ROLE, bridge);
        // try to bridge
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "BRIDGE_LIMIT");
        vm.prank(bridge);
        vm.expectRevert(expError); // exceeded bridge limit
        tokenInstance.bridgeMint(alice, amount);
    }

    function test_Revert_BridgeMint_Branch4() public {
        _initializeTGE();
        // get some tokens
        vm.deal(alice, 1 ether);
        address[] memory winners = new address[](1);
        winners[0] = alice;
        vm.prank(managerAdmin);
        ecoInstance.airdrop(winners, 10000 ether);
        vm.prank(alice);
        tokenInstance.burn(5000 ether);
        assertEq(tokenInstance.balanceOf(alice), 5000 ether);
        // give proper access
        vm.prank(guardian);
        tokenInstance.grantRole(BRIDGE_ROLE, bridge);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "BRIDGE_PROBLEM");
        // try to bridge
        vm.prank(bridge);
        vm.expectRevert(expError); // compromised bridge
        tokenInstance.bridgeMint(alice, 5001 ether);
    }

    function _initializeTGE() internal {
        // this is the TGE
        vm.prank(guardian);
        vm.expectEmit();
        emit TGE(INITIAL_SUPPLY);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        uint256 ecoBal = tokenInstance.balanceOf(address(ecoInstance));
        uint256 treasuryBal = tokenInstance.balanceOf(address(treasuryInstance));

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 28_000_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal);
    }
}
