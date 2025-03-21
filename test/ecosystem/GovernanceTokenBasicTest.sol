// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {GovernanceToken} from "../../contracts/ecosystem/GovernanceToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract GovernanceTokenBasicTest is Test {
    // Contract instances
    GovernanceToken public tokenImpl;
    GovernanceToken public tokenInstance;

    // Test addresses
    address public guardian = address(0x1111);
    address public timelock = address(0x2222);
    address public ecosystem = address(0x4444);
    address public treasury = address(0x5555);
    address public alice = address(0x6666);
    address public bob = address(0x7777);
    address public bridge = address(0x8888);

    // Constants
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant TGE_ROLE = keccak256("TGE_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    uint256 public constant INITIAL_SUPPLY = 50_000_000 ether;
    uint256 public constant DEFAULT_MAX_BRIDGE_AMOUNT = 5_000 ether;
    uint256 public constant TREASURY_SHARE = 27_400_000 ether;
    uint256 public constant ECOSYSTEM_SHARE = 22_000_000 ether;
    uint256 public constant DEPLOYER_SHARE = 600_000 ether;
    uint256 public constant UPGRADE_TIMELOCK_DURATION = 3 days;

    // Events
    event Initialized(address indexed src);
    event TGE(uint256 amount);
    event BridgeMint(address indexed src, address indexed to, uint256 amount);
    event MaxBridgeUpdated(address indexed admin, uint256 oldMaxBridge, uint256 newMaxBridge);
    event BridgeRoleAssigned(address indexed admin, address indexed bridgeAddress);
    event UpgradeScheduled(
        address indexed sender, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );
    event Upgrade(address indexed src, address indexed implementation);
    event Paused(address account);
    event Unpaused(address account);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);

    function setUp() public {
        vm.label(guardian, "Guardian");
        vm.label(timelock, "Timelock");
        vm.label(timelock, "timelock");
        vm.label(ecosystem, "Ecosystem");
        vm.label(treasury, "Treasury");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(bridge, "Bridge");

        // Deploy implementation
        tokenImpl = new GovernanceToken();

        // Deploy proxy and initialize
        bytes memory initData = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian, timelock));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", initData));
        tokenInstance = GovernanceToken(proxy);
    }

    // ========== Initialization Tests ==========

    function testInitialization() public {
        // Basic token details
        assertEq(tokenInstance.name(), "Lendefi DAO");
        assertEq(tokenInstance.symbol(), "LEND");
        assertEq(tokenInstance.decimals(), 18);
        assertEq(tokenInstance.version(), 1);
        assertEq(tokenInstance.totalSupply(), 0);

        // Configuration values
        assertEq(tokenInstance.initialSupply(), INITIAL_SUPPLY);
        assertEq(tokenInstance.maxBridge(), DEFAULT_MAX_BRIDGE_AMOUNT);
        assertEq(tokenInstance.tge(), 0);

        // Roles
        assertTrue(tokenInstance.hasRole(DEFAULT_ADMIN_ROLE, timelock));
        assertTrue(tokenInstance.hasRole(TGE_ROLE, guardian));
        assertTrue(tokenInstance.hasRole(PAUSER_ROLE, timelock));
        assertTrue(tokenInstance.hasRole(UPGRADER_ROLE, timelock));
        assertTrue(tokenInstance.hasRole(MANAGER_ROLE, timelock));

        // Upgrade state
        (address impl, uint64 scheduledTime, bool exists) = tokenInstance.pendingUpgrade();
        assertEq(impl, address(0));
        assertEq(scheduledTime, 0);
        assertFalse(exists);
    }

    function testInitializeWithZeroAddresses() public {
        GovernanceToken newImpl = new GovernanceToken();

        // Zero guardian
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (address(0), timelock));
        vm.expectRevert(GovernanceToken.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), data);

        // Zero timelock
        data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian, address(0)));
        vm.expectRevert(GovernanceToken.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), data);
    }

    function testCannotReinitialize() public {
        // FIX #1: Use InvalidInitialization selector instead of string error
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        tokenInstance.initializeUUPS(guardian, timelock);
    }

    function testRevert_Receive() public returns (bool success) {
        vm.expectRevert(abi.encodeWithSignature("ValidationFailed(string)", "NO_ETHER_ACCEPTED")); // contract does not receive ether
        (success,) = payable(address(tokenInstance)).call{value: 100 ether}("");
    }
    // ========== TGE Tests ==========

    function testInitializeTGE() public {
        // Pre-TGE state
        assertEq(tokenInstance.tge(), 0);
        assertEq(tokenInstance.totalSupply(), 0);
        assertEq(tokenInstance.balanceOf(ecosystem), 0);
        assertEq(tokenInstance.balanceOf(treasury), 0);
        assertEq(tokenInstance.balanceOf(guardian), 0);

        // Initialize TGE
        vm.prank(guardian);
        vm.expectEmit(false, false, false, true);
        emit TGE(INITIAL_SUPPLY);
        tokenInstance.initializeTGE(ecosystem, treasury);

        // Post-TGE state
        assertEq(tokenInstance.tge(), 1);
        assertEq(tokenInstance.totalSupply(), TREASURY_SHARE + ECOSYSTEM_SHARE + DEPLOYER_SHARE);
        assertEq(tokenInstance.balanceOf(ecosystem), ECOSYSTEM_SHARE);
        assertEq(tokenInstance.balanceOf(treasury), TREASURY_SHARE);
        assertEq(tokenInstance.balanceOf(guardian), DEPLOYER_SHARE);
    }

    function testRevert_TGEWithZeroAddresses() public {
        // Zero ecosystem
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceToken.InvalidAddress.selector, address(0), "Ecosystem address cannot be zero"
            )
        );
        tokenInstance.initializeTGE(address(0), treasury);

        // Zero treasury
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceToken.InvalidAddress.selector, address(0), "Treasury address cannot be zero"
            )
        );
        tokenInstance.initializeTGE(ecosystem, address(0));
    }

    function testRevert_TGEAlreadyInitialized() public {
        // First TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(ecosystem, treasury);

        // Try second TGE
        vm.prank(guardian);
        vm.expectRevert(GovernanceToken.TGEAlreadyInitialized.selector);
        tokenInstance.initializeTGE(ecosystem, treasury);
    }

    function testRevert_UnauthorizedTGE() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, TGE_ROLE)
        );
        tokenInstance.initializeTGE(ecosystem, treasury);
    }

    // ========== Pause Tests ==========

    function testPauseAndUnpause() public {
        // Initially not paused
        assertFalse(tokenInstance.paused());

        // Pause
        vm.prank(timelock);
        vm.expectEmit(true, false, false, false);
        emit Paused(timelock);
        tokenInstance.pause();
        assertTrue(tokenInstance.paused());

        // Unpause
        vm.prank(timelock);
        vm.expectEmit(true, false, false, false);
        emit Unpaused(timelock);
        tokenInstance.unpause();
        assertFalse(tokenInstance.paused());
    }

    function testRevert_UnauthorizedPause() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, PAUSER_ROLE)
        );
        tokenInstance.pause();
    }

    function testRevert_UnauthorizedUnpause() public {
        // First pause
        vm.prank(timelock);
        tokenInstance.pause();

        // Try unauthorized unpause
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, PAUSER_ROLE)
        );
        tokenInstance.unpause();
    }

    // ========== Bridge Tests ==========

    function testSetBridgeAddress() public {
        vm.prank(timelock);
        vm.expectEmit(true, true, false, false);
        emit BridgeRoleAssigned(timelock, bridge);
        tokenInstance.setBridgeAddress(bridge);

        assertTrue(tokenInstance.hasRole(BRIDGE_ROLE, bridge));
    }

    function testRevert_SetBridgeAddressZero() public {
        vm.prank(timelock);
        vm.expectRevert(GovernanceToken.ZeroAddress.selector);
        tokenInstance.setBridgeAddress(address(0));
    }

    function testRevert_UnauthorizedSetBridge() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, MANAGER_ROLE)
        );
        tokenInstance.setBridgeAddress(bridge);
    }

    function testBridgeMint() public {
        // Setup bridge role
        vm.prank(timelock);
        tokenInstance.setBridgeAddress(bridge);

        // Perform bridge mint
        vm.prank(bridge);
        vm.expectEmit(true, true, false, true);
        emit BridgeMint(bridge, alice, 1000 ether);
        tokenInstance.bridgeMint(alice, 1000 ether);

        assertEq(tokenInstance.balanceOf(alice), 1000 ether);
        assertEq(tokenInstance.totalSupply(), 1000 ether);
    }

    function testRevert_BridgeMintZeroAddress() public {
        // Setup bridge role
        vm.prank(timelock);
        tokenInstance.setBridgeAddress(bridge);

        // Try to mint to zero address
        vm.prank(bridge);
        vm.expectRevert(GovernanceToken.ZeroAddress.selector);
        tokenInstance.bridgeMint(address(0), 1000 ether);
    }

    function testRevert_BridgeMintZeroAmount() public {
        // Setup bridge role
        vm.prank(timelock);
        tokenInstance.setBridgeAddress(bridge);

        // Try to mint zero amount
        vm.prank(bridge);
        vm.expectRevert(GovernanceToken.ZeroAmount.selector);
        tokenInstance.bridgeMint(alice, 0);
    }

    function testRevert_BridgeMintExceedsMaxBridge() public {
        // Setup bridge role
        vm.prank(timelock);
        tokenInstance.setBridgeAddress(bridge);

        // Try to mint more than maxBridge
        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceToken.BridgeAmountExceeded.selector, DEFAULT_MAX_BRIDGE_AMOUNT + 1, DEFAULT_MAX_BRIDGE_AMOUNT
            )
        );
        tokenInstance.bridgeMint(alice, DEFAULT_MAX_BRIDGE_AMOUNT + 1);
    }

    function testRevert_BridgeMintExceedsMaxSupply() public {
        // First do TGE to get most of supply minted
        vm.prank(guardian);
        tokenInstance.initializeTGE(ecosystem, treasury);

        // Setup bridge role
        vm.prank(timelock);
        tokenInstance.setBridgeAddress(bridge);

        // Increase maxBridge to allow larger amounts
        vm.prank(timelock);
        uint256 newMaxBridge = 500_000 ether; // Max allowed (1% of supply)
        tokenInstance.updateMaxBridgeAmount(newMaxBridge);

        // Calculate current supply after TGE
        uint256 currentSupply = tokenInstance.totalSupply();

        // Try to mint exactly 1 more than the remaining supply
        uint256 remainingSupply = INITIAL_SUPPLY - currentSupply;
        uint256 mintAmount = remainingSupply + 1;

        // Should be less than maxBridge but more than remaining supply
        require(mintAmount <= newMaxBridge, "Test setup error: amount exceeds maxBridge");

        // Try to mint more than remaining supply

        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceToken.MaxSupplyExceeded.selector, currentSupply + mintAmount, INITIAL_SUPPLY
            )
        );
        vm.prank(bridge);
        tokenInstance.bridgeMint(alice, mintAmount);
    }

    function testRevert_BridgeMintWhenPaused() public {
        // Setup bridge role
        vm.prank(timelock);
        tokenInstance.setBridgeAddress(bridge);

        // Pause contract
        vm.prank(address(timelock));
        tokenInstance.pause();

        // FIX #4: Use PausableUpgradeable.EnforcedPause.selector instead of string
        vm.prank(bridge);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        tokenInstance.bridgeMint(alice, 1000 ether);
    }

    function testUpdateMaxBridgeAmount() public {
        uint256 newMaxBridge = 10_000 ether;

        vm.prank(timelock);
        vm.expectEmit(true, false, false, true);
        emit MaxBridgeUpdated(timelock, DEFAULT_MAX_BRIDGE_AMOUNT, newMaxBridge);
        tokenInstance.updateMaxBridgeAmount(newMaxBridge);

        assertEq(tokenInstance.maxBridge(), newMaxBridge);
    }

    function testRevert_UpdateMaxBridgeZeroAmount() public {
        vm.prank(timelock);
        vm.expectRevert(GovernanceToken.ZeroAmount.selector);
        tokenInstance.updateMaxBridgeAmount(0);
    }

    function testRevert_UpdateMaxBridgeTooHigh() public {
        // More than 1% of supply
        uint256 tooHighAmount = INITIAL_SUPPLY / 100 + 1;

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(GovernanceToken.ValidationFailed.selector, "Bridge amount too high"));
        tokenInstance.updateMaxBridgeAmount(tooHighAmount);
    }

    function testRevert_UnauthorizedUpdateMaxBridge() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, MANAGER_ROLE)
        );
        tokenInstance.updateMaxBridgeAmount(10_000 ether);
    }

    // ========== Upgrade Tests ==========

    function testScheduleUpgrade() public {
        address newImpl = address(0x9999);

        vm.prank(timelock);
        vm.expectEmit(true, true, true, true);
        emit UpgradeScheduled(
            timelock, newImpl, uint64(block.timestamp), uint64(block.timestamp + UPGRADE_TIMELOCK_DURATION)
        );
        tokenInstance.scheduleUpgrade(newImpl);

        (address impl, uint64 scheduledTime, bool exists) = tokenInstance.pendingUpgrade();
        assertEq(impl, newImpl);
        assertEq(scheduledTime, block.timestamp);
        assertTrue(exists);
    }

    function testRevert_ScheduleUpgradeZeroAddress() public {
        vm.prank(timelock);
        vm.expectRevert(GovernanceToken.ZeroAddress.selector);
        tokenInstance.scheduleUpgrade(address(0));
    }

    function testRevert_ScheduleUpgradeUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, UPGRADER_ROLE)
        );
        tokenInstance.scheduleUpgrade(address(0x9999));
    }

    function testUpgradeTimelockRemaining() public {
        // Nothing scheduled yet
        assertEq(tokenInstance.upgradeTimelockRemaining(), 0);

        // Schedule upgrade
        address newImpl = address(0x9999);
        vm.prank(timelock);
        tokenInstance.scheduleUpgrade(newImpl);

        // Check remaining time right after scheduling
        assertEq(tokenInstance.upgradeTimelockRemaining(), UPGRADE_TIMELOCK_DURATION);

        // Warp forward 1 day and check again
        vm.warp(block.timestamp + 1 days);
        assertEq(tokenInstance.upgradeTimelockRemaining(), 2 days);

        // Warp past timelock
        vm.warp(block.timestamp + 2 days);
        assertEq(tokenInstance.upgradeTimelockRemaining(), 0);
    }

    function testRevert_UpgradeTimelockActive() public {
        address newImpl = address(0x9999);

        // Schedule upgrade
        vm.prank(timelock);
        tokenInstance.scheduleUpgrade(newImpl);

        // Try to upgrade immediately - FIX #6: Use correct error selector
        uint256 remaining = tokenInstance.upgradeTimelockRemaining();
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(GovernanceToken.UpgradeTimelockActive.selector, remaining));
        tokenInstance.upgradeToAndCall(newImpl, "");
    }

    function testRevert_UpgradeNotScheduled() public {
        address newImpl = address(0x9999);

        // Try to upgrade without scheduling
        vm.prank(timelock);
        vm.expectRevert(GovernanceToken.UpgradeNotScheduled.selector);
        tokenInstance.upgradeToAndCall(newImpl, "");
    }

    function testRevert_UpgradeImplementationMismatch() public {
        address scheduledImpl = address(0x9999);
        address differentImpl = address(0xAAAA);

        // Schedule upgrade
        vm.prank(timelock);
        tokenInstance.scheduleUpgrade(scheduledImpl);

        // Warp past timelock
        vm.warp(block.timestamp + UPGRADE_TIMELOCK_DURATION + 1);

        // Try to upgrade with different implementation
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(GovernanceToken.ImplementationMismatch.selector, scheduledImpl, differentImpl)
        );
        tokenInstance.upgradeToAndCall(differentImpl, "");
    }

    function testRevert_UpgradeUnauthorized() public {
        address newImpl = address(0x9999);

        // Schedule upgrade
        vm.prank(timelock);
        tokenInstance.scheduleUpgrade(newImpl);

        // Warp past timelock
        vm.warp(block.timestamp + UPGRADE_TIMELOCK_DURATION + 1);

        // Try to upgrade from unauthorized address
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, UPGRADER_ROLE)
        );
        tokenInstance.upgradeToAndCall(newImpl, "");
    }

    // ========== ERC20Votes Tests ==========

    function testDelegation() public {
        // First do TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(ecosystem, treasury);

        // Check initial voting power
        assertEq(tokenInstance.getVotes(alice), 0);
        assertEq(tokenInstance.getVotes(bob), 0);

        // Transfer some tokens to alice
        vm.prank(ecosystem);
        tokenInstance.transfer(alice, 1000 ether);

        // Alice delegates to herself
        vm.prank(alice);
        tokenInstance.delegate(alice);

        // Verify voting power updated
        assertEq(tokenInstance.getVotes(alice), 1000 ether);

        // Alice delegates to bob
        vm.prank(alice);
        tokenInstance.delegate(bob);

        // Verify voting power transferred
        assertEq(tokenInstance.getVotes(alice), 0);
        assertEq(tokenInstance.getVotes(bob), 1000 ether);
    }

    function testVotingPowerHistorical() public {
        // First do TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(ecosystem, treasury);

        // Transfer to alice and self-delegate
        vm.prank(ecosystem);
        tokenInstance.transfer(alice, 1000 ether);
        vm.prank(alice);
        tokenInstance.delegate(alice);
        uint256 checkpoint1Block = block.number;

        // Move to next block and increase alice's balance
        vm.roll(block.number + 1);
        vm.prank(ecosystem);
        tokenInstance.transfer(alice, 500 ether);
        uint256 checkpoint2Block = block.number;

        // Move to next block and verify historical voting power
        vm.roll(block.number + 1);
        assertEq(tokenInstance.getPastVotes(alice, checkpoint1Block), 1000 ether);
        assertEq(tokenInstance.getPastVotes(alice, checkpoint2Block), 1500 ether);
        assertEq(tokenInstance.getVotes(alice), 1500 ether);
    }

    // ========== Transfer Tests ==========

    function testTransferEmitsEvents() public {
        // First do TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(ecosystem, treasury);

        // Transfer from ecosystem to alice
        vm.prank(ecosystem);
        vm.expectEmit(true, true, false, true);
        emit Transfer(ecosystem, alice, 1000 ether);
        tokenInstance.transfer(alice, 1000 ether);

        assertEq(tokenInstance.balanceOf(alice), 1000 ether);
    }

    function testTransferFromWithApproval() public {
        // First do TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(ecosystem, treasury);

        // Transfer to alice
        vm.prank(ecosystem);
        tokenInstance.transfer(alice, 1000 ether);

        // Alice approves bob
        vm.prank(alice);
        tokenInstance.approve(bob, 500 ether);

        // Bob transfers from Alice to himself
        vm.prank(bob);
        tokenInstance.transferFrom(alice, bob, 500 ether);

        assertEq(tokenInstance.balanceOf(alice), 500 ether);
        assertEq(tokenInstance.balanceOf(bob), 500 ether);
    }

    function testRevert_TransferPaused() public {
        // First do TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(ecosystem, treasury);

        // Transfer to alice
        vm.prank(ecosystem);
        tokenInstance.transfer(alice, 1000 ether);

        // Pause the contract
        vm.prank(address(timelock));
        tokenInstance.pause();

        // Try to transfer while paused
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        tokenInstance.transfer(bob, 500 ether);
    }

    // ========== Additional Edge Cases ==========

    function testMultipleUpgradeScheduling() public {
        address impl1 = address(0x9999);
        address impl2 = address(0xAAAA);

        // Schedule first upgrade
        vm.prank(timelock);
        tokenInstance.scheduleUpgrade(impl1);

        // Schedule second upgrade (should override first one)
        vm.prank(timelock);
        tokenInstance.scheduleUpgrade(impl2);

        // Check that second implementation is stored
        (address impl,, bool exists) = tokenInstance.pendingUpgrade();
        assertEq(impl, impl2);
        assertTrue(exists);
    }

    function testNonces() public {
        // Check initial nonce
        assertEq(tokenInstance.nonces(alice), 0);

        // We'd need a permit operation to increment nonce, but that's
        // complex to test in isolation. Simply verify the function exists.
        // In a full permit test, the nonce would be incremented.
    }
}
