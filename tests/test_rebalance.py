from brownie import chain, reverts
import pytest
from pytest import approx

from conftest import computePositionKey


def test_rebalance_when_empty_then_mint(
    vault, pool, tokens, getPositions, gov, user, recipient
):

    # Fast-forward 24 hours to avoid cooldown
    chain.sleep(24 * 60 * 60)

    # Rebalance
    vault.rebalance({"from": gov})

    vault.deposit(1e7, 1 << 255, 1 << 255, user, {"from": user})

    # Check liquidity in pool
    base, rebalance = getPositions(vault)
    assert base[0] > 0
    assert rebalance[0] == 0


@pytest.mark.parametrize("buy", [False, True])
@pytest.mark.parametrize("big", [False, True])
def test_rebalance(vault, pool, tokens, router, getPositions, gov, user, buy, big):

    # Mint some liquidity
    vault.deposit(1e18, 1 << 255, 1 << 255, user, {"from": user})

    # Do a swap to move the price
    qty = 1e16 * [100, 1][buy] * [1, 100][big]
    router.swap(pool, buy, qty, {"from": gov})
    baseLower, baseUpper = vault.baseLower(), vault.baseUpper()
    limitLower, limitUpper = vault.limitLower(), vault.limitUpper()

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
    assert tokens[0].balanceOf(vault) < 1000
    assert tokens[1].balanceOf(vault) < 1000

    # Check event
    total0, total1 = vault.getTotalAmounts()
    (ev,) = tx.events["Rebalance"]
    assert ev["tick"] == tick
    assert approx(ev["totalAmount0"]) == total0
    assert approx(ev["totalAmount1"]) == total1
    assert ev["totalSupply"] == vault.totalSupply()


@pytest.mark.parametrize("buy", [False, True])
def test_rebalance_twap_check(
    vault, pool, tokens, router, getPositions, gov, user, buy
):

    # Reduce max deviation
    vault.setMaxTwapDeviation(500, {"from": gov})

    # Mint some liquidity
    vault.deposit(1e18, 1 << 255, 1 << 255, user, {"from": user})

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


def test_rebalance_cooldown(vault, gov):
    vault.rebalance({"from": gov})

    # After 22 hours, cannot rebalance yet
    chain.sleep(22 * 60 * 60)
    with reverts("cooldown"):
        vault.rebalance({"from": gov})

    # After another 2 hours, rebalance works
    chain.sleep(2 * 60 * 60)
    vault.rebalance({"from": gov})
