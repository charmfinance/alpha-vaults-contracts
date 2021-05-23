from brownie import accounts, project


# POOL = "0x8ad599c3a0ff1de082011efddc58f1908eb6e6d8"  # USDC / ETH
POOL = "0x4e68ccd3e89f51c3074ca5072bbac773960dfa36"  # ETH / USDT

CARDINALITY = 10


def main():
    deployer = accounts.load("deployer")
    UniswapV3Core = project.load("Uniswap/uniswap-v3-core@1.0.0")

    pool = UniswapV3Core.interface.IUniswapV3Pool(POOL)
    pool.increaseObservationCardinalityNext(CARDINALITY, {"from": deployer})
