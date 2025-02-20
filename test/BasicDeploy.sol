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
import {InvestmentManager} from "../contracts/ecosystem/InvestmentManager.sol";
import {InvestmentManagerV2} from "../contracts/upgrades/InvestmentManagerV2.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockV2} from "../contracts/upgrades/TimelockV2.sol";
import {TeamManager} from "../contracts/ecosystem/TeamManager.sol";
import {TeamManagerV2} from "../contracts/upgrades/TeamManagerV2.sol";

contract BasicDeploy is Test {
    event Upgrade(address indexed src, address indexed implementation);

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 internal constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 internal constant DAO_ROLE = keccak256("DAO_ROLE");

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
    TimelockControllerUpgradeable internal timelockInstance;
    LendefiGovernor internal govInstance;
    Treasury internal treasuryInstance;
    InvestmentManager internal managerInstance;
    TeamManager internal tmInstance;
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
        _deployToken();

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

        _deployToken();
        _deployTimelock();

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
        // timelock deploy
        uint256 timelockDelay = 24 * 60 * 60;
        address[] memory temp = new address[](1);
        temp[0] = ethereum;

        TimelockControllerUpgradeable implementation = new TimelockControllerUpgradeable();
        bytes memory initData = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, timelockDelay, temp, temp, guardian
        );
        ERC1967Proxy proxy1 = new ERC1967Proxy(address(implementation), initData);

        timelockInstance = TimelockControllerUpgradeable(payable(address(proxy1)));

        // deploy Timelock Upgrade, ERC1967Proxy
        TimelockV2 newImplementation = new TimelockV2();
        bytes memory initData2 = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, timelockDelay, temp, temp, guardian
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(newImplementation), initData2);
        timelockInstance = TimelockControllerUpgradeable(payable(address(proxy2)));
    }

    function deployGovernorUpgrade() internal {
        _deployToken();
        _deployTimelock();

        // deploy Governor
        bytes memory data2 = abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelockInstance, guardian));
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

    function deployIMUpgrade() internal {
        vm.warp(365 days);

        _deployToken();
        _deployTimelock();
        _deployTreasury();

        // deploy Investment Manager
        bytes memory data4 = abi.encodeCall(
            InvestmentManager.initialize,
            (address(tokenInstance), address(timelockInstance), address(treasuryInstance), guardian)
        );
        address payable proxy4 = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", data4));
        managerInstance = InvestmentManager(proxy4);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy4);
        assertFalse(address(managerInstance) == implAddressV1);

        // upgrade InvestmentManager
        vm.prank(guardian);
        managerInstance.grantRole(UPGRADER_ROLE, managerAdmin);

        vm.startPrank(managerAdmin);
        Upgrades.upgradeProxy(proxy4, "InvestmentManagerV2.sol:InvestmentManagerV2", "", guardian);
        vm.stopPrank();

        address implAddressV2 = Upgrades.getImplementationAddress(proxy4);
        InvestmentManagerV2 imInstanceV2 = InvestmentManagerV2(proxy4);
        assertEq(imInstanceV2.version(), 2);
        assertFalse(implAddressV2 == implAddressV1);

        bool isUpgrader = imInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin);
        assertTrue(isUpgrader == true);

        vm.prank(guardian);
        imInstanceV2.revokeRole(UPGRADER_ROLE, managerAdmin);
        assertFalse(imInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin) == true);
    }

    function deployTeamManagerUpgrade() internal {
        vm.warp(365 days);

        deployComplete();

        // deploy Team Manager
        bytes memory data =
            abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implAddressV1);

        // upgrade Team Manager
        vm.prank(guardian);
        tmInstance.grantRole(UPGRADER_ROLE, managerAdmin);

        vm.startPrank(managerAdmin);
        Upgrades.upgradeProxy(proxy, "TeamManagerV2.sol:TeamManagerV2", "", guardian);
        vm.stopPrank();

        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        TeamManagerV2 tmInstanceV2 = TeamManagerV2(proxy);
        assertEq(tmInstanceV2.version(), 2);
        assertFalse(implAddressV2 == implAddressV1);

        bool isUpgrader = tmInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin);
        assertTrue(isUpgrader == true);

        vm.prank(guardian);
        tmInstanceV2.revokeRole(UPGRADER_ROLE, managerAdmin);
        assertFalse(tmInstanceV2.hasRole(UPGRADER_ROLE, managerAdmin) == true);
    }

    function deployComplete() internal {
        vm.warp(365 days);
        _deployToken();
        _deployEcosystem();
        _deployTimelock();
        _deployGovernor();

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
        _deployTreasury();
    }

    function _deployToken() internal {
        // token deploy
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
    }

    function _deployEcosystem() internal {
        // ecosystem deploy
        bytes memory data = abi.encodeCall(Ecosystem.initialize, (address(tokenInstance), guardian, pauser));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Ecosystem.sol", data));
        ecoInstance = Ecosystem(proxy);
        address ecoImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(ecoInstance) == ecoImplementation);
    }

    function _deployTimelock() internal {
        // timelock deploy
        uint256 timelockDelay = 24 * 60 * 60;
        address[] memory temp = new address[](1);
        temp[0] = ethereum;
        TimelockControllerUpgradeable timelock = new TimelockControllerUpgradeable();

        bytes memory initData = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, timelockDelay, temp, temp, guardian
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(timelock), initData);
        timelockInstance = TimelockControllerUpgradeable(payable(address(proxy)));
    }

    function _deployGovernor() internal {
        // deploy Governor
        bytes memory data = abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelockInstance, guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", data));
        govInstance = LendefiGovernor(proxy);
        address govImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(govInstance) == govImplementation);
        assertEq(govInstance.uupsVersion(), 1);
    }

    function _deployTreasury() internal {
        // deploy Treasury
        bytes memory data = abi.encodeCall(Treasury.initialize, (guardian, address(timelockInstance)));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Treasury.sol", data));
        treasuryInstance = Treasury(proxy);
        address implAddress = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(treasuryInstance) == implAddress);
    }

    function _deployInvestmentManager() internal {
        // deploy Investment Manager
        bytes memory data = abi.encodeCall(
            InvestmentManager.initialize,
            (address(tokenInstance), address(timelockInstance), address(treasuryInstance), guardian)
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", data));
        managerInstance = InvestmentManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(managerInstance) == implementation);
    }

    function _deployTeamManager() internal {
        // deploy Team Manager
        bytes memory data =
            abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implementation);
    }
}
