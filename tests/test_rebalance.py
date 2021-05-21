from brownie import chain, reverts
import pytest
from pytest import approx

from conftest import computePositionKey


@pytest.mark.parametrize("buy", [False, True])
@pytest.mark.parametrize("big", [False, True])
def test_rebalance(
    vault, strategy, pool, tokens, router, getPositions, gov, user, keeper, buy, big
):
    # Mint some liquidity
    vault.deposit(1e16, 1e18, 0, 0, user, {"from": user})
    strategy.rebalance({"from": keeper})

    # Do a swap to move the price
    qty = 1e16 * [100, 1][buy] * [1, 100][big]
    router.swap(pool, buy, qty, {"from": gov})
    baseLower, baseUpper = vault.baseLower(), vault.baseUpper()
    limitLower, limitUpper = vault.limitLower(), vault.limitUpper()

    # fast forward 1 hour
    chain.sleep(3600)

    # Store totals
    total0, total1 = vault.getTotalAmounts()
    totalSupply = vault.totalSupply()
    govShares = vault.balanceOf(gov)

    # Rebalance
    tx = strategy.rebalance({"from": keeper})

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
    assert strategy.lastTick() == tick

    base, rebalance = getPositions(vault)

    if big:
        # If order is too big, all tokens go to rebalance order
        assert base[0] == 0
        assert rebalance[0] > 0
    else:
        assert base[0] > 0
        assert rebalance[0] > 0

    # Check no tokens left unused. Only small amount left due to rounding
    assert tokens[0].balanceOf(vault) - vault.accruedProtocolFees0() < 1000
    assert tokens[1].balanceOf(vault) - vault.accruedProtocolFees1() < 1000

    # Check event
    total0After, total1After = vault.getTotalAmounts()
    (ev,) = tx.events["Snapshot"]
    assert ev["tick"] == tick
    assert approx(ev["totalAmount0"]) == total0After
    assert approx(ev["totalAmount1"]) == total1After
    assert ev["totalSupply"] == vault.totalSupply()

    (ev1, ev2) = tx.events["CollectFees"]
    dtotal0 = total0After - total0 + ev1["feesToProtocol0"] + ev2["feesToProtocol0"]
    dtotal1 = total1After - total1 + ev1["feesToProtocol1"] + ev2["feesToProtocol1"]
    assert (
        approx(ev1["feesFromPool0"] + ev2["feesFromPool0"], rel=1e-6, abs=1) == dtotal0
    )
    assert (
        approx(ev1["feesToProtocol0"] + ev2["feesToProtocol0"], rel=1e-6, abs=1)
        == dtotal0 * 0.01
    )
    assert (
        approx(ev1["feesFromPool1"] + ev2["feesFromPool1"], rel=1e-6, abs=1) == dtotal1
    )
    assert (
        approx(ev1["feesToProtocol1"] + ev2["feesToProtocol1"], rel=1e-6, abs=1)
        == dtotal1 * 0.01
    )


@pytest.mark.parametrize("buy", [False, True])
def test_rebalance_last_tick_check(
    vault, strategy, pool, tokens, router, getPositions, gov, user, keeper, buy
):

    # Set min last tick deviation
    strategy.setMinLastTickDeviation(500, {"from": gov})

    # Can't rebalance
    assert not strategy.canRebalance()
    with reverts("tick"):
        strategy.rebalance({"from": keeper})

    # Do a swap to move the price a lot
    qty = 1e16 * 100 * [100, 1][buy]
    router.swap(pool, buy, qty, {"from": gov})

    # Rebalance
    assert strategy.canRebalance()
    strategy.rebalance({"from": keeper})


@pytest.mark.parametrize("buy", [False, True])
def test_rebalance_twap_check(
    vault, strategy, pool, tokens, router, getPositions, gov, user, keeper, buy
):

    # Reduce max deviation
    strategy.setMaxTwapDeviation(500, {"from": gov})

    # Mint some liquidity
    vault.deposit(1e8, 1e10, 0, 0, user, {"from": user})

    # Do a swap to move the price a lot
    qty = 1e16 * 100 * [100, 1][buy]
    router.swap(pool, buy, qty, {"from": gov})

    # Can't rebalance
    assert not strategy.canRebalance()
    with reverts("tick"):
        strategy.rebalance({"from": keeper})

    # Wait for twap period to pass and poke price
    chain.sleep(610)
    router.swap(pool, buy, 1e8, {"from": gov})

    # Rebalance
    assert strategy.canRebalance()
    strategy.rebalance({"from": keeper})


def test_can_rebalance_when_vault_empty(
    vault, strategy, pool, tokens, gov, user, keeper
):
    assert tokens[0].balanceOf(vault) == 0
    assert tokens[1].balanceOf(vault) == 0
    strategy.rebalance({"from": keeper})
    strategy.rebalance({"from": keeper})

    # Check ranges are set correctly
    tick = pool.slot0()[1]
    tickFloor = tick // 60 * 60
    assert vault.baseLower() == tickFloor - 2400
    assert vault.baseUpper() == tickFloor + 60 + 2400
    assert vault.limitLower() == tickFloor + 60
    assert vault.limitUpper() == tickFloor + 60 + 1200
    assert strategy.lastTick() == tick


def test_only_strategy_can_rebalance(vault, strategy, pool, gov, user, keeper):
    for u in [gov, user, keeper]:
        with reverts("strategy"):
            vault.rebalance(0, 0, 0, 0, 0, 0, {"from": u})

    vault.rebalance(0, 0, 0, 0, 0, 0, {"from": strategy})
