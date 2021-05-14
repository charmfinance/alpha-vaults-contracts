from brownie import chain, reverts
import pytest
from pytest import approx

from conftest import computePositionKey


@pytest.mark.parametrize("buy", [False, True])
@pytest.mark.parametrize("big", [False, True])
def test_rebalance(vault, pool, tokens, router, getPositions, gov, user, buy, big):

    # Mint some liquidity
    vault.deposit(1e16, 1e18, 0, 0, user, {"from": user})
    vault.rebalance({"from": gov})

    # Do a swap to move the price
    qty = 1e16 * [100, 1][buy] * [1, 100][big]
    router.swap(pool, buy, qty, {"from": gov})
    baseLower, baseUpper = vault.baseLower(), vault.baseUpper()
    limitLower, limitUpper = vault.limitLower(), vault.limitUpper()

    # fast forward 1 hour
    chain.sleep(3600)

    # Store fees
    fees0, fees1 = vault.fees0(), vault.fees1()

    # Rebalance
    tx = vault.rebalance({"from": gov})

    # Check old positions are empty
    liquidity, _, _, owed0, owed1 = pool.positions(
        computePositionKey(vault, baseLower, baseUpper)
    )
    assert liquidity == owed0 == owed1 == 0
    liquidity, _, _, owed0, owed1 = pool.positions(
        computePositionKey(vault, limitLower, limitUpper)
    )
    assert liquidity == owed0 == owed1 == 0

    # Check ranges are set correctly
    tick = pool.slot0()[1]
    tickFloor = tick // 60 * 60
    assert vault.baseLower() == tickFloor - 2400
    assert vault.baseUpper() == tickFloor + 60 + 2400
    if buy:
        assert vault.limitLower() == tickFloor + 60
        assert vault.limitUpper() == tickFloor + 60 + 1200
    else:
        assert vault.limitLower() == tickFloor - 1200
        assert vault.limitUpper() == tickFloor

    base, rebalance = getPositions(vault)

    if big:
        # If order is too big, all tokens go to rebalance order
        assert base[0] == 0
        assert rebalance[0] > 0
    else:
        assert base[0] > 0
        assert rebalance[0] > 0

    # Check no tokens left unused. Only small amount left due to rounding
    assert tokens[0].balanceOf(vault) - vault.fees0() < 1000
    assert tokens[1].balanceOf(vault) - vault.fees1() < 1000

    # Check event
    total0, total1 = vault.getTotalAmounts()
    (ev,) = tx.events["Rebalance"]
    assert ev["tick"] == tick
    assert approx(ev["totalAmount0"]) == total0
    assert approx(ev["totalAmount1"]) == total1
    assert ev["totalSupply"] == vault.totalSupply()

    # Check streaming fee charged
    charged0 = vault.fees0() - fees0
    charged1 = vault.fees1() - fees1
    assert approx(charged0, rel=1e-3) == (total0 + charged0) * 0.02 / 24
    assert approx(charged1, rel=1e-3) == (total1 + charged1) * 0.02 / 24

    (ev,) = tx.events["StreamingFees"]
    assert approx(ev["protocolFees0"]) == charged0
    assert approx(ev["protocolFees1"]) == charged1


@pytest.mark.parametrize("buy", [False, True])
def test_rebalance_twap_check(
    vault, pool, tokens, router, getPositions, gov, user, buy
):

    # Reduce max deviation
    vault.setMaxTwapDeviation(500, {"from": gov})

    # Mint some liquidity
    vault.deposit(1e8, 1e10, 0, 0, user, {"from": user})

    # Do a swap to move the price a lot
    qty = 1e16 * 100 * [100, 1][buy]
    router.swap(pool, buy, qty, {"from": gov})

    # Rebalance
    with reverts("maxTwapDeviation"):
        vault.rebalance({"from": gov})

    # Wait for twap period to pass and poke price
    chain.sleep(610)
    router.swap(pool, buy, 1e8, {"from": gov})

    vault.rebalance({"from": gov})
