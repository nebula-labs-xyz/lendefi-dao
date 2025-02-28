// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BasicDeploy} from "../BasicDeploy.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {Ecosystem} from "../../contracts/ecosystem/Ecosystem.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract EcosystemTest is BasicDeploy {
    event Burn(address indexed src, uint256 amount);
    event Reward(address indexed src, address indexed to, uint256 amount);
    event AirDrop(address[] addresses, uint256 amount);
    event AddPartner(address indexed account, address indexed vesting, uint256 amount);
    event MaxRewardUpdated(address indexed manager, uint256 oldMaxReward, uint256 newMaxReward);

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

    // Test: RevertReceive
    function testRevertReceive() public returns (bool success) {
        vm.expectRevert(); // contract does not receive ether
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
        ecoInstance.initialize(address(tokenInstance), guardian, pauser);
    }

    function testProxyInitializeSuccess() public {
        // Deploy new proxy instance
        Ecosystem implementation = new Ecosystem();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        Ecosystem ecosystem = Ecosystem(payable(address(proxy)));

        // Initialize with valid addresses
        ecosystem.initialize(address(tokenInstance), guardian, pauser);

        // Verify initialization
        assertTrue(ecosystem.hasRole(DEFAULT_ADMIN_ROLE, guardian));
        assertTrue(ecosystem.hasRole(PAUSER_ROLE, pauser));
        assertFalse(ecosystem.paused());
    }

    function testRevertDoubleInitialize() public {
        // Deploy new proxy instance
        Ecosystem implementation = new Ecosystem();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        Ecosystem ecosystem = Ecosystem(payable(address(proxy)));

        // First initialization
        ecosystem.initialize(address(tokenInstance), guardian, pauser);

        // Attempt second initialization
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        ecosystem.initialize(address(tokenInstance), guardian, pauser);
    }

    function testRevertProxyInitializeZeroAddresses() public {
        // Deploy new proxy instance
        Ecosystem implementation = new Ecosystem();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        Ecosystem ecosystem = Ecosystem(payable(address(proxy)));

        // Test zero token address
        vm.expectRevert(abi.encodeWithSignature("CustomError(string)", "ZERO_ADDRESS_DETECTED"));
        ecosystem.initialize(address(0), guardian, pauser);

        // Test zero guardian address
        vm.expectRevert(abi.encodeWithSignature("CustomError(string)", "ZERO_ADDRESS_DETECTED"));
        ecosystem.initialize(address(tokenInstance), address(0), pauser);

        // Test zero pauser address
        vm.expectRevert(abi.encodeWithSignature("CustomError(string)", "ZERO_ADDRESS_DETECTED"));
        ecosystem.initialize(address(tokenInstance), guardian, address(0));
    }

    // Test: Pause
    function testPause() public {
        assertEq(ecoInstance.paused(), false);
        vm.startPrank(pauser);
        ecoInstance.pause();
        assertEq(ecoInstance.paused(), true);
        ecoInstance.unpause();
        assertEq(ecoInstance.paused(), false);
        vm.stopPrank();
    }

    // Test: RevertPauseBranch1
    function testRevertPauseBranch1() public {
        assertEq(ecoInstance.paused(), false);

        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, PAUSER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError);
        ecoInstance.pause();
    }

    function testUnpauseSuccess() public {
        vm.prank(pauser);
        ecoInstance.pause();

        vm.prank(pauser);
        ecoInstance.unpause();

        // Verify unpaused by attempting an operation
        vm.prank(managerAdmin);
        ecoInstance.addPartner(partner, 1000 ether, 365 days, 730 days);
    }

    function testRevertUnpauseUnauthorized() public {
        vm.prank(pauser);
        ecoInstance.pause();

        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, PAUSER_ROLE);

        vm.prank(alice);
        vm.expectRevert(expError);
        ecoInstance.unpause();
    }

    function testRevertUnpauseWhenNotPaused() public {
        bytes memory expError = abi.encodeWithSignature("ExpectedPause()");

        vm.prank(pauser);
        vm.expectRevert(expError);
        ecoInstance.unpause();
    }

    // Test: Airdrop
    function testAirdrop() public {
        vm.startPrank(managerAdmin);
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;

        emit AirDrop(winners, 20 ether);
        ecoInstance.airdrop(winners, 20 ether);
        vm.stopPrank();
        for (uint256 i = 0; i < winners.length; ++i) {
            uint256 bal = tokenInstance.balanceOf(address(winners[i]));
            assertEq(bal, 20 ether);
        }
    }

    // Test: AirdropGasLimit
    function testAirdropGasLimit() public {
        address[] memory winners = new address[](4000);
        for (uint256 i = 0; i < 4000; ++i) {
            winners[i] = alice;
        }

        vm.prank(managerAdmin);
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
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", pauser, MANAGER_ROLE);
        vm.prank(pauser);
        vm.expectRevert(expError); // access control
        ecoInstance.airdrop(winners, 20 ether);
    }

    // Test: RevertAirdropBranch2
    function testRevertAirdropBranch2() public {
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

    // Test: RevertAirdropBranch3
    function testRevertAirdropBranch3() public {
        address[] memory winners = new address[](5001);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "GAS_LIMIT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // array too large
        ecoInstance.airdrop(winners, 1 ether);
    }

    // Test: RevertAirdropBranch4
    function testRevertAirdropBranch4() public {
        address[] memory winners = new address[](3);
        winners[0] = alice;
        winners[1] = bob;
        winners[2] = charlie;
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "AIRDROP_SUPPLY_LIMIT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // supply exceeded
        ecoInstance.airdrop(winners, 2_000_000 ether);
    }

    // Test: Reward
    function testReward() public {
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

    // Test: RevertRewardBranch1
    function testRevertRewardBranch1() public {
        uint256 maxReward = ecoInstance.maxReward();
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, REWARDER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError);
        ecoInstance.reward(assetRecipient, maxReward);
    }

    // Test: RevertRewardBranch2
    function testRevertRewardBranch2() public {
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

    // Test: RevertRewardBranch3
    function testRevertRewardBranch3() public {
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, managerAdmin);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.reward(assetRecipient, 0);
    }

    // Test: RevertRewardBranch4
    function testRevertRewardBranch4() public {
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, managerAdmin);

        uint256 maxReward = ecoInstance.maxReward();
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "REWARD_LIMIT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.reward(assetRecipient, maxReward + 1 ether);
    }

    // Test: RevertRewardBranch5
    function testRevertRewardBranch5() public {
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

    // Test: Burn
    function testBurn() public {
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

    // Test: RevertBurnBranch1
    function testRevertBurnBranch1() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", guardian, BURNER_ROLE);
        vm.prank(guardian);
        vm.expectRevert(expError);
        ecoInstance.burn(1 ether);
    }

    // Test: RevertBurnBranch2
    function testRevertBurnBranch2() public {
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

    // Test: RevertBurnBranch3
    function testRevertBurnBranch3() public {
        vm.prank(guardian);
        ecoInstance.grantRole(BURNER_ROLE, managerAdmin);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.burn(0);
    }

    // Test: RevertBurnBranch4
    function testRevertBurnBranch4() public {
        vm.prank(guardian);
        ecoInstance.grantRole(BURNER_ROLE, managerAdmin);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "BURN_SUPPLY_LIMIT");
        vm.startPrank(managerAdmin);
        uint256 rewardSupply = ecoInstance.rewardSupply();

        vm.expectRevert(expError);
        ecoInstance.burn(rewardSupply + 1 ether);
        vm.stopPrank();
    }

    // Test: RevertBurnBranch5
    function testRevertBurnBranch5() public {
        vm.prank(guardian);
        ecoInstance.grantRole(BURNER_ROLE, managerAdmin);
        uint256 amount = ecoInstance.maxBurn();
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "MAX_BURN_LIMIT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.burn(amount + 1 ether);
    }

    // Test: AddPartner
    function testAddPartner() public {
        uint256 vmprimer = 365 days;
        vm.warp(vmprimer);
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 8;
        vm.prank(managerAdmin);
        ecoInstance.addPartner(partner, amount, 365 days, 730 days);
        address vestingAddr = ecoInstance.vestingContracts(partner);
        uint256 bal = tokenInstance.balanceOf(vestingAddr);
        assertEq(bal, amount);
    }

    // Test: RevertAddPartnerBranch1
    function testRevertAddPartnerBranch1() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", pauser, MANAGER_ROLE);
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 4;

        vm.prank(pauser);
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, amount, 365 days, 730 days);
    }

    // Test: RevertAddPartnerBranch2
    function testRevertAddPartnerBranch2() public {
        assertEq(ecoInstance.paused(), false);
        vm.prank(pauser);
        ecoInstance.pause();

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.prank(managerAdmin);
        vm.expectRevert(expError); // contract paused
        ecoInstance.addPartner(partner, 100 ether, 365 days, 730 days);
    }

    // Test: RevertAddPartnerBranch3
    function testRevertAddPartnerBranch3() public {
        vm.prank(managerAdmin);
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_ADDRESS");
        vm.expectRevert(expError);
        ecoInstance.addPartner(address(0), 100 ether, 365 days, 730 days);
    }

    // Test: RevertAddPartnerBranch4
    function testRevertAddPartnerBranch4() public {
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 4;
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "PARTNER_EXISTS");
        vm.startPrank(managerAdmin);
        ecoInstance.addPartner(alice, amount, 365 days, 730 days);
        vm.expectRevert(expError); // adding same partner
        ecoInstance.addPartner(alice, amount, 365 days, 730 days);
        vm.stopPrank();
    }

    // Test: RevertAddPartnerBranch5
    function testRevertAddPartnerBranch5() public {
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 2;
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, amount + 1 ether, 365 days, 730 days);
    }

    // Test: RevertAddPartnerBranch6
    function testRevertAddPartnerBranch6() public {
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, 50 ether, 365 days, 730 days);
    }

    // Test: RevertAddPartnerBranch7
    function testRevertAddPartnerBranch7() public {
        uint256 supply = ecoInstance.partnershipSupply();
        uint256 amount = supply / 2;
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "AMOUNT_EXCEEDS_SUPPLY");
        vm.startPrank(managerAdmin);
        ecoInstance.addPartner(alice, amount, 365 days, 730 days);
        ecoInstance.addPartner(bob, amount, 365 days, 730 days);
        vm.expectRevert(expError);
        ecoInstance.addPartner(charlie, 100 ether, 365 days, 730 days);
        vm.stopPrank();
    }
    //--------------MORE TESTS-----------------------

    function testAddPartnerSuccess() public {
        uint256 amount = 1000 ether;
        uint256 cliff = 365 days;
        uint256 duration = 730 days;

        vm.startPrank(managerAdmin);
        ecoInstance.addPartner(partner, amount, cliff, duration);

        address vestingAddress = ecoInstance.vestingContracts(partner);
        VestingWallet vesting = VestingWallet(payable(vestingAddress));

        assertEq(vesting.owner(), partner);
        assertEq(vesting.duration(), duration);
        assertEq(vesting.start(), block.timestamp + cliff);
        assertEq(tokenInstance.balanceOf(vestingAddress), amount);
        vm.stopPrank();
    }

    function testRevertAddPartnerUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, MANAGER_ROLE)
        );
        vm.prank(alice);
        ecoInstance.addPartner(partner, 1000 ether, 365 days, 730 days);
    }

    function testRevertAddPartnerZeroAddress() public {
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_ADDRESS");

        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.addPartner(address(0), 1000 ether, 365 days, 730 days);
    }

    function testRevertAddPartnerExists() public {
        vm.startPrank(managerAdmin);
        ecoInstance.addPartner(partner, 1000 ether, 365 days, 730 days);

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "PARTNER_EXISTS");
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, 1000 ether, 365 days, 730 days);
        vm.stopPrank();
    }

    function testRevertAddPartnerInvalidAmount() public {
        vm.startPrank(managerAdmin);

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");

        // Test amount less than minimum
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, 99 ether, 365 days, 730 days);

        // Test amount more than maximum
        uint256 maxAmount = ecoInstance.partnershipSupply() / 2 + 1;
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, maxAmount, 365 days, 730 days);

        vm.stopPrank();
    }

    function testRevertAddPartnerWhenPaused() public {
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");

        vm.prank(pauser);
        ecoInstance.pause();

        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, 1000 ether, 365 days, 730 days);
    }

    function testFuzz_AddPartner(address _partner, uint256 _amount, uint64 _cliff, uint64 _duration) public {
        // Bound amount between valid ranges (100 ether to partnershipSupply/2)
        _amount = bound(_amount, 100 ether, ecoInstance.partnershipSupply() / 2);
        // Ensure cliff is less than duration
        _cliff = uint64(bound(_cliff, 1 days, 365 days));
        _duration = uint64(bound(_duration, _cliff + 1 days, 1000 days));

        vm.assume(_partner != address(0));
        vm.assume(_partner.code.length == 0); // Ensure not a contract
        vm.assume(_partner != managerAdmin);

        vm.startPrank(managerAdmin);
        ecoInstance.addPartner(_partner, _amount, _cliff, _duration);

        address vestingAddress = ecoInstance.vestingContracts(_partner);
        VestingWallet vesting = VestingWallet(payable(vestingAddress));

        assertEq(vesting.owner(), _partner);
        assertEq(vesting.duration(), _duration);
        assertEq(vesting.start(), block.timestamp + _cliff);
        vm.stopPrank();
    }

    function testFuzz_RevertInvalidAmount(uint256 _amount) public {
        vm.assume(_amount < 100 ether || _amount > ecoInstance.partnershipSupply() / 2);

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");
        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, _amount, 365 days, 730 days);
    }

    function testFuzz_RevertExceedSupply(uint256 _amount) public {
        uint256 partnershipSupply = ecoInstance.partnershipSupply();
        _amount = bound(_amount, partnershipSupply + 1, type(uint256).max);

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");

        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.addPartner(partner, _amount, 365 days, 730 days);
    }

    function testFuzz_MultiplePartners(
        address[5] calldata _partners,
        uint256[5] calldata _amounts,
        uint64[5] calldata _cliffs,
        uint64[5] calldata _durations
    ) public {
        vm.startPrank(managerAdmin);

        for (uint256 i = 0; i < _partners.length; i++) {
            address currentPartner = _partners[i];
            vm.assume(currentPartner != address(0));
            vm.assume(currentPartner.code.length == 0);
            vm.assume(currentPartner != managerAdmin);

            // Skip if partner already exists
            if (ecoInstance.vestingContracts(currentPartner) != address(0)) continue;

            uint256 amount = bound(_amounts[i], 100 ether, ecoInstance.partnershipSupply() / 10);
            uint64 cliff = uint64(bound(_cliffs[i], 1 days, 365 days));
            uint64 duration = uint64(bound(_durations[i], cliff + 1 days, 1000 days));

            ecoInstance.addPartner(currentPartner, amount, cliff, duration);

            address vestingAddress = ecoInstance.vestingContracts(currentPartner);
            VestingWallet vesting = VestingWallet(payable(vestingAddress));

            assertEq(vesting.owner(), currentPartner);
            assertEq(vesting.duration(), duration);
            assertEq(vesting.start(), block.timestamp + cliff);
        }
        vm.stopPrank();
    }

    function testFuzz_PartnerVestingSchedule(uint64 _cliff, uint64 _duration) public {
        // Bound cliff and duration to reasonable ranges
        _cliff = uint64(bound(_cliff, 1 days, 365 days));
        _duration = uint64(bound(_duration, _cliff + 1 days, 1000 days));

        vm.prank(managerAdmin);
        ecoInstance.addPartner(partner, 100 ether, _cliff, _duration);

        address vestingAddress = ecoInstance.vestingContracts(partner);
        VestingWallet vesting = VestingWallet(payable(vestingAddress));

        // Test vesting schedule
        vm.warp(block.timestamp + _cliff - 1);
        assertEq(vesting.releasable(address(tokenInstance)), 0);

        vm.warp(block.timestamp + _cliff + _duration);
        assertEq(vesting.releasable(address(tokenInstance)), 100 ether);
    }

    function testUpdateMaxReward() public {
        uint256 oldMaxReward = ecoInstance.maxReward();
        uint256 newMaxReward = oldMaxReward / 2; // Reduce to half

        vm.prank(managerAdmin);
        vm.expectEmit(address(ecoInstance));
        emit MaxRewardUpdated(managerAdmin, oldMaxReward, newMaxReward);
        ecoInstance.updateMaxReward(newMaxReward);

        assertEq(ecoInstance.maxReward(), newMaxReward, "Max reward should be updated");
    }

    function testRevertUpdateMaxRewardUnauthorized() public {
        bytes memory expError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", alice, MANAGER_ROLE);

        vm.prank(alice);
        vm.expectRevert(expError);
        ecoInstance.updateMaxReward(1 ether);
    }

    function testRevertUpdateMaxRewardWhenPaused() public {
        vm.prank(pauser);
        ecoInstance.pause();

        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");

        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.updateMaxReward(1 ether);
    }

    function testRevertUpdateMaxRewardZero() public {
        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "INVALID_AMOUNT");

        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.updateMaxReward(0);
    }

    function testRevertUpdateMaxRewardExcessive() public {
        uint256 remainingRewards = ecoInstance.rewardSupply() - ecoInstance.issuedReward();
        uint256 excessiveAmount = (remainingRewards / 20) + 1 ether; // Just over 5%

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "EXCESSIVE_MAX_REWARD");

        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.updateMaxReward(excessiveAmount);
    }

    function testFuzz_UpdateMaxReward(uint256 _newMaxReward) public {
        uint256 remainingRewards = ecoInstance.rewardSupply() - ecoInstance.issuedReward();
        uint256 maxAllowed = remainingRewards / 20; // 5% of remaining rewards

        // Bound the input to be between 1 and the maximum allowed
        _newMaxReward = bound(_newMaxReward, 1, maxAllowed);

        vm.prank(managerAdmin);
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

        bytes memory expError = abi.encodeWithSignature("CustomError(string)", "EXCESSIVE_MAX_REWARD");

        vm.prank(managerAdmin);
        vm.expectRevert(expError);
        ecoInstance.updateMaxReward(excessiveAmount);
    }
}
