// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol"; // solhint-disable-line

contract BasicDeployTest is BasicDeploy {
    function test_001_TokenDeploy() public {
        deployTokenUpgrade();
    }

    function test_002_EcosystemDeploy() public {
        deployEcosystemUpgrade();
    }

    function test_003_TreasuryDeploy() public {
        deployTreasuryUpgrade();
    }

    function test_004_TimelockDeploy() public {
        deployTimelockUpgrade();
    }

    function test_005_GovernorDeploy() public {
        deployGovernorUpgrade();
    }

    function test_006_CompleteDeploy() public {
        deployComplete();
        console.log("token:    ", address(tokenInstance));
        console.log("ecosystem:", address(ecoInstance));
        console.log("treasury: ", address(treasuryInstance));
        console.log("governor: ", address(govInstance));
        console.log("timelock: ", address(timelockInstance));
    }

    function test_007_InvestmentManagerDeploy() public {
        deployComplete();
        _deployInvestmentManager();

        assertFalse(
            address(managerInstance) == Upgrades.getImplementationAddress(address(managerInstance)),
            "Implementation should be different from proxy"
        );
    }

    function test_008_DeployIMUpgrade() public {
        deployIMUpgrade();
    }

    function test_009_TGE() public {
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
    }

    function test_010_deployTeamManager() public {
        deployComplete();

        _deployTeamManager();
    }

    function test_011_deployTeamManagerUpgrade() public {
        deployTeamManagerUpgrade();
    }
}
