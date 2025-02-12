// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

interface IWETH9 is IERC20, IERC20Metadata {
    /// @dev allows users to deposit ETH
    function deposit() external payable;

    /// @dev allows users to withdraw ETH
    /// @param wad amount
    function withdraw(uint256 wad) external;
}
