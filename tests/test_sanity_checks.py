import pytest
from pytest import approx


@pytest.mark.parametrize(
    "shares",
    [1e4, 1e18],
)
def test_total_amounts(vaultAfterPriceMove, tokens, user, recipient, shares):
    vault = vaultAfterPriceMove

    # Store balances and total amounts
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)
    total0, total1 = vault.getTotalAmounts()

    # Mint some liquidity
    tx = vault.deposit(shares, 1 << 255, 1 << 255, recipient, {"from": user})
    amount0, amount1 = tx.return_value

    # Check amounts match total amounts
    assert approx(amount0, abs=1) == vault.getTotalAmounts()[0] - total0
    assert approx(amount1, abs=1) == vault.getTotalAmounts()[1] - total1


@pytest.mark.parametrize(
    "shares",
    [1e4, 1e18],
)
def test_total_amounts_per_share_do_not_decrease(
    vaultAfterPriceMove, tokens, user, recipient, shares
):
    vault = vaultAfterPriceMove

    # Store balances and total amounts
    total0, total1 = vault.getTotalAmounts()
    supply = vault.totalSupply()
    valuePerShare0 = total0 / supply
    valuePerShare1 = total1 / supply

    # Mint some liquidity
    vault.deposit(shares, 1 << 255, 1 << 255, recipient, {"from": user})

    # Check amounts match total amounts
    total0, total1 = vault.getTotalAmounts()
    supply = vault.totalSupply()
    newValuePerShare0 = total0 / supply
    newValuePerShare1 = total1 / supply
    assert newValuePerShare0 >= valuePerShare0
    assert newValuePerShare1 >= valuePerShare1
    assert approx(newValuePerShare0, abs=1) == valuePerShare0
    assert approx(newValuePerShare1, abs=1) == valuePerShare1


@pytest.mark.parametrize("buy", [False, True])
@pytest.mark.parametrize("big", [False, True])
def test_total_amounts_do_not_change_after_rebalance(
    vault, pool, tokens, router, getPositions, gov, user, buy, big
):

    # Mint some liquidity
    vault.deposit(1e18, 1 << 255, 1 << 255, gov, {"from": gov})

    # Do a swap to move the price
    qty = 1e16 * [100, 1][buy] * [1, 100][big]
    router.swap(pool, buy, qty, {"from": gov})

    # Rebalance
    total0, total1 = vault.getTotalAmounts()
    vault.rebalance({"from": gov})

    # Check total amounts haven't changed - they should only increase a bit due to fees earned
    newTotal0, newTotal1 = vault.getTotalAmounts()
    if buy:
        assert approx(total1) == newTotal1
        assert approx(total0, rel=1e-2) == newTotal0
        assert total0 < newTotal0
    else:
        assert approx(total0) == newTotal0
        assert approx(total1, rel=1e-2) == newTotal1
        assert total1 < newTotal1
