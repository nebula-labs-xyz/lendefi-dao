# Lendefi DAO

```
 *      ,,,          ,,     ,,,    ,,,      ,,   ,,,  ,,,      ,,,    ,,,   ,,,    ,,,   ,,,
 *      ██▌          ███▀▀▀███▄   ███▄     ██   ██▄██▀▀██▄     ███▀▀▀███▄   ██▄██▀▀██▄  ▄██╟
 *     ██▌          ██▌          █████,   ██   ██▌     └██▌   ██▌          ██▌          ██
 *    ╟█l          ███▀▄███     ██ └███  ██   l██       ██╟  ███▀▄███     ██▌└██╟██    ╟█i
 *    ██▌         ██▌          ██    ╙████    ██▌     ,██▀  ██▌          ██▌           ██
 *   █████▀▄██▀  █████▀▀▄██▀  ██      ╙██    ██▌██▌╙███▀`  █████▀▀▄██▀  ╙██          ╙██
 *  ¬─     ¬─   ¬─¬─  ¬─¬─'  ¬─¬─     ¬─'   ¬─¬─   '¬─    '─¬   ¬─      ¬─'          ¬─'
```

## Introduction

Lendefi is a lending protocol designed for EVM blockchains by Nebula Labs.
It fixes several problems uncovered with current lending protocols such as
Compound III, AAVE and MakerDAO. Using all the latest and greatest.
This repo contains just the DAO contracts.
For more information visit [Nebula Labs](https://nebula-labs.xyz).

## Features

1. Supports more than 200 collateral assets.
2. Up to 20 collateral assets per user at a time.
3. Compounds interest.
4. Gas Efficient.
5. Issues ERC20 yield token to lenders.
6. Completely upgradeable.
7. DAO Managed.
8. Reward Ecosystem.

## Disclaimer

This software is provided as is with a Business Source License 1.1 without warranties of any kind.
Some libraries included with this software are licenced under the MIT license, while others
require GPL-v3.0. The smart contracts are labeled accordingly.

## Important Information

You need to hold 20_000 governance tokens to be able to run liquidations on the Nebula Protocol.

## Running tests

This is a foundry repository. To get more information visit [Foundry](https://github.com/foundry-rs/foundry/blob/master/foundryup/README.md).
You must have foundry installed.

```
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

then

```
git clone https://github.com/nebula-labs-xyz/lendefi-dao
cd lendefi-dao

npm install
forge clean && forge build && forge test -vvv --ffi --gas-report
```
