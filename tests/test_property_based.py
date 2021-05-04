from brownie.test import given, strategy
from hypothesis import settings
from pytest import approx

MAX_EXAMPLES = 5


@given(shares1=strategy("uint256", min_value=1e8, max_value=1e20))
@given(shares2=strategy("uint256", min_value=1e8, max_value=1e20))
@given(buy=strategy("bool"))
@given(qty=strategy("uint256", min_value=1e3, max_value=1e24))
@settings(max_examples=MAX_EXAMPLES)
def test_deposit(vault, pool, router, gov, user, shares1, shares2, buy, qty):

    # Deposit, move price and rebalance to simulate existing activity
    vault.deposit(shares1, 1<<255, 1<<255, gov, {"from": gov})
    router.swap(pool, buy, qty, {"from": gov})
    vault.setMaxTwapDeviation(1<<22, {"from": gov})  # ignore twap deviation
    vault.rebalance({"from": gov})

    before = get_stats(vault)
    tx = vault.deposit(shares2, 1<<255, 1<<255, gov, {"from": gov})
    amount0, amount1 = tx.return_value
    after = get_stats(vault)

    # Check amount per share is roughly the same
    assert approx(after["perShare0"], rel=1e-3) == before["perShare0"]
    assert approx(after["perShare1"], rel=1e-3) == before["perShare1"]

    # Check amount per share doesn't decrease
    assert after["perShare0"] >= before["perShare0"]
    assert after["perShare1"] >= before["perShare1"]

    # Check ratios
    assert approx(after["total0"] * amount1, rel=1e-5) == after["total1"] * amount0
    assert approx(before["total0"] * amount1, rel=1e-5) == before["total1"] * amount0


@given(shares=strategy("uint256", min_value=1e8, max_value=1e20))
@given(buy=strategy("bool"))
@given(qty=strategy("uint256", min_value=1e3, max_value=1e24))
@settings(max_examples=MAX_EXAMPLES)
def test_rebalance(vault, pool, router, gov, user, shares, tokens, buy, qty):

    # Deposit, move price and rebalance to simulate existing activity
    vault.deposit(shares, 1<<255, 1<<255, gov, {"from": gov})
    router.swap(pool, buy, qty, {"from": gov})
    vault.setMaxTwapDeviation(1<<22, {"from": gov})  # ignore twap deviation

    before = get_stats(vault)
    vault.rebalance({"from": user})
    after = get_stats(vault)

    # Check total amounts is roughly the same. They should only increase a bit
    # due to fees earned
    assert approx(after["total0"], rel=1e-3) == before["total0"]
    assert approx(after["total1"], rel=1e-3) == before["total1"]
    assert after["total0"] >= before["total0"] - 2
    assert after["total1"] >= before["total1"] - 2

    # Check balances is roughly zero
    assert tokens[0].balanceOf(vault) < 1000
    assert tokens[1].balanceOf(vault) < 1000


def get_stats(vault):
    total0, total1 = vault.getTotalAmounts()
    totalSupply = vault.totalSupply()
    return {
        "total0": total0,
        "total1": total1,
        "perShare0": total0 / max(totalSupply, 1),
        "perShare1": total1 / max(totalSupply, 1),
    }
