// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";
import {GovernanceToken} from "../contracts/ecosystem/GovernanceToken.sol";
import {Ecosystem} from "../contracts/ecosystem/Ecosystem.sol";
import {Treasury} from "../contracts/ecosystem/Treasury.sol";
import {LendefiGovernor} from "../contracts/ecosystem/LendefiGovernor.sol";
import {InvestmentManager} from "../contracts/ecosystem/InvestmentManager.sol";
import {TeamManager} from "../contracts/ecosystem/TeamManager.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DefenderOptions} from "openzeppelin-foundry-upgrades/Options.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployLendefiDAO
 * @notice Comprehensive deployment script for the entire Lendefi DAO ecosystem
 * @dev Deploys and configures all core contracts with proper access controls and inline verification
 */
contract DeployLendefiDAO is Script, Test {
    // Constants
    uint256 internal constant TIMELOCK_DELAY = 24 hours;
    uint256 internal constant TREASURY_START_OFFSET = 180 days;
    uint256 internal constant TREASURY_VESTING_DURATION = 3 * 365 days;

    // Common roles
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    address internal constant ETHEREUM = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Core addresses from environment variables
    address public guardian;
    address public multisig;

    // Core contract instances
    TimelockControllerUpgradeable public timelockInstance;
    GovernanceToken public tokenInstance;
    Ecosystem public ecosystemInstance;
    LendefiGovernor public governorInstance;
    Treasury public treasuryInstance;
    InvestmentManager public investmentManagerInstance;
    TeamManager public teamManagerInstance;

    // Defender integration variables
    string public relayerId;
    string public approvalProcessId;

    function setUp() public {
        // Required addresses
        guardian = vm.envAddress("GUARDIAN_ADDRESS");
        multisig = vm.envAddress("MULTISIG_ADDRESS");

        // Optional Defender configuration
        try vm.envString("DEFENDER_RELAYER_ID") returns (string memory value) {
            relayerId = value;
        } catch {
            relayerId = "";
        }

        try vm.envString("DEFENDER_APPROVAL_PROCESS") returns (string memory value) {
            approvalProcessId = value;
        } catch {
            approvalProcessId = "";
        }

        // Verify required addresses are set
        assertTrue(guardian != address(0), "Guardian address not set");
        assertTrue(multisig != address(0), "Multisig address not set");
    }

    function run() public {
        console.log("Starting Lendefi DAO deployment...");
        vm.startBroadcast();

        // Deploy all contracts in the correct sequence
        deployTimelock();
        deployToken();
        deployEcosystem();
        deployGovernor();
        deployTreasury();
        deployTeamManager();
        deployInvestmentManager();

        // Configure proper access controls
        configureAccessControl();

        vm.stopBroadcast();
        console.log("Lendefi DAO deployment complete and verified!");
    }

    /**
     * @notice Deploy the timelock controller with verification
     */
    function deployTimelock() internal {
        console.log("Deploying Timelock Controller...");

        // Set initial proposers and executors
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = ETHEREUM;
        executors[0] = ETHEREUM;

        TimelockControllerUpgradeable timelock = new TimelockControllerUpgradeable();
        bytes memory timelockData = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, TIMELOCK_DELAY, proposers, executors, guardian
        );

        ERC1967Proxy timelockProxy = new ERC1967Proxy(address(timelock), timelockData);
        timelockInstance = TimelockControllerUpgradeable(payable(address(timelockProxy)));

        // Verify timelock deployment
        assertTrue(address(timelockInstance) != address(0), "Timelock deployment failed");
        assertTrue(timelockInstance.hasRole(timelockInstance.PROPOSER_ROLE(), ETHEREUM), "Proposer role not set");
        assertTrue(timelockInstance.hasRole(timelockInstance.EXECUTOR_ROLE(), ETHEREUM), "Executor role not set");
        assertEq(timelockInstance.getMinDelay(), TIMELOCK_DELAY, "Timelock delay not set correctly");

        console.log("* Timelock deployed and verified at:", address(timelockInstance));
    }

    /**
     * @notice Deploy the governance token with Defender integration
     */
    function deployToken() internal {
        console.log("Deploying Governance Token...");

        bytes memory tokenData = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian, address(timelockInstance)));

        // Create options with Defender enabled if configured
        Options memory opts = getDefaultOptions("GovernanceToken.sol");
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", tokenData, opts));
        tokenInstance = GovernanceToken(proxy);

        address tokenImplementation = Upgrades.getImplementationAddress(proxy);

        // Verify token deployment
        assertTrue(address(tokenInstance) != address(0), "Token deployment failed");
        assertTrue(tokenInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)), "Timelock not admin of token");
        assertTrue(tokenInstance.hasRole(PAUSER_ROLE, guardian), "Guardian not pauser of token");
        assertTrue(tokenInstance.hasRole(UPGRADER_ROLE, multisig), "Multisig not upgrader of token");

        console.log("* GovernanceToken deployed and verified at:", address(tokenInstance));
        console.log("  Implementation address:", tokenImplementation);
    }

    /**
     * @notice Deploy the ecosystem contract
     */
    function deployEcosystem() internal {
        console.log("Deploying Ecosystem...");

        bytes memory ecosystemData =
            abi.encodeCall(Ecosystem.initialize, (address(tokenInstance), address(timelockInstance), multisig));

        Options memory opts = getDefaultOptions("Ecosystem.sol");
        address payable proxy = payable(Upgrades.deployUUPSProxy("Ecosystem.sol", ecosystemData, opts));
        ecosystemInstance = Ecosystem(proxy);

        address ecosystemImplementation = Upgrades.getImplementationAddress(proxy);

        // Verify ecosystem deployment
        assertTrue(address(ecosystemInstance) != address(0), "Ecosystem deployment failed");
        assertTrue(
            ecosystemInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)), "Timelock not admin of ecosystem"
        );
        assertTrue(ecosystemInstance.hasRole(PAUSER_ROLE, guardian), "Guardian not pauser of ecosystem");
        assertTrue(ecosystemInstance.hasRole(UPGRADER_ROLE, multisig), "Multisig not upgrader of ecosystem");

        console.log("* Ecosystem deployed and verified at:", address(ecosystemInstance));
        console.log("  Implementation address:", ecosystemImplementation);
    }

    /**
     * @notice Deploy the governor contract
     */
    function deployGovernor() internal {
        console.log("Deploying Lendefi Governor...");

        bytes memory governorData =
            abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelockInstance, multisig));

        Options memory opts = getDefaultOptions("LendefiGovernor.sol");
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", governorData, opts));
        governorInstance = LendefiGovernor(proxy);

        address governorImplementation = Upgrades.getImplementationAddress(proxy);

        // Verify governor deployment
        assertTrue(address(governorInstance) != address(0), "Governor deployment failed");
        assertTrue(
            governorInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)), "Timelock not admin of governor"
        );
        assertTrue(governorInstance.hasRole(UPGRADER_ROLE, multisig), "Multisig not upgrader of governor");
        assertEq(address(governorInstance.token()), address(tokenInstance), "Token not correctly set");
        assertEq(address(governorInstance.timelock()), address(timelockInstance), "Timelock not correctly set");

        console.log("* Governor deployed and verified at:", address(governorInstance));
        console.log("  Implementation address:", governorImplementation);
    }

    /**
     * @notice Deploy the treasury contract
     */
    function deployTreasury() internal {
        console.log("Deploying Treasury...");

        bytes memory treasuryData = abi.encodeCall(
            Treasury.initialize, (address(timelockInstance), multisig, TREASURY_START_OFFSET, TREASURY_VESTING_DURATION)
        );

        Options memory opts = getDefaultOptions("Treasury.sol");
        address payable proxy = payable(Upgrades.deployUUPSProxy("Treasury.sol", treasuryData, opts));
        treasuryInstance = Treasury(proxy);

        address treasuryImplementation = Upgrades.getImplementationAddress(proxy);

        // Verify treasury deployment
        assertTrue(address(treasuryInstance) != address(0), "Treasury deployment failed");
        assertTrue(
            treasuryInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)), "Timelock not admin of treasury"
        );
        assertTrue(treasuryInstance.hasRole(PAUSER_ROLE, guardian), "Guardian not pauser of treasury");
        assertTrue(treasuryInstance.hasRole(UPGRADER_ROLE, multisig), "Multisig not upgrader of treasury");
        assertTrue(
            treasuryInstance.hasRole(MANAGER_ROLE, address(timelockInstance)), "Timelock not manager of treasury"
        );

        console.log("* Treasury deployed and verified at:", address(treasuryInstance));
        console.log("  Implementation address:", treasuryImplementation);
    }

    /**
     * @notice Deploy the team manager contract
     */
    function deployTeamManager() internal {
        console.log("Deploying Team Manager...");

        bytes memory teamManagerData =
            abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), multisig));

        Options memory opts = getDefaultOptions("TeamManager.sol");
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", teamManagerData, opts));
        teamManagerInstance = TeamManager(proxy);

        address teamManagerImplementation = Upgrades.getImplementationAddress(proxy);

        // Verify team manager deployment
        assertTrue(address(teamManagerInstance) != address(0), "TeamManager deployment failed");
        assertTrue(
            teamManagerInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)),
            "Timelock not admin of team manager"
        );
        assertTrue(teamManagerInstance.hasRole(PAUSER_ROLE, guardian), "Guardian not pauser of team manager");
        assertTrue(teamManagerInstance.hasRole(UPGRADER_ROLE, multisig), "Multisig not upgrader of team manager");
        assertTrue(
            teamManagerInstance.hasRole(MANAGER_ROLE, address(timelockInstance)), "Timelock not manager of team manager"
        );

        console.log("* TeamManager deployed and verified at:", address(teamManagerInstance));
        console.log("  Implementation address:", teamManagerImplementation);
    }

    /**
     * @notice Deploy the investment manager contract
     */
    function deployInvestmentManager() internal {
        console.log("Deploying Investment Manager...");

        bytes memory investmentManagerData = abi.encodeCall(
            InvestmentManager.initialize, (address(tokenInstance), address(timelockInstance), address(treasuryInstance))
        );

        Options memory opts = getDefaultOptions("InvestmentManager.sol");
        address payable proxy = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", investmentManagerData, opts));
        investmentManagerInstance = InvestmentManager(proxy);

        address investmentManagerImplementation = Upgrades.getImplementationAddress(proxy);

        // Verify investment manager deployment
        assertTrue(address(investmentManagerInstance) != address(0), "InvestmentManager deployment failed");
        assertTrue(
            investmentManagerInstance.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)),
            "Timelock not admin of investment manager"
        );
        assertTrue(
            investmentManagerInstance.hasRole(PAUSER_ROLE, guardian), "Guardian not pauser of investment manager"
        );
        assertTrue(
            investmentManagerInstance.hasRole(UPGRADER_ROLE, multisig), "Multisig not upgrader of investment manager"
        );
        assertTrue(
            investmentManagerInstance.hasRole(MANAGER_ROLE, address(timelockInstance)),
            "Timelock not manager of investment manager"
        );
        assertEq(investmentManagerInstance.treasury(), address(treasuryInstance), "Treasury not correctly set");

        console.log("* InvestmentManager deployed and verified at:", address(investmentManagerInstance));
        console.log("  Implementation address:", investmentManagerImplementation);
    }

    /**
     * @notice Configure access control settings across all contracts with verification
     */
    function configureAccessControl() internal {
        console.log("Configuring access controls...");

        // Transfer timelock control from ETHEREUM placeholder to governor
        vm.startPrank(guardian);
        timelockInstance.revokeRole(PROPOSER_ROLE, ETHEREUM);
        timelockInstance.revokeRole(EXECUTOR_ROLE, ETHEREUM);
        timelockInstance.revokeRole(CANCELLER_ROLE, ETHEREUM);

        timelockInstance.grantRole(PROPOSER_ROLE, address(governorInstance));
        timelockInstance.grantRole(EXECUTOR_ROLE, address(governorInstance));
        timelockInstance.grantRole(CANCELLER_ROLE, address(governorInstance));
        vm.stopPrank();

        // Verify role configuration
        assertTrue(timelockInstance.hasRole(PROPOSER_ROLE, address(governorInstance)), "Governor not proposer");
        assertTrue(timelockInstance.hasRole(EXECUTOR_ROLE, address(governorInstance)), "Governor not executor");
        assertTrue(timelockInstance.hasRole(CANCELLER_ROLE, address(governorInstance)), "Governor not canceller");

        assertFalse(timelockInstance.hasRole(PROPOSER_ROLE, ETHEREUM), "ETHEREUM still proposer");
        assertFalse(timelockInstance.hasRole(EXECUTOR_ROLE, ETHEREUM), "ETHEREUM still executor");
        assertFalse(timelockInstance.hasRole(CANCELLER_ROLE, ETHEREUM), "ETHEREUM still canceller");

        console.log("* Access controls configured and verified successfully");
    }

    /**
     * @notice Helper to get default options for contract deployment
     * @param referenceContract The contract reference name
     * @return Options struct with standard settings
     */
    function getDefaultOptions(string memory referenceContract) internal view returns (Options memory) {
        return Options({
            referenceContract: referenceContract,
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: bytes(relayerId).length > 0, // Enable Defender deployment if configured
                skipVerifySourceCode: false,
                relayerId: relayerId,
                salt: bytes32(0),
                upgradeApprovalProcessId: approvalProcessId
            })
        });
    }
}
