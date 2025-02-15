// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol"; // solhint-disable-line

import {USDC} from "../contracts/mock/USDC.sol";
import {WETHPriceConsumerV3} from "../contracts/mock/WETHOracle.sol";
import {WETH9} from "../contracts/vendor/canonical-weth/contracts/WETH9.sol";
import {ITREASURY} from "../contracts/interfaces/ITreasury.sol";
import {IECOSYSTEM} from "../contracts/interfaces/IEcosystem.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treasury} from "../contracts/ecosystem/Treasury.sol";
import {TreasuryV2} from "../contracts/upgrades/TreasuryV2.sol";
import {Ecosystem} from "../contracts/ecosystem/Ecosystem.sol";
import {EcosystemV2} from "../contracts/upgrades/EcosystemV2.sol";
import {GovernanceToken} from "../contracts/ecosystem/GovernanceToken.sol";
import {GovernanceTokenV2} from "../contracts/upgrades/GovernanceTokenV2.sol";
import {LendefiGovernor} from "../contracts/ecosystem/LendefiGovernor.sol";
import {LendefiGovernorV2} from "../contracts/upgrades/LendefiGovernorV2.sol";
import {LendefiTimelock} from "../contracts/ecosystem/LendefiTimelock.sol";
import {LendefiTimelockV2} from "../contracts/upgrades/LendefiTimelockV2.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol"; // Path to your contract

contract BasicDeploy is Test {
    event Upgrade(address indexed src, address indexed implementation);

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 internal constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    uint256 constant INIT_BALANCE_USDC = 100_000_000e6;
    uint256 constant INITIAL_SUPPLY = 50_000_000 ether;
    address constant ethereum = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant usdcWhale = 0x0A59649758aa4d66E25f08Dd01271e891fe52199;
    address constant bridge = address(0x9999988);
    address constant partner = address(0x9999989);
    address constant guardian = address(0x9999990);
    address constant alice = address(0x9999991);
    address constant bob = address(0x9999992);
    address constant charlie = address(0x9999993);
    address constant registryAdmin = address(0x9999994);
    address constant managerAdmin = address(0x9999995);
    address constant pauser = address(0x9999996);
    address constant assetSender = address(0x9999997);
    address constant assetRecipient = address(0x9999998);
    address constant feeRecipient = address(0x9999999);
    address[] users;

    GovernanceToken internal tokenInstance;
    Ecosystem internal ecoInstance;
    LendefiTimelock internal timelockInstance;
    LendefiGovernor internal govInstance;
    Treasury internal treasuryInstance;
    USDC internal usdcInstance; // mock usdc
    WETH9 internal wethInstance;
    WETHPriceConsumerV3 internal oracleInstance;
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    function deployTokenUpgrade() internal {
        // token deploy
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
        // upgrade token
        vm.prank(guardian);
        tokenInstance.grantRole(UPGRADER_ROLE, managerAdmin);

        vm.startPrank(managerAdmin);
        Upgrades.upgradeProxy(proxy, "GovernanceTokenV2.sol", "", guardian);
        vm.stopPrank();

        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        GovernanceTokenV2 instanceV2 = GovernanceTokenV2(proxy);
        assertEq(instanceV2.version(), 2);
        assertFalse(implAddressV2 == tokenImplementation);

        bool isUpgrader = instanceV2.hasRole(UPGRADER_ROLE, managerAdmin);
        assertTrue(isUpgrader == true);

        vm.prank(guardian);
        instanceV2.revokeRole(UPGRADER_ROLE, managerAdmin);
        assertFalse(instanceV2.hasRole(UPGRADER_ROLE, managerAdmin) == true);
    }

    function deployEcosystemUpgrade() internal {
        // token deploy
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);

        // ecosystem deploy
        bytes memory data1 = abi.encodeCall(Ecosystem.initialize, (address(tokenInstance), guardian, pauser));
        address payable proxy1 = payable(Upgrades.deployUUPSProxy("Ecosystem.sol", data1));
        ecoInstance = Ecosystem(proxy1);
        address ecoImplementation = Upgrades.getImplementationAddress(proxy1);
        assertFalse(address(ecoInstance) == ecoImplementation);

        // upgrade Ecosystem
        vm.prank(guardian);
        ecoInstance.grantRole(UPGRADER_ROLE, managerAdmin);

        vm.startPrank(managerAdmin);
        Upgrades.upgradeProxy(proxy1, "EcosystemV2.sol", "", guardian);
        vm.stopPrank();

        address implAddressV2 = Upgrades.getImplementationAddress(proxy1);
        EcosystemV2 ecoInstanceV2 = EcosystemV2(proxy1);
        assertEq(ecoInstanceV2.version(), 2);
        assertFalse(implAddressV2 == ecoImplementation);

        bool isUpgrader = ecoInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin);
        assertTrue(isUpgrader == true);

        vm.prank(guardian);
        ecoInstanceV2.revokeRole(UPGRADER_ROLE, managerAdmin);
        assertFalse(ecoInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin) == true);
    }

    function deployTreasuryUpgrade() internal {
        vm.warp(365 days);
        // token deploy
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
        // timelock deploy
        uint256 timelockDelay = 24 * 60 * 60;
        address[] memory temp = new address[](1);
        temp[0] = ethereum;
        bytes memory data2 = abi.encodeCall(LendefiTimelock.initialize, (timelockDelay, temp, temp, guardian));
        address payable proxy2 = payable(Upgrades.deployUUPSProxy("LendefiTimelock.sol", data2));
        timelockInstance = LendefiTimelock(proxy2);
        address tlImplementation = Upgrades.getImplementationAddress(proxy2);
        assertFalse(address(timelockInstance) == tlImplementation);
        //deploy Treasury
        bytes memory data1 = abi.encodeCall(Treasury.initialize, (guardian, address(timelockInstance)));
        address payable proxy1 = payable(Upgrades.deployUUPSProxy("Treasury.sol", data1));
        treasuryInstance = Treasury(proxy1);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy1);
        assertFalse(address(treasuryInstance) == implAddressV1);
        // upgrade Treasury
        vm.prank(guardian);
        treasuryInstance.grantRole(UPGRADER_ROLE, managerAdmin);

        vm.startPrank(managerAdmin);
        Upgrades.upgradeProxy(proxy1, "TreasuryV2.sol", "", guardian);
        vm.stopPrank();

        address implAddressV2 = Upgrades.getImplementationAddress(proxy1);
        TreasuryV2 treasuryInstanceV2 = TreasuryV2(proxy1);
        assertEq(treasuryInstanceV2.version(), 2);
        assertFalse(implAddressV2 == implAddressV1);

        bool isUpgrader = treasuryInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin);
        assertTrue(isUpgrader == true);

        vm.prank(guardian);
        treasuryInstanceV2.revokeRole(UPGRADER_ROLE, managerAdmin);
        assertFalse(treasuryInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin) == true);
    }

    function deployTimelockUpgrade() internal {
        // deploy Timelock
        uint256 timelockDelay = 24 * 60 * 60;
        address[] memory temp = new address[](1);
        temp[0] = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        bytes memory data = abi.encodeCall(LendefiTimelock.initialize, (timelockDelay, temp, temp, guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiTimelock.sol", data));
        LendefiTimelock instance = LendefiTimelock(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(instance) == implAddressV1);
        // upgrade Timelock
        vm.prank(guardian);
        instance.grantRole(UPGRADER_ROLE, managerAdmin);

        vm.startPrank(managerAdmin);
        Upgrades.upgradeProxy(proxy, "LendefiTimelockV2.sol", "", guardian);
        vm.stopPrank();

        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        LendefiTimelockV2 ecoInstanceV2 = LendefiTimelockV2(proxy);
        assertEq(ecoInstanceV2.version(), 2);
        assertFalse(implAddressV2 == implAddressV1);
        deployComplete();

        bool isUpgrader = ecoInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin);
        assertTrue(isUpgrader == true);

        vm.prank(guardian);
        ecoInstanceV2.revokeRole(UPGRADER_ROLE, managerAdmin);
        assertFalse(ecoInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin) == true);
    }

    function deployGovernorUpgrade() internal {
        // deploy Token
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);

        // deploy Timelock
        uint256 timelockDelay = 24 * 60 * 60;
        address[] memory temp = new address[](1);
        temp[0] = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        bytes memory data1 = abi.encodeCall(LendefiTimelock.initialize, (timelockDelay, temp, temp, guardian));
        address payable proxy1 = payable(Upgrades.deployUUPSProxy("LendefiTimelock.sol", data1));
        LendefiTimelock instance = LendefiTimelock(proxy1);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy1);
        assertFalse(address(instance) == implAddressV1);

        // deploy Governor
        bytes memory data2 = abi.encodeCall(
            LendefiGovernor.initialize, (tokenInstance, TimelockControllerUpgradeable(payable(proxy1)), guardian)
        );
        address payable proxy2 = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", data2));
        LendefiGovernor govInstanceV1 = LendefiGovernor(proxy2);
        address govImplAddressV1 = Upgrades.getImplementationAddress(proxy2);
        assertFalse(address(govInstanceV1) == govImplAddressV1);
        assertEq(govInstanceV1.uupsVersion(), 1);

        // upgrade Governor
        Upgrades.upgradeProxy(proxy2, "LendefiGovernorV2.sol", "", guardian);
        address govImplAddressV2 = Upgrades.getImplementationAddress(proxy2);

        LendefiGovernorV2 govInstanceV2 = LendefiGovernorV2(proxy2);
        assertEq(govInstanceV2.uupsVersion(), 2);
        assertFalse(govImplAddressV2 == govImplAddressV1);
    }

    function deployComplete() internal {
        vm.warp(365 days);
        // token deploy
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);

        // ecosystem deploy
        bytes memory data1 = abi.encodeCall(Ecosystem.initialize, (address(tokenInstance), guardian, pauser));
        address payable proxy1 = payable(Upgrades.deployUUPSProxy("Ecosystem.sol", data1));
        ecoInstance = Ecosystem(proxy1);
        address ecoImplementation = Upgrades.getImplementationAddress(proxy1);
        assertFalse(address(ecoInstance) == ecoImplementation);

        // timelock deploy
        uint256 timelockDelay = 24 * 60 * 60;
        address[] memory temp = new address[](1);
        temp[0] = ethereum;
        bytes memory data2 = abi.encodeCall(LendefiTimelock.initialize, (timelockDelay, temp, temp, guardian));
        address payable proxy2 = payable(Upgrades.deployUUPSProxy("LendefiTimelock.sol", data2));
        timelockInstance = LendefiTimelock(proxy2);
        address tlImplementation = Upgrades.getImplementationAddress(proxy2);
        assertFalse(address(timelockInstance) == tlImplementation);

        // governor deploy
        bytes memory data3 = abi.encodeCall(
            LendefiGovernor.initialize, (tokenInstance, TimelockControllerUpgradeable(payable(proxy2)), guardian)
        );
        address payable proxy3 = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", data3));
        govInstance = LendefiGovernor(proxy3);
        address govImplementation = Upgrades.getImplementationAddress(proxy3);
        assertFalse(address(govInstance) == govImplementation);

        // reset timelock proposers and executors
        vm.startPrank(guardian);
        timelockInstance.revokeRole(PROPOSER_ROLE, ethereum);
        timelockInstance.revokeRole(EXECUTOR_ROLE, ethereum);
        timelockInstance.revokeRole(CANCELLER_ROLE, ethereum);
        timelockInstance.grantRole(PROPOSER_ROLE, address(govInstance));
        timelockInstance.grantRole(EXECUTOR_ROLE, address(govInstance));
        timelockInstance.grantRole(CANCELLER_ROLE, address(govInstance));
        vm.stopPrank();

        //deploy Treasury
        bytes memory data4 = abi.encodeCall(Treasury.initialize, (guardian, address(timelockInstance)));
        address payable proxy4 = payable(Upgrades.deployUUPSProxy("Treasury.sol", data4));
        treasuryInstance = Treasury(proxy4);
        address tImplementation = Upgrades.getImplementationAddress(proxy4);
        assertFalse(address(treasuryInstance) == tImplementation);
    }
}
