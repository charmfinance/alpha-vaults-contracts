from brownie import (
    accounts,
    project,
    MockToken,
    AlphaStrategy,
    AlphaVault,
    TestRouter,
    ZERO_ADDRESS,
)
from math import floor, sqrt
import time


# Uniswap v3 factory on Rinkeby
FACTORY = "0xAE28628c0fdFb5e54d60FEDC6C9085199aec14dF"

PROTOCOL_FEE = 10000
MAX_TOTAL_SUPPLY = 1e32

BASE_THRESHOLD = 1800
LIMIT_THRESHOLD = 600
MAX_TWAP_DEVIATION = 100
TWAP_DURATION = 60


def main():
    deployer = accounts.load("deployer")
    UniswapV3Core = project.load("Uniswap/uniswap-v3-core@1.0.0")

    eth = deployer.deploy(MockToken, "ETH", "ETH", 18)
    usdc = deployer.deploy(MockToken, "USDC", "USDC", 6)

    eth.mint(deployer, 100 * 1e18, {"from": deployer})
    usdc.mint(deployer, 100000 * 1e6, {"from": deployer})

    factory = UniswapV3Core.interface.IUniswapV3Factory(FACTORY)
    factory.createPool(eth, usdc, 3000, {"from": deployer})
    time.sleep(15)

    pool = UniswapV3Core.interface.IUniswapV3Pool(factory.getPool(eth, usdc, 3000))

    inverse = pool.token0() == usdc
    price = 1e18 / 2000e6 if inverse else 2000e6 / 1e18

    # Set ETH/USDC price to 2000
    pool.initialize(floor(sqrt(price) * (1 << 96)), {"from": deployer})

    # Increase cardinality so TWAP works
    pool.increaseObservationCardinalityNext(100, {"from": deployer})

    router = deployer.deploy(TestRouter)
    MockToken.at(eth).approve(router, 1 << 255, {"from": deployer})
    MockToken.at(usdc).approve(router, 1 << 255, {"from": deployer})

    max_tick = 887272 // 60 * 60
    router.mint(pool, -max_tick, max_tick, 1e14, {"from": deployer})

    vault = deployer.deploy(
        AlphaVault,
        pool,
        PROTOCOL_FEE,
        MAX_TOTAL_SUPPLY,
        publish_source=True,
    )

    strategy = deployer.deploy(
        AlphaStrategy,
        vault,
        BASE_THRESHOLD,
        LIMIT_THRESHOLD,
        MAX_TWAP_DEVIATION,
        TWAP_DURATION,
        deployer,
        publish_source=True,
    )
    vault.setStrategy(strategy, {"from": deployer})

    print(f"Vault address: {vault.address}")
    print(f"Strategy address: {strategy.address}")
    print(f"Router address: {router.address}")
