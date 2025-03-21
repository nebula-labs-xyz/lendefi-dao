// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BasicDeploy} from "../BasicDeploy.sol";
import {GovernanceToken} from "../../contracts/ecosystem/GovernanceToken.sol";
import {GovernanceTokenV2} from "../../contracts/upgrades/GovernanceTokenV2.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract GovernanceTokenTest is BasicDeploy {
    uint256 internal vmprimer = 365 days;
    bytes32 internal constant TGE_ROLE = keccak256("TGE_ROLE");

    // Events
    event WithdrawEther(address to, uint256 amount);
    event WithdrawTokens(address to, uint256 amount);
    event BridgeMint(address indexed src, address indexed to, uint256 amount);
    event TGE(uint256 amount);
    event MaxBridgeUpdated(address indexed admin, uint256 oldMaxBridge, uint256 newMaxBridge);
    event UpgradeCancelled(address indexed canceller, address indexed implementation);

    // Define the error types directly
    error InvalidAddress(address provided, string reason);
    error ZeroAmount();
    error ZeroAddress();
    error BridgeAmountExceeded(uint256 requested, uint256 maxAllowed);
    error MaxSupplyExceeded(uint256 requested, uint256 maxAllowed);
    error TGEAlreadyInitialized();

    function setUp() public {
        deployComplete();
        assertEq(tokenInstance.totalSupply(), 0);

        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(MANAGER_ROLE, managerAdmin);
        vm.warp(vmprimer);
    }

    function test_TGE() public {
        _initializeTGE();
    }

    function testRevertInitializeTGE_ZeroAddress() public {
        vm.startPrank(guardian);

        // Test zero ecosystem address
        vm.expectRevert(abi.encodeWithSelector(InvalidAddress.selector, address(0), "Ecosystem address cannot be zero"));
        tokenInstance.initializeTGE(address(0), address(treasuryInstance));

        // Test zero treasury address
        vm.expectRevert(abi.encodeWithSelector(InvalidAddress.selector, address(0), "Treasury address cannot be zero"));
        tokenInstance.initializeTGE(address(ecoInstance), address(0));

        vm.stopPrank();
    }

    function testRevertInitializeTGE_AlreadyInitialized() public {
        vm.startPrank(guardian);
        // First initialization
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Attempt second initialization
        vm.expectRevert(TGEAlreadyInitialized.selector);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        vm.stopPrank();
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

        vm.prank(address(timelockInstance));
        tokenInstance.grantRole(BRIDGE_ROLE, bridge);
        vm.prank(bridge);
        vm.expectEmit();
        emit BridgeMint(bridge, alice, 20 ether);
        tokenInstance.bridgeMint(alice, 20 ether);
        assertEq(tokenInstance.balanceOf(alice), 100 ether);
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
        vm.prank(address(timelockInstance));
        tokenInstance.grantRole(BRIDGE_ROLE, bridge);
        // try to bridge
        vm.expectRevert(abi.encodeWithSelector(BridgeAmountExceeded.selector, amount, tokenInstance.maxBridge()));
        vm.prank(bridge);
        tokenInstance.bridgeMint(alice, amount);
    }

    function test_Revert_BridgeMint_Branch4() public {
        _initializeTGE();

        // Update maxBridge to the maximum allowed amount (1% of initial supply)
        uint256 maxAllowedBridge = tokenInstance.initialSupply() / 100;
        vm.prank(address(timelockInstance));
        tokenInstance.updateMaxBridgeAmount(maxAllowedBridge);

        // Make sure we're at max supply already - we shouldn't need to burn anything
        // as the TGE already minted all 50M tokens
        uint256 currentSupply = tokenInstance.totalSupply();
        assertEq(currentSupply, tokenInstance.initialSupply());

        // Use an amount that's UNDER the maxBridge limit but would still exceed supply
        uint256 bridgeAmount = maxAllowedBridge / 2; // 250K ether, well under the 500K bridge limit

        // Give proper access
        vm.prank(address(timelockInstance));
        tokenInstance.grantRole(BRIDGE_ROLE, bridge);

        // Calculate the new supply after this mint
        uint256 newSupplyAfterMint = currentSupply + bridgeAmount;

        // Try to bridge mint - should revert with MaxSupplyExceeded since we're already at max supply
        vm.expectRevert(
            abi.encodeWithSelector(MaxSupplyExceeded.selector, newSupplyAfterMint, tokenInstance.initialSupply())
        );
        vm.prank(bridge);
        tokenInstance.bridgeMint(alice, bridgeAmount);
    }

    function test_UpdateMaxBridgeAmount() public {
        uint256 oldMaxBridge = tokenInstance.maxBridge();
        uint256 newMaxBridge = 10_000 ether;

        vm.prank(address(timelockInstance));
        vm.expectEmit(address(tokenInstance));
        emit MaxBridgeUpdated(address(timelockInstance), oldMaxBridge, newMaxBridge);
        tokenInstance.updateMaxBridgeAmount(newMaxBridge);

        assertEq(tokenInstance.maxBridge(), newMaxBridge, "Max bridge amount should be updated");
    }

    function testRevert_UpdateMaxBridgeAmount_ZeroAmount() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(ZeroAmount.selector);
        tokenInstance.updateMaxBridgeAmount(0);
    }

    function testRevert_UpdateMaxBridgeAmount_Unauthorized() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, MANAGER_ROLE);

        vm.prank(alice);
        vm.expectRevert(expError);
        tokenInstance.updateMaxBridgeAmount(10_000 ether);
    }

    function testBridgeMint_WithUpdatedMaxAmount() public {
        _initializeTGE();

        // Burn a significant portion first to make room for a larger mint
        vm.prank(address(ecoInstance));
        tokenInstance.burn(20_000_000 ether);
        vm.prank(address(treasuryInstance));
        tokenInstance.burn(25_000_000 ether);

        // Current supply is 5M ether
        uint256 currentSupply = tokenInstance.totalSupply();
        assertEq(currentSupply, 5_000_000 ether);

        // Update max bridge amount to a higher value
        uint256 newMaxBridge = 30_000 ether;
        vm.prank(address(timelockInstance));
        tokenInstance.updateMaxBridgeAmount(newMaxBridge);

        // Setup bridge role
        vm.prank(address(timelockInstance));
        tokenInstance.grantRole(BRIDGE_ROLE, bridge);

        // Try to bridge with an amount between old and new limit
        uint256 bridgeAmount = 25_000 ether; // Between old (20k) and new (30k) limits
        vm.prank(bridge);
        tokenInstance.bridgeMint(alice, bridgeAmount);

        assertEq(tokenInstance.balanceOf(alice), bridgeAmount, "Bridge mint should succeed with updated limit");
    }

    function testRevert_BridgeMint_ZeroAddress() public {
        _initializeTGE();

        // Grant bridge role
        vm.prank(address(timelockInstance));
        tokenInstance.grantRole(BRIDGE_ROLE, bridge);

        // Try to mint to zero address
        vm.prank(bridge);
        vm.expectRevert(ZeroAddress.selector);
        tokenInstance.bridgeMint(address(0), 100 ether);
    }

    function testRevert_BridgeMint_ZeroAmount() public {
        _initializeTGE();

        // Grant bridge role
        vm.prank(address(timelockInstance));
        tokenInstance.grantRole(BRIDGE_ROLE, bridge);

        // Try to mint zero tokens
        vm.prank(bridge);
        vm.expectRevert(ZeroAmount.selector);
        tokenInstance.bridgeMint(alice, 0);
    }

    function testRevert_BridgeMint_WhenPaused() public {
        _initializeTGE();

        // Grant bridge role
        vm.prank(address(timelockInstance));
        tokenInstance.grantRole(BRIDGE_ROLE, bridge);

        // Pause the contract
        vm.prank(address(timelockInstance));
        tokenInstance.pause();

        // Try to bridge mint while paused
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(bridge);
        vm.expectRevert(expError);
        tokenInstance.bridgeMint(alice, 100 ether);
    }

    function test_PauseUnpause() public {
        _initializeTGE();

        // Test pause functionality
        vm.prank(address(timelockInstance));
        tokenInstance.pause();
        assertTrue(tokenInstance.paused());

        // Test unpause functionality
        vm.prank(address(timelockInstance));
        tokenInstance.unpause();
        assertFalse(tokenInstance.paused());
    }

    function testRevert_Pause_Unauthorized() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, PAUSER_ROLE);

        vm.prank(alice);
        vm.expectRevert(expError);
        tokenInstance.pause();
    }

    function testRevert_Unpause_Unauthorized() public {
        // First pause the contract
        vm.prank(address(timelockInstance));
        tokenInstance.pause();

        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, PAUSER_ROLE);

        vm.prank(alice);
        vm.expectRevert(expError);
        tokenInstance.unpause();
    }

    function testRevert_TransferWhenPaused() public {
        _initializeTGE();

        // Transfer some tokens to alice
        vm.prank(address(ecoInstance));
        tokenInstance.transfer(alice, 100 ether);

        // Pause the contract
        vm.prank(address(timelockInstance));
        tokenInstance.pause();

        // Try to transfer while paused
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(alice);
        vm.expectRevert(expError);
        tokenInstance.transfer(bob, 50 ether);
    }

    function testRevert_AuthorizeUpgrade_Unauthorized() public {
        // token deploy
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian, address(timelockInstance)));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);

        // upgrade token
        vm.prank(address(timelockInstance));
        tokenInstance.grantRole(UPGRADER_ROLE, managerAdmin);

        // Mock call for upgrade attempt to test authorization check only
        // This avoids trying to deploy GovernanceTokenV2.sol
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, UPGRADER_ROLE);

        // Directly attempt to call upgradeTo (internal UUPSUpgradeable function)
        vm.prank(alice);
        vm.expectRevert(expError);
        // Instead of trying to deploy V2, just use a random address
        (bool success,) = address(tokenInstance).call(abi.encodeWithSignature("upgradeTo(address)", address(0x123)));
        // Since we're expecting a revert, success should be false
        assertFalse(success);
    }

    function test_SuccessfulUpgrade() public {
        deployTokenUpgrade();
    }

    function testRevertInitializeTGE_Unauthorized() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, TGE_ROLE);

        vm.prank(alice);
        vm.expectRevert(expError);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
    }

    //Test: RevertReceive
    function testRevert_Receive() public returns (bool success) {
        vm.expectRevert(abi.encodeWithSignature("ValidationFailed(string)", "NO_ETHER_ACCEPTED")); // contract does not receive ether
        (success,) = payable(address(tokenInstance)).call{value: 100 ether}("");
    }

    function test_Revert_InitializeUUPS() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        tokenInstance.initializeUUPS(guardian, address(timelockInstance));
    }

    function test_Transfer() public {
        _initializeTGE();

        // Transfer some tokens from ecosystem to alice
        uint256 transferAmount = 100 ether;
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), alice, transferAmount);

        // Check balances
        assertEq(tokenInstance.balanceOf(alice), transferAmount);
        assertEq(tokenInstance.balanceOf(address(treasuryInstance)), 27_400_000 ether - transferAmount);
    }

    function test_RoleManagement() public {
        // Test granting roles
        vm.prank(address(timelockInstance));
        tokenInstance.grantRole(PAUSER_ROLE, pauser);
        assertTrue(tokenInstance.hasRole(PAUSER_ROLE, pauser));

        // Test revoking roles
        vm.prank(address(timelockInstance));
        tokenInstance.revokeRole(PAUSER_ROLE, pauser);
        assertFalse(tokenInstance.hasRole(PAUSER_ROLE, pauser));
    }

    /**
     * @notice Tests successful cancellation of a scheduled upgrade
     */
    function testCancelUpgrade() public {
        // Schedule an upgrade first
        address newImpl = address(0x1234);
        vm.prank(address(timelockInstance));
        tokenInstance.scheduleUpgrade(newImpl);

        // Verify upgrade is scheduled
        assertTrue(tokenInstance.upgradeTimelockRemaining() > 0);

        // Cancel the upgrade
        vm.prank(address(timelockInstance));
        vm.expectEmit(true, true, false, false);
        emit UpgradeCancelled(address(timelockInstance), newImpl);
        tokenInstance.cancelUpgrade();

        // Verify upgrade is cancelled (upgradeTimelockRemaining should be 0)
        assertEq(tokenInstance.upgradeTimelockRemaining(), 0);

        // Verify pendingUpgrade struct is cleared
        (address impl, uint64 scheduledTime, bool exists) = tokenInstance.pendingUpgrade();
        assertFalse(exists);
        assertEq(impl, address(0));
        assertEq(scheduledTime, 0);
    }

    /**
     * @notice Tests that cancelUpgrade reverts when no upgrade is scheduled
     */
    function testRevert_CancelUpgrade_NoScheduledUpgrade() public {
        // Attempt to cancel when no upgrade is scheduled
        vm.prank(address(timelockInstance));
        vm.expectRevert(GovernanceToken.UpgradeNotScheduled.selector);
        tokenInstance.cancelUpgrade();
    }

    /**
     * @notice Tests that cancelUpgrade reverts when called by unauthorized account
     */
    function testRevert_CancelUpgrade_Unauthorized() public {
        // Schedule an upgrade first
        address newImpl = address(0x1234);
        vm.prank(address(timelockInstance));
        tokenInstance.scheduleUpgrade(newImpl);

        // Try to cancel from non-upgrader account
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, UPGRADER_ROLE);

        vm.prank(alice);
        vm.expectRevert(expError);
        tokenInstance.cancelUpgrade();

        // Verify upgrade is still scheduled
        assertTrue(tokenInstance.upgradeTimelockRemaining() > 0);
    }

    /**
     * @notice Tests scheduling a new upgrade after cancellation
     */
    function testScheduleAfterCancellation() public {
        // Schedule first upgrade
        address firstImpl = address(0x1234);
        vm.prank(address(timelockInstance));
        tokenInstance.scheduleUpgrade(firstImpl);

        // Cancel the upgrade
        vm.prank(address(timelockInstance));
        tokenInstance.cancelUpgrade();

        // Schedule a new upgrade
        address secondImpl = address(0x5678);
        vm.prank(address(timelockInstance));
        tokenInstance.scheduleUpgrade(secondImpl);

        // Verify new upgrade is scheduled
        assertTrue(tokenInstance.upgradeTimelockRemaining() > 0);

        // Verify correct implementation is scheduled
        (address impl,,) = tokenInstance.pendingUpgrade();
        assertEq(impl, secondImpl);
    }

    /**
     * @notice Tests that upgrade fails after cancellation
     */
    function testRevert_UpgradeAfterCancellation() public {
        // Schedule an upgrade
        address newImpl = address(0x1234);
        vm.prank(address(timelockInstance));
        tokenInstance.scheduleUpgrade(newImpl);

        // Wait for timelock to expire
        vm.warp(block.timestamp + 3 days + 1);

        // Cancel the upgrade
        vm.prank(address(timelockInstance));
        tokenInstance.cancelUpgrade();

        // Try to upgrade - should fail because upgrade was cancelled
        vm.prank(address(timelockInstance));
        vm.expectRevert(GovernanceToken.UpgradeNotScheduled.selector);
        tokenInstance.upgradeToAndCall(newImpl, "");
    }

    function _initializeTGE() internal {
        // this is the TGE
        vm.prank(guardian);
        vm.expectEmit();
        emit TGE(INITIAL_SUPPLY);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        uint256 ecoBal = tokenInstance.balanceOf(address(ecoInstance));
        uint256 treasuryBal = tokenInstance.balanceOf(address(treasuryInstance));
        uint256 guardianBal = tokenInstance.balanceOf(guardian);

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 27_400_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal + guardianBal);
    }
}
