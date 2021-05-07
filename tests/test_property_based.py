from brownie.test import given, strategy
from hypothesis import settings
from pytest import approx

MAX_EXAMPLES = 5


# test to get an idea of how burn/collect works
# def test_router(pool, router, gov, user, tokens):
#     balance0 = tokens[0].balanceOf(user)
#     balance1 = tokens[1].balanceOf(user)
#
#     max_tick = 887272 // 60 * 60
#     tx = router.mint(pool, -max_tick, max_tick, 1e16, {"from": user})
#     print("Mint", tx.return_value)
#
#     router.swap(pool, True, 1e15, {"from": gov})
#     router.swap(pool, False, -1e15, {"from": gov})
#
#     tx = pool.burn(-max_tick, max_tick, 1e16, {"from": user})
#     print("Burn", tx.return_value)
#
#     tx = pool.collect(user, -max_tick, max_tick, 1e15, 1e17, {"from": user})
#     tx = pool.collect(user, -max_tick, max_tick, 1e18, 1e18, {"from": user})
#     print("Collect", tx.return_value)
#
#     print("Balance0", tokens[0].balanceOf(user) - balance0)
#     print("Balance1", tokens[1].balanceOf(user) - balance1)


@given(shares=strategy("uint256", min_value=1e8, max_value=1e20))
@given(buy=strategy("bool"))
@given(qty=strategy("uint256", min_value=1e3, max_value=1e20))
@settings(max_examples=MAX_EXAMPLES)
def test_rebalance_uses_up_all_balances(
    vault, pool, router, gov, user, shares, tokens, buy, qty
):

    # Deposit, move price and rebalance to simulate existing activity
    vault.deposit(shares, 1 << 255, 1 << 255, gov, {"from": gov})
    router.swap(pool, buy, qty, {"from": gov})
    vault.setMaxTwapDeviation(1 << 22, {"from": gov})  # ignore twap deviation

    vault.rebalance({"from": user})

    # Check balances is roughly zero
    assert tokens[0].balanceOf(vault) < 1000
    assert tokens[1].balanceOf(vault) < 1000
