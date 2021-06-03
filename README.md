## Alpha Vaults

This repository contains the smart contracts for the [Alpha Vaults](https://alpha.charm.fi/) protocol.

Feel free to [join our discord](https://discord.gg/6BY3Fq2) if you have any questions.

### Usage

Install brownie

`pip3 install eth-brownie`

Install node modules and ganache

`npm install`

`npm install -g ganache-cli`

Before compiling, run below. The uniswap-v3-periphery package has to be cloned
otherwise imports don't work.

`brownie pm install Uniswap/uniswap-v3-periphery@1.0.0`

and then

`brownie pm clone Uniswap/uniswap-v3-periphery@1.0.0`

Run tests

`brownie test`

To deploy, modify the parameters in `scripts/deploy_mainnet.py` and run:

`brownie run deploy_mainnet`

To trigger a rebalance, run:

`brownie run rebalance`

### Bug Bounty

We have a bug bounty program hosted on Immunefi. Please visit [our bounty page](https://immunefi.com/bounty/charm/) for more details
