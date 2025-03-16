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
import {DefenderOptions} from "openzeppelin-foundry-upgrades/Options.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockV2} from "../contracts/upgrades/TimelockV2.sol";
import {TeamManager} from "../contracts/ecosystem/TeamManager.sol";
import {TeamManagerV2} from "../contracts/upgrades/TeamManagerV2.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

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
    address constant gnosisSafe = address(0x9999987);
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
        if (address(timelockInstance) == address(0)) {
            _deployTimelock();
        }

        // token deploy
        bytes memory data =
            abi.encodeCall(GovernanceToken.initializeUUPS, (guardian, address(timelockInstance), gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
        assertTrue(tokenInstance.hasRole(UPGRADER_ROLE, gnosisSafe) == true);

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "GovernanceToken.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("GovernanceTokenV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        tokenInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        GovernanceTokenV2 instanceV2 = GovernanceTokenV2(proxy);
        assertEq(instanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == tokenImplementation, "Implementation address didn't change");
        assertTrue(instanceV2.hasRole(UPGRADER_ROLE, gnosisSafe) == true, "Lost UPGRADER_ROLE");
    }

    function deployEcosystemUpgrade() internal {
        vm.warp(365 days);
        _deployToken();
        _deployTimelock();

        // ecosystem deploy
        bytes memory data = abi.encodeCall(
            Ecosystem.initialize, (address(tokenInstance), address(timelockInstance), guardian, gnosisSafe)
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("Ecosystem.sol", data));
        ecoInstance = Ecosystem(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(ecoInstance) == implAddressV1);

        // Verify gnosis multisig has the required role
        assertTrue(ecoInstance.hasRole(UPGRADER_ROLE, gnosisSafe), "Multisig should have UPGRADER_ROLE");

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "Ecosystem.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("EcosystemV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        ecoInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for Ecosystem)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        EcosystemV2 ecoInstanceV2 = EcosystemV2(proxy);
        assertEq(ecoInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(ecoInstanceV2.hasRole(UPGRADER_ROLE, gnosisSafe), "Lost UPGRADER_ROLE");
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
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();

        // deploy Governor
        bytes memory data = abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelockInstance, gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", data));
        govInstance = LendefiGovernor(proxy);
        address govImplAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(govInstance) == govImplAddressV1);
        assertEq(govInstance.uupsVersion(), 1);

        // Verify gnosis multisig has the required role
        assertTrue(govInstance.gnosisSafe() == gnosisSafe, "Gnosis Safe address not set correctly");

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "LendefiGovernor.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("LendefiGovernorV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        govInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for Governor)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address govImplAddressV2 = Upgrades.getImplementationAddress(proxy);
        LendefiGovernorV2 govInstanceV2 = LendefiGovernorV2(proxy);
        assertEq(govInstanceV2.uupsVersion(), 2, "Version not incremented to 2");
        assertFalse(govImplAddressV2 == govImplAddressV1, "Implementation address didn't change");
        assertTrue(govInstanceV2.gnosisSafe() == gnosisSafe, "Lost gnosisSafe address");
    }

    function deployIMUpgrade() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();
        _deployTreasury();

        // deploy Investment Manager
        bytes memory data = abi.encodeCall(
            InvestmentManager.initialize,
            (address(tokenInstance), address(timelockInstance), address(treasuryInstance), guardian, gnosisSafe)
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", data));
        managerInstance = InvestmentManager(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(managerInstance) == implAddressV1);

        // Verify gnosis multisig has the required role
        assertTrue(managerInstance.hasRole(UPGRADER_ROLE, gnosisSafe), "Multisig should have UPGRADER_ROLE");

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "InvestmentManager.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("InvestmentManagerV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        managerInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for InvestmentManager)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        InvestmentManagerV2 imInstanceV2 = InvestmentManagerV2(proxy);
        assertEq(imInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(imInstanceV2.hasRole(UPGRADER_ROLE, gnosisSafe), "Lost UPGRADER_ROLE");
    }

    function deployTeamManagerUpgrade() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();

        // deploy Team Manager with gnosisSafe as the upgrader role
        bytes memory data = abi.encodeCall(
            TeamManager.initialize, (address(tokenInstance), address(timelockInstance), guardian, gnosisSafe)
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implAddressV1);
        assertTrue(tmInstance.hasRole(UPGRADER_ROLE, gnosisSafe) == true);

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "TeamManager.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("TeamManagerV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        tmInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for TeamManager)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        TeamManagerV2 tmInstanceV2 = TeamManagerV2(proxy);
        assertEq(tmInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(tmInstanceV2.hasRole(UPGRADER_ROLE, gnosisSafe) == true, "Lost UPGRADER_ROLE");
    }

    function deployComplete() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();
        _deployEcosystem();
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
        if (address(timelockInstance) == address(0)) {
            _deployTimelock();
        }
        // token deploy
        bytes memory data =
            abi.encodeCall(GovernanceToken.initializeUUPS, (guardian, address(timelockInstance), gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
    }

    function _deployEcosystem() internal {
        // ecosystem deploy
        bytes memory data = abi.encodeCall(
            Ecosystem.initialize, (address(tokenInstance), address(timelockInstance), guardian, gnosisSafe)
        );
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
        uint256 startOffset = 180 days;
        uint256 vestingDuration = 3 * 365 days;
        bytes memory data = abi.encodeCall(
            Treasury.initialize, (guardian, address(timelockInstance), gnosisSafe, startOffset, vestingDuration)
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("Treasury.sol", data));
        treasuryInstance = Treasury(proxy);
        address implAddress = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(treasuryInstance) == implAddress);
    }

    function _deployInvestmentManager() internal {
        // deploy Investment Manager
        bytes memory data = abi.encodeCall(
            InvestmentManager.initialize,
            (address(tokenInstance), address(timelockInstance), address(treasuryInstance), guardian, gnosisSafe)
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", data));
        managerInstance = InvestmentManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(managerInstance) == implementation);
    }

    function _deployTeamManager() internal {
        // deploy Team Manager
        bytes memory data = abi.encodeCall(
            TeamManager.initialize, (address(tokenInstance), address(timelockInstance), guardian, gnosisSafe)
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implementation);
    }

    function deployTreasuryUpgrade() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();

        // deploy Treasury
        uint256 startOffset = 180 days;
        uint256 vestingDuration = 3 * 365 days;

        bytes memory data = abi.encodeCall(
            Treasury.initialize, (guardian, address(timelockInstance), gnosisSafe, startOffset, vestingDuration)
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("Treasury.sol", data));
        treasuryInstance = Treasury(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(treasuryInstance) == implAddressV1);

        // Verify gnosis multisig has the required role
        assertTrue(treasuryInstance.hasRole(treasuryInstance.UPGRADER_ROLE(), gnosisSafe));

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "Treasury.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("TreasuryV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        treasuryInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for Treasury)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        TreasuryV2 treasuryInstanceV2 = TreasuryV2(proxy);
        assertEq(treasuryInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(treasuryInstanceV2.hasRole(treasuryInstanceV2.UPGRADER_ROLE(), gnosisSafe), "Lost UPGRADER_ROLE");
    }
}
