from brownie import (
    accounts,
    convert,
    project,
    Contract,
    MockToken,
    Router,
    PassiveRebalanceVault,
)
import json
from math import floor, log, sqrt


UniswapV3Core = project.load("Uniswap/uniswap-v3-core@1.0.0-rc.2")


# rinkeby
ETH = "0x0d5da5fb1e278089fc1370e49ff2b57cabc436c1"
USDC = "0x708273d941f2cfb87607f0f6f64ffdf516d742f8"
ROUTER = "0xc423F5B1e233B31997De5001C03C35F3A9220E6C"
VAULT = "0x8e92BF93EF7c1d6cAC19EBc34BF22037FccA99a6"

FEE = 3000
TICK_SPACING = 60


# https://docs.uniswap.org/reference/Deployments
CONTRACTS = {
    "v3CoreFactoryAddress": "0xAE28628c0fdFb5e54d60FEDC6C9085199aec14dF",
    "weth9Address": "0xc778417E063141139Fce010982780140Aa0cD5Ab",
    "multicall2Address": "0x5BA1e12693Dc8F9c48aAD8770482f4739bEeD696",
    "proxyAdminAddress": "0xc97c7D6C2F1EE518bE4D4B8566bcEb917dED4F39",
    "tickLensAddress": "0x2d31366B7D446d629ac36933F12bdbca96860f84",
    "quoterAddress": "0x7046f9311663DB8B7cf218BC7B6F3f17B0Ea1047",
    "swapRouter": "0x8dF824f7885611c587AA45924BF23153EC832b89",
    "nonfungibleTokenPositionDescriptorAddress": "0x3b1aC1c352F3A18A58471908982b8b870c836EC0",
    "descriptorProxyAddress": "0x539BF58f052dE91ae369dAd59f1ac6887dF39Bc5",
    "nonfungibleTokenPositionManagerAddress": "0xbBca0fFBFE60F60071630A8c80bb6253dC9D6023",
    "v3MigratorAddress": "0xc4b81504F9a2bd6a6f2617091FB01Efb38D119c8",
}


def price_to_tick(price):
    return sqrt_to_tick(price_to_sqrt(price))


def tick_to_price(tick):
    return sqrt_to_price(tick_to_sqrt(tick))


def sqrt_to_tick(sqrtratio):
    tick = 2 * log(sqrtratio / (1 << 96)) / log(1.0001)
    return floor(tick / TICK_SPACING) * TICK_SPACING


def tick_to_sqrt(tick):
    return floor(sqrt(1.0001 ** tick) * (1 << 96))


def price_to_sqrt(price):
    return floor(sqrt(price) * (1 << 96))


def sqrt_to_price(sqrtratio):
    return (sqrtratio / (1 << 96)) ** 2 * 10 ** 10


def _pool():
    factory = UniswapV3Core.interface.IUniswapV3Factory(
        CONTRACTS["v3CoreFactoryAddress"]
    )
    return UniswapV3Core.interface.IUniswapV3Pool(factory.getPool(ETH, USDC, FEE))


def create_pool():
    deployer = accounts.load("deployer")

    eth = deployer.deploy(MockToken, "ETH", "ETH", 18)
    usdc = deployer.deploy(MockToken, "USDC", "USDC", 8)

    factory = UniswapV3Core.interface.IUniswapV3Factory(
        CONTRACTS["v3CoreFactoryAddress"]
    )
    factory.createPool(eth, usdc, FEE, {"from": deployer})

    pool = UniswapV3Core.interface.IUniswapV3Pool(factory.getPool(eth, usdc, FEE))

    inverse = pool.token0() == usdc
    price = 1e18 / 2000e8 if inverse else 2000e8 / 1e18

    # set ETH/USDC price to 2000
    pool.initialize(price_to_sqrt(price), {"from": deployer})

    print(f"ETH address:   {eth.address}")
    print(f"USDC address:  {usdc.address}")
    print(f"Pool address:  {pool.address}")


def deploy_vault():
    deployer = accounts.load("deployer")
    vault = deployer.deploy(PassiveRebalanceVault, _pool(), 2400, 1200, 100)
    MockToken.at(ETH).approve(vault, 1 << 255, {"from": deployer})
    MockToken.at(USDC).approve(vault, 1 << 255, {"from": deployer})

    print(vault.passiveTickLower())
    print(vault.passiveTickUpper())
    print(vault.rebalanceTickLower())
    print(vault.rebalanceTickUpper())

    _print_balances(deployer)
    # vault.mint(1e9, deployer, {"from": deployer})
    vault.mint(1, deployer, {"from": deployer})
    _print_balances(deployer)

    vault.rebalance({"from": deployer})
    print(f"Vault address: {vault.address}")


def deploy_router():
    deployer = accounts.load("deployer")
    router = deployer.deploy(Router)
    MockToken.at(ETH).approve(router, 1 << 255, {"from": deployer})
    MockToken.at(USDC).approve(router, 1 << 255, {"from": deployer})

    # lp over whole range
    _print_balances(deployer)
    router.mint(_pool(), -887220, 887220, 1e14, {"from": deployer})
    _print_balances(deployer)
    print(f"Router address: {router.address}")


def rebalance():
    deployer = accounts.load("deployer")
    vault = PassiveRebalanceVault.at(VAULT)
    print(f"Passive position:    {vault.passivePosition()}")
    print(f"Rebalance position:  {vault.rebalancePosition()}")

    vault.rebalance({"from": deployer})
    print(f"Passive range:    {vault.passiveTickLower()}  {vault.passiveTickUpper()}")
    print(
        f"Rebalance range:  {vault.rebalanceTickLower()}  {vault.rebalanceTickUpper()}"
    )
    _print_balances(vault)


def price():
    pool = _pool()
    tick = pool.slot0()[1]
    inverse = pool.token0() == USDC
    price = 1.0 / tick_to_price(tick) if inverse else tick_to_price(tick)
    print(f"Price:       {price:.3f}")
    print(f"Sqrt ratio:  {tick_to_sqrt(tick)}")
    print(f"Tick:        {tick}")


def vaultMint():
    deployer = accounts.load("deployer")
    vault = PassiveRebalanceVault.at(VAULT)

    _print_balances(deployer)
    vault.mint(1e20, deployer, {"from": deployer})
    _print_balances(deployer)
    print(f"Total supply:  {vault.totalSupply()}")


def vaultBurn():
    deployer = accounts.load("deployer")
    vault = PassiveRebalanceVault.at(VAULT)

    _print_balances(deployer)
    vault.burn(1e20, deployer, {"from": deployer})
    _print_balances(deployer)
    print(f"Total supply:  {vault.totalSupply()}")


def poolMint():
    deployer = accounts.load("deployer")
    router = Router.at(ROUTER)

    _print_balances(deployer)
    router.mint(
        _pool(),
        price_to_tick(1800e8 / 1e18),
        price_to_tick(2200e8 / 1e18),
        1e20,
        {"from": deployer},
    )
    _print_balances(deployer)


def poolBuy():
    deployer = accounts.load("deployer")
    router = Router.at(ROUTER)

    _print_balances(deployer)
    router.swap(_pool(), True, 1e20, {"from": deployer})
    _print_balances(deployer)
    price()


def poolSell():
    deployer = accounts.load("deployer")
    router = Router.at(ROUTER)

    _print_balances(deployer)
    router.swap(_pool(), False, 2000e22, {"from": deployer})
    _print_balances(deployer)
    price()


def _print_balances(account):
    # balance = MockToken.at(ETH).balanceOf(account) * 1e-18
    # print(f"ETH balance:   {balance:.3f}")
    # balance = MockToken.at(USDC).balanceOf(account) * 1e-8
    # print(f"USDC balance:  {balance:.3f}")

    balance = MockToken.at(ETH).balanceOf(account)
    print(f"ETH balance:   {balance}")
    balance = MockToken.at(USDC).balanceOf(account)
    print(f"USDC balance:  {balance}")
