## Alpha Vaults

This repository contains the smart contracts for the Alpha Vaults protocol.

### Usage

Before compiling, run below. The uniswap-v3-periphery has to be cloned otherwise
the naming in Brownie clashes with uniswap-v3-core.

`brownie pm clone Uniswap/uniswap-v3-periphery@1.0.0`

Run tests

`brownie test`

To deploy, modify the parameters in `scripts/deploy_mainnet.py` and run:

`brownie run deploy_mainnet`

To trigger a rebalance, run:

`brownie run rebalance`
