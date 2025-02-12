// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

contract WETHPriceConsumerV3 {
    int256 public price = 2500e8;

    function setPrice(int256 newPrice) external {
        price = newPrice;
    }

    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, 1, block.timestamp, 1);
    }
}
