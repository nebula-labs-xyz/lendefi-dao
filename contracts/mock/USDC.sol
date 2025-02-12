// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20Mock} from "./ERC20Mock.sol";

contract USDC is ERC20Mock("USD Coin", "USDC") {
    function drip(address to) public {
        _mint(to, 20000e6);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
