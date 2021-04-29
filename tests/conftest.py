from math import sqrt
import pytest


UNISWAP_V3_CORE = "Uniswap/uniswap-v3-core@1.0.0-rc.2"


@pytest.fixture
def gov(accounts):
    yield accounts[0]


@pytest.fixture
def user(accounts):
    yield accounts[1]


@pytest.fixture
def recipient(accounts):
    yield accounts[2]


@pytest.fixture
def users(gov, user, recipient):
    yield [gov, user, recipient]


@pytest.fixture
def router(Router, gov):
    yield gov.deploy(Router)


@pytest.fixture
def helper(TestHelper, gov):
    yield gov.deploy(TestHelper)


@pytest.fixture
def pool(MockToken, router, pm, gov, users):
    UniswapV3Core = pm(UNISWAP_V3_CORE)

    tokenA = gov.deploy(MockToken, "name A", "symbol A", 18)
    tokenB = gov.deploy(MockToken, "name B", "symbol B", 18)
    fee = 3000

    factory = gov.deploy(UniswapV3Core.UniswapV3Factory)
    tx = factory.createPool(tokenA, tokenB, fee, {"from": gov})
    pool = UniswapV3Core.interface.IUniswapV3Pool(tx.return_value)
    token0 = MockToken.at(pool.token0())
    token1 = MockToken.at(pool.token1())

    # initialize price to 100
    price = int(sqrt(100) * (1 << 96))
    pool.initialize(price, {"from": gov})

    for u in users:
        token0.mint(u, 100e18, {"from": gov})
        token1.mint(u, 10000e18, {"from": gov})
        token0.approve(router, 100e18, {"from": u})
        token1.approve(router, 10000e18, {"from": u})

    # add some liquidity over whole range
    max_tick = 887272 // 60 * 60
    router.mint(
        pool,
        -max_tick,
        max_tick,
        1e16, {"from": gov})
    yield pool


@pytest.fixture
def tokens(MockToken, pool):
    return MockToken.at(pool.token0()), MockToken.at(pool.token1())


@pytest.fixture
def vault(Vault, pool, router, tokens, gov, users):
    vault = gov.deploy(Vault, pool, 2400, 1200, 23*60*60, 600)

    for u in users:
        tokens[0].approve(vault, 100e18, {"from": u})
        tokens[1].approve(vault, 10000e18, {"from": u})
    
    yield vault


@pytest.fixture
def getPositions(pool, helper):
    def f(vault):
        (b0, b1, _) = vault.baseRange()
        (r0, r1, _) = vault.rebalanceRange()
        bkey = helper.computePositionKey(vault, b0, b1)
        rkey = helper.computePositionKey(vault, r0, r1)
        return pool.positions(bkey), pool.positions(rkey)
    yield f


@pytest.fixture
def debug(pool, tokens, helper):
    def f(vault):
        (b0, b1, _) = vault.baseRange()
        (r0, r1, _) = vault.rebalanceRange()
        bkey = helper.computePositionKey(vault, b0, b1)
        rkey = helper.computePositionKey(vault, r0, r1)
        print(f"Passive position:    {pool.positions(bkey)}")
        print(f"Rebalance position:  {pool.positions(rkey)}")
        print(f"Spare balance 0:  {tokens[0].balanceOf(vault)}")
        print(f"Spare balance 1:  {tokens[1].balanceOf(vault)}")
    yield f
