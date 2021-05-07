from brownie import accounts, project, MockToken, PassiveRebalanceVault, TestRouter
from math import floor, sqrt
import time


UniswapV3Core = project.load("Uniswap/uniswap-v3-core@1.0.0")

# Uniswap v3 factory on Rinkeby
FACTORY = "0xAE28628c0fdFb5e54d60FEDC6C9085199aec14dF"


def main():
    deployer = accounts.load("deployer")

    eth = deployer.deploy(MockToken, "ETH", "ETH", 18)
    usdc = deployer.deploy(MockToken, "USDC", "USDC", 8)

    eth.mint(deployer, 100 * 1e18, {"from": deployer})
    usdc.mint(deployer, 100000 * 1e8, {"from": deployer})

    factory = UniswapV3Core.interface.IUniswapV3Factory(FACTORY)
    factory.createPool(eth, usdc, 3000, {"from": deployer})
    pool = UniswapV3Core.interface.IUniswapV3Pool(factory.getPool(eth, usdc, 3000))

    inverse = pool.token0() == usdc
    price = 1e18 / 2000e8 if inverse else 2000e8 / 1e18

    # Set ETH/USDC price to 2000
    pool.initialize(floor(sqrt(price) * (1 << 96)), {"from": deployer})

    # Increase cardinality so TWAP works
    pool.increaseObservationCardinalityNext(100, {"from": deployer})

    router = deployer.deploy(TestRouter)
    MockToken.at(eth).approve(router, 1 << 255, {"from": deployer})
    MockToken.at(usdc).approve(router, 1 << 255, {"from": deployer})

    max_tick = 887272 // 60 * 60
    router.mint(pool, -max_tick, max_tick, 1e15, {"from": deployer})

    vault = deployer.deploy(
        PassiveRebalanceVault,
        pool,
        1800,
        600,
        100,
        0,
        600,
        100e18,
        publish_source=True,
    )

    print(f"Vault address: {vault.address}")
    print(f"Router address: {router.address}")
