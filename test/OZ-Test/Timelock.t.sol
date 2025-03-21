// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BasicDeploy} from "../BasicDeploy.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockV2} from "../../contracts/upgrades/TimelockV2.sol";
import {LendefiGovernor} from "../../contracts/ecosystem/LendefiGovernor.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {GovernanceToken} from "../../contracts/ecosystem/GovernanceToken.sol";

contract TimelockTest is BasicDeploy {
    TimelockControllerUpgradeable public timelock;
    address public admin;
    uint256 public minDelay;
    address[] public proposers;
    address[] public executors;

    function setUp() public {
        admin = address(0x1);
        minDelay = 1 days;
        proposers = new address[](1);
        proposers[0] = address(0x2);
        executors = new address[](1);
        executors[0] = address(0x3);

        // Deploy implementation
        TimelockControllerUpgradeable implementation = new TimelockControllerUpgradeable();

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, minDelay, proposers, executors, admin
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Setup the main timelock instance
        timelock = TimelockControllerUpgradeable(payable(address(proxy)));
    }

    function testInitialSetup() public {
        assertEq(timelock.getMinDelay(), minDelay);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposers[0]));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), executors[0]));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), admin));
    }

    function testScheduleOperation() public {
        vm.startPrank(proposers[0]);

        bytes32 salt = bytes32(0);
        bytes32 predecessor = bytes32(0);
        bytes memory data = "";

        timelock.schedule(address(0x4), 0, data, predecessor, salt, minDelay);

        bytes32 id = timelock.hashOperation(address(0x4), 0, data, predecessor, salt);

        assertTrue(timelock.isOperationPending(id));
        vm.stopPrank();
    }

    // Add to TimelockTest contract
    function testTimelockUpgrade() public {
        // Deploy new implementation
        TimelockV2 newImplementation = new TimelockV2();

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, minDelay, proposers, executors, admin
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(newImplementation), initData);

        // Setup the main timelock instance
        timelock = TimelockControllerUpgradeable(payable(address(proxy)));

        bytes memory data = abi.encodeWithSelector(timelock.updateDelay.selector, 2 days);

        // Schedule upgrade
        bytes32 salt = bytes32(0);
        bytes32 predecessor = bytes32(0);

        vm.prank(proposers[0]);
        timelock.schedule(address(timelock), 0, data, predecessor, salt, minDelay);

        // Wait for delay
        vm.warp(block.timestamp + minDelay);

        // Execute upgrade
        vm.prank(executors[0]);
        timelock.execute(address(timelock), 0, data, predecessor, salt);

        // Verify upgrade
        assertEq(timelock.getMinDelay(), 2 days);
    }

    function test_DeployGovernor() public {
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian, address(timelock)));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
        bytes memory data1 = abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelock, guardian));
        address payable proxy1 = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", data1));
        govInstance = LendefiGovernor(proxy1);
        address govImplementation = Upgrades.getImplementationAddress(proxy1);
        assertFalse(address(govInstance) == govImplementation);
    }
}
