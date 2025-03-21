// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Vm} from "forge-std/Vm.sol";
import {BasicDeploy} from "../BasicDeploy.sol";
import {PartnerVesting} from "../../contracts/ecosystem/PartnerVesting.sol";
import {Ecosystem} from "../../contracts/ecosystem/Ecosystem.sol";
import {IECOSYSTEM} from "../../contracts/interfaces/IEcosystem.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";

contract EcosystemTest is BasicDeploy {
    event Burn(address indexed burner, uint256 amount);
    event Reward(address indexed sender, address indexed recipient, uint256 amount);
    event AirDrop(address[] indexed winners, uint256 amount);
    event AddPartner(address indexed partner, address indexed vestingContract, uint256 amount);
    event CancelPartnership(address indexed partner, uint256 remainingAmount);
    event MaxRewardUpdated(address indexed updater, uint256 oldValue, uint256 newValue);
    event MaxBurnUpdated(address indexed updater, uint256 oldValue, uint256 newValue);
    event Initialized(address indexed initializer);
    event Upgrade(address indexed upgrader, address indexed newImplementation, uint32 version);
    event UpgradeCancelled(address indexed canceller, address indexed implementation);
    event UpgradeScheduled(
        address indexed sender, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );
    event EmergencyWithdrawal(address indexed token, uint256 amount);

    function setUp() public {
        deployComplete();
        assertEq(tokenInstance.totalSupply(), 0);
        // this is the TGE
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        uint256 ecoBal = tokenInstance.balanceOf(address(ecoInstance));
        uint256 treasuryBal = tokenInstance.balanceOf(address(treasuryInstance));
        uint256 guardianBal = tokenInstance.balanceOf(guardian);

        assertEq(ecoBal, 22_000_000 ether);
        assertEq(treasuryBal, 27_400_000 ether);
        assertEq(guardianBal, 600_000 ether);
        assertEq(tokenInstance.totalSupply(), ecoBal + treasuryBal + guardianBal);
    }

    // Test: RevertReceive
    function testRevert_Receive() public returns (bool success) {
        vm.expectRevert(abi.encodeWithSignature("ValidationFailed(string)", "NO_ETHER_ACCEPTED")); // contract does not receive ether
        (success,) = payable(address(ecoInstance)).call{value: 100 ether}("");
    }

    // Test: ReceiveAndFallback
    function testReceiveFallback() public {
        // Setup test accounts with ETH
        vm.deal(alice, 2 ether);

        vm.startPrank(alice);

        // Test sending ETH with empty calldata (calls receive)
        (bool success,) = address(ecoInstance).call{value: 1 ether}("");
        assertFalse(success);

        // Test sending ETH with non-empty calldata (calls fallback)
        (success,) = address(ecoInstance).call{value: 1 ether}(hex"dead");
        assertFalse(success);

        // Test sending with no ETH but with data
        (success,) = address(ecoInstance).call(hex"dead");
        assertFalse(success);

        vm.stopPrank();

        // Verify contract has no ETH
        assertEq(address(ecoInstance).balance, 0);
    }

    // Test: RevertInitialization
    function testRevertInitialization() public {
        bytes memory expError = abi.encodeWithSignature("InvalidInitialization()");
        vm.prank(guardian);
        vm.expectRevert(expError); // contract already initialized
        ecoInstance.initialize(address(tokenInstance), address(timelockInstance), pauser);
    }

    function testRevertDoubleInitialize() public {
        // Deploy new proxy instance
        Ecosystem implementation = new Ecosystem();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        Ecosystem ecosystem = Ecosystem(payable(address(proxy)));

        // First initialization
        ecosystem.initialize(address(tokenInstance), address(timelockInstance), pauser);

        // Attempt second initialization
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        ecosystem.initialize(address(tokenInstance), address(timelockInstance), pauser);
    }

    function testRevertProxyInitializeZeroAddresses() public {
        // Deploy new proxy instance
        Ecosystem implementation = new Ecosystem();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        Ecosystem ecosystem = Ecosystem(payable(address(proxy)));

        // Test zero token address
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressDetected()"));
        ecosystem.initialize(address(0), address(timelockInstance), pauser);

        // Test zero timelock address
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressDetected()"));
        ecosystem.initialize(address(tokenInstance), address(0), pauser);

        // Test zero guardian address
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressDetected()"));
        ecosystem.initialize(address(tokenInstance), address(timelockInstance), address(0));
    }

    function testRevertUnpauseWhenNotPaused() public {
        bytes memory expError = abi.encodeWithSignature("ExpectedPause()");

        vm.prank(address(timelockInstance));
        vm.expectRevert(expError);
        ecoInstance.unpause();
    }

    // Test: AirdropGasLimit
    function testAirdropGasLimit() public {
        address[] memory winners = new address[](4000);
        for (uint256 i = 0; i < 4000; ++i) {
            winners[i] = alice;
        }

        vm.prank(address(timelockInstance));
        ecoInstance.airdrop(winners, 20 ether);
        uint256 bal = tokenInstance.balanceOf(alice);
        assertEq(bal, 80000 ether);
    }

    // Test: RevertAirdropBranch1
    function testRevertAirdropBranch1() public {
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError); // access control
        ecoInstance.airdrop(winners, 20 ether);
    }

    // Test: RevertAirdropBranch3
    function testRevertAirdropBranch3() public {
        address[] memory winners = new address[](5001);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("GasLimit(uint256)", 5001)); // array too large
        ecoInstance.airdrop(winners, 1 ether);
    }

    // Test: RevertAirdropBranch4
    function testRevertAirdropBranch4() public {
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;

        uint256 totalAmount = 3 * 2_000_000 ether;
        uint256 available = ecoInstance.airdropSupply() - ecoInstance.issuedAirDrop();

        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("AirdropSupplyLimit(uint256,uint256)", totalAmount, available)); // supply exceeded
        ecoInstance.airdrop(winners, 2_000_000 ether);
    }

    // Test: RevertAirdropInvalidAmount
    function testRevertAirdropInvalidAmount() public {
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;

        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("InvalidAmount(uint256)", 0.5 ether));
        ecoInstance.airdrop(winners, 0.5 ether);
    }

    // Test: RevertBurnBranch1
    function testRevertBurnBranch1() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, BURNER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError);
        ecoInstance.burn(1 ether);
    }

    // Test: AddPartner
    function testAddPartner() public {
        uint256 vmprimer = 365 days;
        vm.warp(vmprimer);
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 8;
        vm.prank(address(timelockInstance));
        ecoInstance.addPartner(partner, amount, 365 days, 730 days);
        address vestingAddr = ecoInstance.vestingContracts(partner);
        uint256 bal = tokenInstance.balanceOf(vestingAddr);
        assertEq(bal, amount);
    }

    // Test: RevertAddPartnerBranch1
    function testRevertAddPartnerBranch1() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, MANAGER_ROLE);
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 4;

        vm.prank(guardian);
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, amount, 365 days, 730 days);
    }

    // Test: RevertAddPartnerBranch3
    function testRevertAddPartnerBranch3() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        ecoInstance.addPartner(address(0), 100 ether, 365 days, 730 days);
    }

    // Test: RevertAddPartnerBranch5
    function testRevertAddPartnerBranch5() public {
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 2;
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("InvalidAmount(uint256)", amount + 1 ether));
        ecoInstance.addPartner(partner, amount + 1 ether, 365 days, 730 days);
    }

    // Test: RevertAddPartnerBranch6
    function testRevertAddPartnerBranch6() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("InvalidAmount(uint256)", 50 ether));
        ecoInstance.addPartner(partner, 50 ether, 365 days, 730 days);
    }

    // Test: CancelPartnership
    function testCancelPartnership() public {
        uint256 amount = 1000 ether;

        // Add a partner
        vm.prank(address(timelockInstance));
        ecoInstance.addPartner(partner, amount, 365 days, 730 days);

        // Cancel the partnership
        vm.prank(address(timelockInstance));
        vm.expectEmit(address(ecoInstance));
        emit CancelPartnership(partner, amount);
        ecoInstance.cancelPartnership(partner);

        // Verify tokens are returned to timelock
        assertEq(tokenInstance.balanceOf(address(timelockInstance)), amount);

        // Check accounting
        assertEq(ecoInstance.issuedPartnership(), 0);
    }

    // Test: RevertCancelPartnershipInvalidAddress
    function testRevertCancelPartnershipInvalidAddress() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        ecoInstance.cancelPartnership(address(0x123));
    }

    function testRevertAddPartnerUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, MANAGER_ROLE)
        );
        vm.prank(alice);
        ecoInstance.addPartner(partner, 1000 ether, 365 days, 730 days);
    }

    function testRevertAddPartnerZeroAddress() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        ecoInstance.addPartner(address(0), 1000 ether, 365 days, 730 days);
    }

    function testRevertAddPartnerWhenPaused() public {
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");

        vm.prank(address(timelockInstance));
        ecoInstance.pause();

        vm.prank(address(timelockInstance));
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, 1000 ether, 365 days, 730 days);
    }

    function testRevertUpdateMaxRewardUnauthorized() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, MANAGER_ROLE);

        vm.prank(alice);
        vm.expectRevert(expError);
        ecoInstance.updateMaxReward(1 ether);
    }

    function testRevertUpdateMaxRewardWhenPaused() public {
        vm.prank(address(timelockInstance));
        ecoInstance.pause();

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");

        vm.prank(address(timelockInstance));
        vm.expectRevert(expError);
        ecoInstance.updateMaxReward(1 ether);
    }

    function testRevertUpdateMaxRewardZero() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("InvalidAmount(uint256)", 0));
        ecoInstance.updateMaxReward(0);
    }

    function testRevertUpdateMaxRewardExcessive() public {
        uint256 remainingRewards = ecoInstance.rewardSupply() - ecoInstance.issuedReward();
        uint256 maxAllowed = remainingRewards / 20; // 5% of remaining rewards
        uint256 excessiveAmount = maxAllowed + 1 ether; // Just over 5%

        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("ExcessiveMaxValue(uint256,uint256)", excessiveAmount, maxAllowed));
        ecoInstance.updateMaxReward(excessiveAmount);
    }

    function testFuzz_UpdateMaxReward(uint256 _newMaxReward) public {
        uint256 remainingRewards = ecoInstance.rewardSupply() - ecoInstance.issuedReward();
        uint256 maxAllowed = remainingRewards / 20; // 5% of remaining rewards

        // Bound the input to be between 1 and the maximum allowed
        _newMaxReward = bound(_newMaxReward, 1, maxAllowed);

        vm.prank(address(timelockInstance));
        ecoInstance.updateMaxReward(_newMaxReward);

        assertEq(ecoInstance.maxReward(), _newMaxReward, "Max reward should be updated correctly");
    }

    function testFuzz_RevertUpdateMaxRewardExcessive(uint256 _excessAmount) public {
        // Make sure _excessAmount is positive but not too large
        _excessAmount = bound(_excessAmount, 1, type(uint128).max);

        uint256 remainingRewards = ecoInstance.rewardSupply() - ecoInstance.issuedReward();
        uint256 maxAllowed = remainingRewards / 20; // 5% of remaining rewards

        // Prevent overflow by ensuring we can safely add these values
        vm.assume(maxAllowed <= type(uint256).max - _excessAmount);

        uint256 excessiveAmount = maxAllowed + _excessAmount;

        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("ExcessiveMaxValue(uint256,uint256)", excessiveAmount, maxAllowed));
        ecoInstance.updateMaxReward(excessiveAmount);
    }

    function testAddPartnerSuccess() public {
        uint256 amount = 100 ether;
        uint256 cliff = 365 days;
        uint256 duration = 1460 days;

        vm.prank(address(timelockInstance)); // Uses timelock which has MANAGER_ROLE
        ecoInstance.addPartner(partner, amount, cliff, duration);

        address vestingContract = ecoInstance.vestingContracts(partner);
        assertNotEq(vestingContract, address(0));
        assertEq(tokenInstance.balanceOf(vestingContract), amount);
    }

    function testAirdrop() public {
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
        uint256 amount = 20 ether;

        uint256 initialBalance0 = tokenInstance.balanceOf(winners[0]);
        uint256 initialBalance1 = tokenInstance.balanceOf(winners[1]);
        uint256 initialBalance2 = tokenInstance.balanceOf(winners[2]);

        vm.prank(address(timelockInstance)); // Uses timelock which has MANAGER_ROLE
        vm.expectEmit(address(ecoInstance));
        emit AirDrop(winners, amount); // Match correct event signature
        ecoInstance.airdrop(winners, amount);

        assertEq(tokenInstance.balanceOf(winners[0]), initialBalance0 + amount);
        assertEq(tokenInstance.balanceOf(winners[1]), initialBalance1 + amount);
        assertEq(tokenInstance.balanceOf(winners[2]), initialBalance2 + amount);
    }

    function testBurn() public {
        // First grant the BURNER_ROLE to address(0x9999990)
        vm.prank(address(timelockInstance)); // timelockInstance has DEFAULT_ADMIN_ROLE
        ecoInstance.grantRole(BURNER_ROLE, address(0x9999990));

        uint256 amount = ecoInstance.maxBurn() / 2;
        uint256 initialBalance = tokenInstance.balanceOf(address(ecoInstance));
        uint256 initialSupply = tokenInstance.totalSupply();

        vm.prank(address(0x9999990)); // Using address with BURNER_ROLE
        vm.expectEmit(address(ecoInstance));
        emit Burn(address(0x9999990), amount);
        ecoInstance.burn(amount);

        assertEq(tokenInstance.balanceOf(address(ecoInstance)), initialBalance - amount);
        assertEq(tokenInstance.totalSupply(), initialSupply - amount);
        assertEq(ecoInstance.burnedAmount(), amount);
    }

    function testPause() public {
        assertFalse(ecoInstance.paused());

        vm.prank(address(timelockInstance));
        ecoInstance.pause();

        assertTrue(ecoInstance.paused());
    }

    function testProxyInitializeSuccess() public {
        Ecosystem impl = new Ecosystem();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                impl.initialize.selector, address(tokenInstance), address(timelockInstance), gnosisSafe
            )
        );

        Ecosystem eco = Ecosystem(payable(address(proxy)));

        // Verify roles are assigned correctly per contract implementation
        assertTrue(eco.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)));
        assertTrue(eco.hasRole(MANAGER_ROLE, address(timelockInstance)));
        assertTrue(eco.hasRole(PAUSER_ROLE, address(timelockInstance)));
        assertTrue(eco.hasRole(UPGRADER_ROLE, gnosisSafe));

        // Verify other initialization parameters
        assertEq(eco.timelock(), address(timelockInstance));
        assertNotEq(eco.rewardSupply(), 0);
        assertNotEq(eco.airdropSupply(), 0);
        assertNotEq(eco.partnershipSupply(), 0);
        assertNotEq(eco.maxReward(), 0);
        assertNotEq(eco.maxBurn(), 0);
        assertEq(eco.version(), 1);
    }

    function testRevertAddPartnerBranch2() public {
        vm.prank(guardian); // Guardian doesn't have MANAGER_ROLE
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, MANAGER_ROLE)
        );
        ecoInstance.addPartner(partner, 100 ether, 365 days, 730 days);
    }

    function testRevertAddPartnerBranch4() public {
        uint256 amount = 100 ether;
        uint256 cliff = 365 days;
        uint256 duration = 730 days;

        // First add partner
        vm.prank(address(timelockInstance));
        ecoInstance.addPartner(partner, amount, cliff, duration);

        // Try to add same partner again
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IECOSYSTEM.PartnerExists.selector, partner));
        ecoInstance.addPartner(partner, amount, cliff, duration);
    }

    function testRevertAddPartnerBranch7() public {
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 2;
        vm.startPrank(address(timelockInstance));
        ecoInstance.addPartner(alice, amount, 365 days, 730 days);
        ecoInstance.addPartner(bob, amount, 365 days, 730 days);

        uint256 available = ecoInstance.availablePartnershipSupply();
        vm.expectRevert(abi.encodeWithSelector(IECOSYSTEM.AmountExceedsSupply.selector, 100 ether, available));
        ecoInstance.addPartner(charlie, 100 ether, 365 days, 730 days);
        vm.stopPrank();
    }

    function testRevertAddPartnerExists() public {
        vm.startPrank(address(timelockInstance));
        ecoInstance.addPartner(partner, 1000 ether, 365 days, 730 days);

        vm.expectRevert(abi.encodeWithSelector(IECOSYSTEM.PartnerExists.selector, partner));
        ecoInstance.addPartner(partner, 1000 ether, 365 days, 730 days);
        vm.stopPrank();
    }

    function testRevertAddPartnerInvalidAmount() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IECOSYSTEM.InvalidAmount.selector, 99 ether));
        ecoInstance.addPartner(partner, 99 ether, 365 days, 730 days);
    }

    function testRevertAirdropBranch2() public {
        address[] memory recipients = new address[](3);
        recipients[0] = address(0x1);
        uint256 amount = 0.9 ether; // Less than 1 ether

        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IECOSYSTEM.InvalidAmount.selector, amount));
        ecoInstance.airdrop(recipients, amount);
    }

    function testRevertBurnBranch2() public {
        // First grant the BURNER_ROLE
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(BURNER_ROLE, address(0x9999990));

        // Then pause the contract
        vm.prank(address(timelockInstance));
        ecoInstance.pause();

        vm.prank(address(0x9999990)); // Has BURNER_ROLE but contract is paused
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        ecoInstance.burn(1 ether);
    }

    function testRevertBurnBranch3() public {
        // First grant the BURNER_ROLE
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(BURNER_ROLE, address(0x9999990));

        uint256 amount = 0; // Zero amount

        vm.prank(address(0x9999990));
        vm.expectRevert(abi.encodeWithSelector(IECOSYSTEM.InvalidAmount.selector, amount));
        ecoInstance.burn(amount);
    }

    function testRevert_BurnBranch4() public {
        // First grant the BURNER_ROLE to the address we'll use
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(BURNER_ROLE, address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496));

        uint256 amount = ecoInstance.maxBurn() + 1 ether;

        vm.prank(address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496));
        vm.expectRevert(abi.encodeWithSelector(IECOSYSTEM.MaxBurnLimit.selector, amount, ecoInstance.maxBurn()));
        ecoInstance.burn(amount);
    }

    function testRevert_BurnBranch5() public {
        // First grant the BURNER_ROLE to the address we'll use
        // First grant the BURNER_ROLE
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(BURNER_ROLE, address(0x9999990));

        // First increase the maxBurn to a much higher value
        uint256 remainingRewards = ecoInstance.rewardSupply() - ecoInstance.issuedReward();
        uint256 newMaxBurn = remainingRewards / 11; // Just under 10% limit

        vm.prank(address(timelockInstance));
        ecoInstance.updateMaxBurn(newMaxBurn);

        // Instead of looping through thousands of reward calls, directly modify state
        // to simulate that most of the reward supply has been issued

        // Define a small amount we want to leave available (1000 ether)
        uint256 targetRemaining = 1000 ether;

        // Calculate how much to set as issuedReward
        uint256 totalRewardSupply = ecoInstance.rewardSupply();
        uint256 newIssuedReward = totalRewardSupply - targetRemaining;

        // Storage slot for issuedReward is at index 3 (0-based) in the contract
        bytes32 issuedRewardSlot = bytes32(uint256(3));

        // Store the new value directly
        vm.store(address(ecoInstance), issuedRewardSlot, bytes32(newIssuedReward));

        // Verify we set the state correctly
        uint256 availableSupply = ecoInstance.availableRewardSupply();
        assertEq(availableSupply, targetRemaining, "Available supply should be exactly the target amount");

        // Verify our available supply is less than maxBurn (important for test)
        assertTrue(availableSupply < ecoInstance.maxBurn(), "Available supply must be less than maxBurn for this test");

        // Try to burn more than the available supply (but still within maxBurn limit)
        vm.prank(address(0x9999990));
        vm.expectRevert(
            abi.encodeWithSelector(IECOSYSTEM.BurnSupplyLimit.selector, availableSupply + 1, availableSupply)
        );
        ecoInstance.burn(availableSupply + 1);
    }

    function testRevertCancelPartnershipUnauthorized() public {
        // First add a partner
        vm.prank(address(timelockInstance));
        ecoInstance.addPartner(partner, 1000 ether, 365 days, 730 days);

        // Try to cancel from unauthorized address - Only MANAGER_ROLE can call this
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, MANAGER_ROLE)
        );
        ecoInstance.cancelPartnership(partner);
    }

    function testRevertPauseBranch1() public {
        assertEq(ecoInstance.paused(), false);

        vm.prank(alice); // alice doesn't have PAUSER_ROLE
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, PAUSER_ROLE)
        );
        ecoInstance.pause();
    }

    function testRevert_RewardBranch2() public {
        // First grant the REWARDER_ROLE
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, guardian);

        // Pause contract
        vm.prank(address(timelockInstance));
        ecoInstance.pause();

        // Try to reward when paused
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        ecoInstance.reward(assetRecipient, 1 ether);
    }

    function testRevert_RewardBranch3() public {
        // First grant the REWARDER_ROLE
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(0x9999990));

        vm.prank(address(0x9999990));
        vm.expectRevert(abi.encodeWithSelector(IECOSYSTEM.InvalidAmount.selector, 0));
        ecoInstance.reward(assetRecipient, 0);
    }

    function testRevert_RewardBranch4() public {
        // First grant the REWARDER_ROLE
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(0x9999990));

        uint256 maxReward = ecoInstance.maxReward();
        vm.prank(address(0x9999990));
        vm.expectRevert(abi.encodeWithSelector(IECOSYSTEM.RewardLimit.selector, maxReward + 1 ether, maxReward));
        ecoInstance.reward(assetRecipient, maxReward + 1 ether);
    }

    function testRevert_RewardBranch5() public {
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, managerAdmin);
        uint256 maxReward = ecoInstance.maxReward();

        vm.startPrank(managerAdmin);
        for (uint256 i = 0; i < 1000; ++i) {
            ecoInstance.reward(assetRecipient, maxReward);
        }

        uint256 availableSupply = ecoInstance.availableRewardSupply();
        assertEq(availableSupply, 0);

        vm.expectRevert(abi.encodeWithSelector(IECOSYSTEM.RewardSupplyLimit.selector, 1 ether, availableSupply));
        ecoInstance.reward(assetRecipient, 1 ether);
        vm.stopPrank();
    }

    function testRevertUnpauseUnauthorized() public {
        vm.prank(address(timelockInstance));
        ecoInstance.pause();

        vm.prank(alice); // alice doesn't have PAUSER_ROLE
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, PAUSER_ROLE)
        );
        ecoInstance.unpause();
    }

    function testReward() public {
        // First grant the REWARDER_ROLE
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(0x9999990));

        vm.startPrank(address(0x9999990));
        vm.expectEmit(address(ecoInstance));
        emit Reward(address(0x9999990), assetRecipient, 20 ether);
        ecoInstance.reward(assetRecipient, 20 ether);
        vm.stopPrank();

        uint256 bal = tokenInstance.balanceOf(assetRecipient);
        assertEq(bal, 20 ether);
    }

    function testUnpauseSuccess() public {
        vm.prank(address(timelockInstance));
        ecoInstance.pause();

        vm.prank(address(timelockInstance));
        ecoInstance.unpause();

        // Verify unpaused by attempting an operation
        vm.prank(address(timelockInstance));
        ecoInstance.addPartner(partner, 1000 ether, 365 days, 730 days);
    }

    function testUpdateMaxReward() public {
        uint256 oldMaxReward = ecoInstance.maxReward();
        uint256 newMaxReward = oldMaxReward / 2; // Reduce to half

        vm.prank(address(timelockInstance));
        vm.expectEmit(address(ecoInstance));
        emit MaxRewardUpdated(address(timelockInstance), oldMaxReward, newMaxReward);
        ecoInstance.updateMaxReward(newMaxReward);

        assertEq(ecoInstance.maxReward(), newMaxReward, "Max reward should be updated");
    }

    // ============ Schedule Upgrade Tests ============

    function testScheduleUpgrade() public {
        address mockImplementation = address(0xABCD);

        vm.recordLogs();

        vm.prank(gnosisSafe); // gnosisSafe has the UPGRADER_ROLE
        ecoInstance.scheduleUpgrade(mockImplementation);

        // Verify event emission
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);

        // Verify struct is properly set
        (address implementation, uint64 scheduledTime, bool exists) = ecoInstance.pendingUpgrade();
        assertEq(implementation, mockImplementation, "Implementation address not set correctly");
        assertEq(scheduledTime, uint64(block.timestamp), "Scheduled time not set correctly");
        assertTrue(exists, "Exists flag not set to true");
    }

    function testRevertScheduleUpgradeUnauthorized() public {
        address mockImplementation = address(0xABCD);

        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, UPGRADER_ROLE);

        vm.prank(alice); // alice doesn't have UPGRADER_ROLE
        vm.expectRevert(expError);
        ecoInstance.scheduleUpgrade(mockImplementation);
    }

    function testRevertScheduleUpgradeZeroAddress() public {
        vm.prank(gnosisSafe); // gnosisSafe has the UPGRADER_ROLE
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        ecoInstance.scheduleUpgrade(address(0));
    }

    // ============ Upgrade Timelock Tests ============

    function testUpgradeTimelockRemaining() public {
        address mockImplementation = address(0xABCD);

        // Initially no pending upgrade
        assertEq(ecoInstance.upgradeTimelockRemaining(), 0, "Should be 0 with no pending upgrade");

        // Schedule an upgrade
        vm.prank(gnosisSafe);
        ecoInstance.scheduleUpgrade(mockImplementation);

        // Check initial remaining time (should be 3 days)
        uint256 remaining = ecoInstance.upgradeTimelockRemaining();
        assertEq(remaining, 3 days, "Initial timelock should be 3 days");

        // Forward time by 1 day
        vm.warp(block.timestamp + 1 days);

        // Check updated remaining time
        remaining = ecoInstance.upgradeTimelockRemaining();
        assertEq(remaining, 2 days, "Remaining time should be 2 days after 1 day passes");

        // Forward time past timelock
        vm.warp(block.timestamp + 3 days);

        // Check remaining time is now 0
        remaining = ecoInstance.upgradeTimelockRemaining();
        assertEq(remaining, 0, "Remaining time should be 0 when timelock expires");
    }

    // ============ Emergency Withdrawal Tests ============
    function testEmergencyWithdrawToken() public {
        // Get initial balance of timelock
        uint256 initialBalance = tokenInstance.balanceOf(address(timelockInstance));

        // Get current balance of ecosystem contract
        uint256 ecoBalance = tokenInstance.balanceOf(address(ecoInstance));
        assertGt(ecoBalance, 0, "Ecosystem should have tokens");

        // Record events
        vm.recordLogs();

        // Execute emergency withdrawal
        vm.prank(address(timelockInstance)); // timelockInstance has MANAGER_ROLE
        ecoInstance.emergencyWithdrawToken(address(tokenInstance));

        // Verify event emission
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 2); // Transfer event + EmergencyWithdrawal event

        // Verify tokens were sent to timelock
        assertEq(
            tokenInstance.balanceOf(address(timelockInstance)),
            initialBalance + ecoBalance,
            "All tokens not correctly sent to timelock"
        );

        // Verify ecosystem has no tokens left
        assertEq(tokenInstance.balanceOf(address(ecoInstance)), 0, "Ecosystem should have no tokens left");
    }

    function testRevertEmergencyWithdrawTokenUnauthorized() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, MANAGER_ROLE);

        vm.prank(alice); // alice doesn't have MANAGER_ROLE
        vm.expectRevert(expError);
        ecoInstance.emergencyWithdrawToken(address(tokenInstance));
    }

    function testRevertEmergencyWithdrawTokenZeroAddress() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        ecoInstance.emergencyWithdrawToken(address(0));
    }

    function testRevertEmergencyWithdrawTokenZeroBalance() public {
        // Create a new mock token that the ecosystem doesn't have any balance of
        TokenMock newToken = new TokenMock("Test Token", "TEST");

        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("ZeroBalance()"));
        ecoInstance.emergencyWithdrawToken(address(newToken));
    }

    // Test emergency withdrawal when contract is paused
    function testEmergencyWithdrawTokenWhenPaused() public {
        // Pause the contract
        vm.prank(address(timelockInstance));
        ecoInstance.pause();

        uint256 ecoBalance = tokenInstance.balanceOf(address(ecoInstance));
        uint256 timelockInitial = tokenInstance.balanceOf(address(timelockInstance));

        // Emergency withdraw should still work when paused
        vm.prank(address(timelockInstance));
        ecoInstance.emergencyWithdrawToken(address(tokenInstance));

        // Verify tokens were transferred
        assertEq(tokenInstance.balanceOf(address(ecoInstance)), 0, "Ecosystem should have no tokens left");
        assertEq(
            tokenInstance.balanceOf(address(timelockInstance)),
            timelockInitial + ecoBalance,
            "Timelock should receive all tokens"
        );
    }

    // Test cancelling an upgrade
    function testCancelUpgrade() public {
        address mockImplementation = address(0xABCD);

        // Schedule an upgrade first
        vm.prank(gnosisSafe); // Has UPGRADER_ROLE
        ecoInstance.scheduleUpgrade(mockImplementation);

        // Verify upgrade is scheduled
        (address impl,, bool exists) = ecoInstance.pendingUpgrade();
        assertTrue(exists);
        assertEq(impl, mockImplementation);

        // Now cancel it
        vm.expectEmit(true, true, false, false);
        emit UpgradeCancelled(gnosisSafe, mockImplementation);

        vm.prank(gnosisSafe);
        ecoInstance.cancelUpgrade();

        // Verify upgrade was cancelled
        (,, exists) = ecoInstance.pendingUpgrade();
        assertFalse(exists);
    }

    // Test error when trying to cancel non-existent upgrade
    function testRevert_CancelUpgradeNoScheduledUpgrade() public {
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSignature("UpgradeNotScheduled()"));
        ecoInstance.cancelUpgrade();
    }

    function testRevert_UpgradeWithoutScheduling() public {
        // Create a new implementation
        address newImplementation = address(new Ecosystem());

        // Try to upgrade directly without scheduling first
        vm.prank(gnosisSafe); // Has UPGRADER_ROLE
        vm.expectRevert(abi.encodeWithSignature("UpgradeNotScheduled()"));

        // This calls _authorizeUpgrade internally
        ecoInstance.upgradeToAndCall(newImplementation, "");
    }

    // Test implementation mismatch error during upgrade
    function testRevertUpgradeImplementationMismatch() public {
        address scheduledImpl = address(0x1234);
        address attemptedImpl = address(0x5678);

        // Schedule upgrade with first implementation
        vm.prank(gnosisSafe);
        ecoInstance.scheduleUpgrade(scheduledImpl);

        // Wait for timelock to expire
        vm.warp(block.timestamp + 4 days);

        // Try to upgrade with different implementation
        vm.prank(gnosisSafe);
        vm.expectRevert(
            abi.encodeWithSelector(IECOSYSTEM.ImplementationMismatch.selector, scheduledImpl, attemptedImpl)
        );

        // This calls _authorizeUpgrade internally
        ecoInstance.upgradeToAndCall(attemptedImpl, "");
    }

    // Test upgrade during active timelock period
    function testRevertUpgradeTimelockActive() public {
        address mockImplementation = address(0xABCD);

        // Schedule upgrade
        vm.prank(gnosisSafe);
        ecoInstance.scheduleUpgrade(mockImplementation);

        // Try to upgrade before timelock expires (only 1 day passed)
        vm.warp(block.timestamp + 1 days);

        vm.prank(gnosisSafe);
        vm.expectRevert(
            abi.encodeWithSelector(
                IECOSYSTEM.UpgradeTimelockActive.selector,
                2 days // 3 days total - 1 day passed
            )
        );
        ecoInstance.upgradeToAndCall(mockImplementation, "");
    }

    // Test version increment after successful upgrade
    function testVersionIncrement() public {
        uint32 initialVersion = ecoInstance.version();

        // Perform complete upgrade process
        address newImplementation = address(new Ecosystem());

        // Schedule upgrade
        vm.prank(gnosisSafe);
        ecoInstance.scheduleUpgrade(newImplementation);

        // Wait for timelock to expire
        vm.warp(block.timestamp + 4 days);

        // Complete the upgrade
        vm.prank(gnosisSafe);
        ecoInstance.upgradeToAndCall(newImplementation, "");

        // Verify version incremented
        assertEq(ecoInstance.version(), initialVersion + 1);
    }

    // Test invalid vesting schedule parameters
    function testRevertAddPartnerInvalidVestingSchedule() public {
        uint256 amount = 1000 ether;

        // Test case 1: Duration too short
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("InvalidVestingSchedule()"));
        ecoInstance.addPartner(partner, amount, 7 days, 29 days); // Less than MIN_VESTING_DURATION (30 days)

        // Test case 2: Duration too long
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("InvalidVestingSchedule()"));
        ecoInstance.addPartner(partner, amount, 365 days, 3700 days); // More than MAX_VESTING_DURATION (3650 days)

        // Test case 3: Cliff >= Duration
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("InvalidVestingSchedule()"));
        ecoInstance.addPartner(partner, amount, 730 days, 730 days); // Cliff equals duration
    }

    function test_UpdateMaxBurn() public {
        uint256 oldMaxBurn = ecoInstance.maxBurn();
        uint256 remainingRewards = ecoInstance.rewardSupply() - ecoInstance.issuedReward();
        uint256 newMaxBurn = remainingRewards / 20; // Half of the maximum allowed (10%)

        vm.prank(address(timelockInstance));
        vm.expectEmit(address(ecoInstance));
        emit MaxBurnUpdated(address(timelockInstance), oldMaxBurn, newMaxBurn);
        ecoInstance.updateMaxBurn(newMaxBurn);

        assertEq(ecoInstance.maxBurn(), newMaxBurn, "Max burn should be updated");
    }

    function testRevert_UpdateMaxBurnExcessive() public {
        uint256 remainingRewards = ecoInstance.rewardSupply() - ecoInstance.issuedReward();
        uint256 maxAllowed = remainingRewards / 10; // 10% of remaining rewards
        uint256 excessiveAmount = maxAllowed + 1 ether; // Just over 10%

        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSignature("ExcessiveMaxValue(uint256,uint256)", excessiveAmount, maxAllowed));
        ecoInstance.updateMaxBurn(excessiveAmount);
    }

    function testRevertRewardZeroAddress() public {
        // First grant the REWARDER_ROLE to an address
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(0x9999990));

        // Try to reward a zero address
        vm.prank(address(0x9999990));
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        ecoInstance.reward(address(0), 1 ether);
    }

    function test_ViewFunctions() public {
        // Initial state after setup
        uint256 initialRewardSupply = ecoInstance.rewardSupply();
        uint256 initialAirdropSupply = ecoInstance.airdropSupply();
        uint256 initialPartnershipSupply = ecoInstance.partnershipSupply();

        // Initially, available should match total as nothing has been issued yet
        assertEq(ecoInstance.availableRewardSupply(), initialRewardSupply);
        assertEq(ecoInstance.availableAirdropSupply(), initialAirdropSupply);
        assertEq(ecoInstance.availablePartnershipSupply(), initialPartnershipSupply);

        // Issue some rewards
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(0x9999990));

        uint256 rewardAmount = 100 ether;
        vm.prank(address(0x9999990));
        ecoInstance.reward(assetRecipient, rewardAmount);

        // Available supply should decrease
        assertEq(ecoInstance.availableRewardSupply(), initialRewardSupply - rewardAmount);

        // Do an airdrop
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256 airdropAmount = 50 ether;

        vm.prank(address(timelockInstance));
        ecoInstance.airdrop(recipients, airdropAmount);

        // Available airdrop supply should decrease by airdropAmount * recipients.length
        assertEq(ecoInstance.availableAirdropSupply(), initialAirdropSupply - (airdropAmount * 2));
    }

    function test_AirdropWithZeroAddresses() public {
        // Create an array with some zero addresses mixed in
        address[] memory recipients = new address[](5);
        recipients[0] = alice;
        recipients[1] = address(0); // Zero address
        recipients[2] = bob;
        recipients[3] = address(0); // Zero address
        recipients[4] = charlie;

        uint256 initialAliceBalance = tokenInstance.balanceOf(alice);
        uint256 initialBobBalance = tokenInstance.balanceOf(bob);
        uint256 initialCharlieBalance = tokenInstance.balanceOf(charlie);
        uint256 airdropAmount = 10 ether;

        // Only 3 valid addresses should receive tokens
        uint256 expectedTotalAmount = 3 * airdropAmount;
        uint256 initialAirdropIssued = ecoInstance.issuedAirDrop();

        vm.prank(address(timelockInstance));
        ecoInstance.airdrop(recipients, airdropAmount);

        // Check that tokens were only sent to non-zero addresses
        assertEq(tokenInstance.balanceOf(alice), initialAliceBalance + airdropAmount);
        assertEq(tokenInstance.balanceOf(bob), initialBobBalance + airdropAmount);
        assertEq(tokenInstance.balanceOf(charlie), initialCharlieBalance + airdropAmount);

        // Check that the issuedAirDrop was incremented correctly
        assertEq(ecoInstance.issuedAirDrop(), initialAirdropIssued + expectedTotalAmount);
    }
    // ============ Full Upgrade Flow Test ============

    function test_CancelPartnershipAfterFullClaim() public {
        uint256 amount = 1000 ether;

        // Add a partner
        vm.startPrank(address(timelockInstance));
        ecoInstance.addPartner(partner, amount, 0, 30 days); // No cliff, short duration

        // Get vesting contract address
        address vestingContract = ecoInstance.vestingContracts(partner);
        assertNotEq(vestingContract, address(0));
        vm.stopPrank();

        // Fast forward to after vesting period
        vm.warp(block.timestamp + 31 days);

        // Have partner claim all tokens first
        vm.startPrank(partner);
        PartnerVesting(vestingContract).release();
        vm.stopPrank();

        // Verify all tokens were claimed
        assertEq(tokenInstance.balanceOf(vestingContract), 0);

        // Initial balances before cancellation
        uint256 initialTimelockBalance = tokenInstance.balanceOf(address(timelockInstance));
        uint256 initialIssuedPartnership = ecoInstance.issuedPartnership();

        // Cancel the partnership with zero tokens to return
        vm.prank(address(timelockInstance));
        ecoInstance.cancelPartnership(partner);

        // Verify no tokens were transferred to timelock
        assertEq(tokenInstance.balanceOf(address(timelockInstance)), initialTimelockBalance);

        // Check accounting wasn't reduced (since no tokens were returned)
        assertEq(ecoInstance.issuedPartnership(), initialIssuedPartnership);

        // Verify the partnership was removed
        assertEq(ecoInstance.vestingContracts(partner), address(0));
    }

    function test_SuccessfulUpgrade() public {
        deployEcosystemUpgrade();
    }
}
