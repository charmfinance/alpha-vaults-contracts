from brownie import accounts, project, PassiveRebalanceVault

UniswapV3Core = project.load("Uniswap/uniswap-v3-core@1.0.0")

POOL = "0x8ad599c3a0ff1de082011efddc58f1908eb6e6d8"  # USDC / ETH

CARDINALITY = 2


def main():
    deployer = accounts.load("deployer")

    pool = UniswapV3Core.interface.IUniswapV3Pool(POOL)
    pool.increaseObservationCardinalityNext(CARDINALITY, {"from": deployer})
