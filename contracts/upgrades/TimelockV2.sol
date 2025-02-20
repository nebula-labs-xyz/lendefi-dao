// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

contract TimelockV2 is TimelockControllerUpgradeable {
    uint256 public version;

    function getVersion() external pure returns (uint256) {
        return 2;
    }
}
