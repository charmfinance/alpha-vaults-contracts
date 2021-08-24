## Alpha Vaults

This repository contains the smart contracts for the [Alpha Vaults](https://alpha.charm.fi/) protocol.

Feel free to [join our discord](https://discord.gg/6BY3Fq2) if you have any questions.


### Usage

Before compiling, run below. The uniswap-v3-periphery package has to be installed and cloned
otherwise imports don't work.

#### Solidity version

The smart contracts in this repository require `solc v0.7.6` . We recommend using [solc-select](https://github.com/crytic/solc-select) to switch solidity version

```bash
# Install v0.7.6 if you do not have it locally
solc-select install 0.7.6

# Switch to solc 0.7.6
solc-select use 0.7.6
```

#### Install Uniswap v3 Periphery contracts

`brownie pm install Uniswap/uniswap-v3-periphery@1.0.0`

#### Clone v3 Periphery contracts

`brownie pm clone Uniswap/uniswap-v3-periphery@1.0.0`

#### Run tests

`brownie test`

#### Deployment

To deploy, modify the parameters in `scripts/deploy_mainnet.py` and run:

`brownie run deploy_mainnet`

#### Rebalancing

To trigger a rebalance, run:

`brownie run rebalance`


### Bug Bounty

We have a bug bounty program hosted on Immunefi. Please visit [our bounty page](https://immunefi.com/bounty/charm/) for more details
