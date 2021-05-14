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


@given(amount0Desired=strategy("uint256", min_value=0, max_value=1e18))
@given(amount1Desired=strategy("uint256", min_value=0, max_value=1e18))
@given(buy=strategy("bool"))
@given(qty=strategy("uint256", min_value=1e3, max_value=1e18))
@settings(max_examples=MAX_EXAMPLES)
def test_deposit(
    vault, pool, router, gov, user, tokens, amount0Desired, amount1Desired, buy, qty
):
    # Set fee to 0 since this when an arb is most likely to work
    vault.setDepositFee(0, {"from": gov})
    vault.setStreamingFee(0, {"from": gov})

    # Simulate deposit and random price move
    vault.deposit(1e16, 1e18, 0, 0, user, {"from": user})
    vault.rebalance({"from": gov})
    router.swap(pool, buy, qty, {"from": user})

    # Store totals
    total0, total1 = vault.getTotalAmounts()
    totalSupply = vault.totalSupply()

    # Ignore when output shares is 0:
    if amount1Desired == 0 and total1 > 0:
        return
    if amount0Desired == 0 and total0 > 0:
        return

    # Deposit
    tx = vault.deposit(amount0Desired, amount1Desired, 0, 0, user, {"from": user})
    shares, amount0, amount1 = tx.return_value

    # Check amounts don't exceed desired
    assert amount0 <= amount0Desired
    assert amount1 <= amount1Desired

    # Check one is tight
    assert amount0 == amount0Desired or amount1 == amount1Desired

    # Check ratios stay the same
    if amount0Desired > 1000 and amount1Desired > 1000:
        assert approx(amount0 * total1, rel=1e-4) == amount1 * total0
        assert approx(amount0 * totalSupply, rel=1e-4) == shares * total0
        assert approx(amount1 * totalSupply, rel=1e-4) == shares * total1

    # Check doesn't under-pay
    assert amount0 * totalSupply >= shares * total0
    assert amount1 * totalSupply >= shares * total1


@given(amount0Desired=strategy("uint256", min_value=1e8, max_value=1e18))
@given(amount1Desired=strategy("uint256", min_value=1e8, max_value=1e18))
@given(buy=strategy("bool"))
@given(qty=strategy("uint256", min_value=1e3, max_value=1e18))
@settings(max_examples=MAX_EXAMPLES)
def test_rebalance(
    vault, pool, router, gov, user, tokens, amount0Desired, amount1Desired, buy, qty
):
    # Simulate random deposit and random price move
    vault.deposit(amount0Desired, amount1Desired, 0, 0, user, {"from": user})
    vault.rebalance({"from": gov})
    router.swap(pool, buy, qty, {"from": user})

    # Ignore TWAP deviation
    vault.setMaxTwapDeviation(1 << 22, {"from": gov})

    # Poke Uniswap amounts owed to include fees
    shares = vault.balanceOf(user)
    vault.withdraw(shares // 2, 0, 0, user, {"from": user})

    # Store totals
    total0, total1 = vault.getTotalAmounts()

    vault.rebalance({"from": gov})

    # Check leftover balances is low
    assert tokens[0].balanceOf(vault) - vault.fees0() < 10000
    assert tokens[1].balanceOf(vault) - vault.fees1() < 10000

    # Check total amounts haven't changed
    newTotal0, newTotal1 = vault.getTotalAmounts()
    assert approx(total0, abs=1000) == newTotal0
    assert approx(total1, abs=1000) == newTotal1
    assert total0 - 2 <= newTotal0 <= total0
    assert total1 - 2 <= newTotal1 <= total1


@given(amount0Desired=strategy("uint256", min_value=1e8, max_value=1e18))
@given(amount1Desired=strategy("uint256", min_value=1e8, max_value=1e18))
@given(buy=strategy("bool"))
@given(qty=strategy("uint256", min_value=1e3, max_value=1e18))
@settings(max_examples=MAX_EXAMPLES)
def test_cannot_make_instant_profit_from_deposit_then_withdraw(
    vault, pool, router, gov, user, tokens, amount0Desired, amount1Desired, buy, qty
):

    # Set fee to 0 since this when an arb is most likely to work
    vault.setDepositFee(0, {"from": gov})
    vault.setStreamingFee(0, {"from": gov})

    # Simulate deposit and random price move
    vault.deposit(1e16, 1e18, 0, 0, user, {"from": user})
    vault.rebalance({"from": gov})
    router.swap(pool, buy, qty, {"from": user})

    # Deposit
    tx = vault.deposit(amount0Desired, amount1Desired, 0, 0, user, {"from": user})
    shares, amount0Deposit, amount1Deposit = tx.return_value

    # Withdraw all
    tx = vault.withdraw(shares, 0, 0, user, {"from": user})
    amount0Withdraw, amount1Withdraw = tx.return_value

    # Check did not make a profit
    assert amount0Deposit >= amount0Withdraw
    assert amount1Deposit >= amount1Withdraw

    # Check amounts are roughly equal
    assert approx(amount0Deposit, abs=100) == amount0Withdraw
    assert approx(amount1Deposit, abs=100) == amount1Withdraw


# TODO fix
# @given(amount0Desired=strategy("uint256", min_value=1e8, max_value=1e18))
# @given(amount1Desired=strategy("uint256", min_value=1e8, max_value=1e18))
# @given(buy=strategy("bool"))
# @given(buy2=strategy("bool"))
# @given(qty=strategy("uint256", min_value=1e3, max_value=1e18))
# @given(qty2=strategy("uint256", min_value=1e3, max_value=1e18))
# @settings(max_examples=MAX_EXAMPLES)
# def test_cannot_make_instant_profit_from_manipulated_deposit(
#     vault,
#     pool,
#     router,
#     gov,
#     user,
#     tokens,
#     amount0Desired,
#     amount1Desired,
#     buy,
#     qty,
#     buy2,
#     qty2,
# ):
#
#     # Set fee to 0 since this when an arb is most likely to work
#     vault.setDepositFee(0, {"from": gov})
#     vault.setStreamingFee(0, {"from": gov})
#
#     # Simulate deposit and random price move
#     vault.deposit(1e16, 1e18, 0, 0, user, {"from": user})
#     vault.rebalance({"from": gov})
#     router.swap(pool, buy, qty, {"from": user})
#
#     # Store initial balances
#     balance0 = tokens[0].balanceOf(user)
#     balance1 = tokens[1].balanceOf(user)
#
#     # Manipulate
#     router.swap(pool, buy2, qty2, {"from": user})
#
#     # Deposit
#     tx = vault.deposit(amount0Desired, amount1Desired, 0, 0, user, {"from": user})
#     shares, _, _ = tx.return_value
#
#     # Manipulate price back
#     router.swap(pool, not buy2, -qty2, {"from": user})
#
#     # Withdraw all
#     vault.withdraw(shares, 0, 0, user, {"from": user})
#     price = 1.0001 ** pool.slot0()[1]
#
#     balance0After = tokens[0].balanceOf(user)
#     balance1After = tokens[1].balanceOf(user)
#
#     # Check did not make a profit
#     value = balance0 * price + balance1
#     valueAfter = balance0After * price + balance1After
#     assert value >= valueAfter


@given(amount0Desired=strategy("uint256", min_value=1e8, max_value=1e18))
@given(amount1Desired=strategy("uint256", min_value=1e8, max_value=1e18))
@given(buy=strategy("bool"))
@given(buy2=strategy("bool"))
@given(qty=strategy("uint256", min_value=1e3, max_value=1e18))
@given(qty2=strategy("uint256", min_value=1e3, max_value=1e18))
@settings(max_examples=MAX_EXAMPLES)
def test_cannot_make_instant_profit_from_manipulated_withdraw(
    vault,
    pool,
    router,
    gov,
    user,
    tokens,
    amount0Desired,
    amount1Desired,
    buy,
    qty,
    buy2,
    qty2,
):

    # Set fee to 0 since this when an arb is most likely to work
    vault.setDepositFee(0, {"from": gov})
    vault.setStreamingFee(0, {"from": gov})

    # Simulate deposit and random price move
    vault.deposit(1e16, 1e18, 0, 0, user, {"from": user})
    vault.rebalance({"from": gov})
    router.swap(pool, buy, qty, {"from": user})

    # Store initial balances
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)

    # Deposit
    tx = vault.deposit(amount0Desired, amount1Desired, 0, 0, user, {"from": user})
    shares, _, _ = tx.return_value
    price = 1.0001 ** pool.slot0()[1]

    # Manipulate
    router.swap(pool, buy2, qty2, {"from": user})

    # Withdraw all
    vault.withdraw(shares, 0, 0, user, {"from": user})
    priceAfter = 1.0001 ** pool.slot0()[1]

    balance0After = tokens[0].balanceOf(user)
    balance1After = tokens[1].balanceOf(user)

    # Check did not make a profit
    value = balance0 * price + balance1
    valueAfter = balance0After * price + balance1After
    assert value >= valueAfter


@given(amount0Desired=strategy("uint256", min_value=1e8, max_value=1e18))
@given(amount1Desired=strategy("uint256", min_value=1e8, max_value=1e18))
@given(buy=strategy("bool"))
@given(buy2=strategy("bool"))
@given(qty=strategy("uint256", min_value=1e3, max_value=1e18))
@given(qty2=strategy("uint256", min_value=1e3, max_value=1e18))
@settings(max_examples=MAX_EXAMPLES)
def test_cannot_make_instant_profit_around_rebalance(
    vault,
    pool,
    router,
    gov,
    user,
    tokens,
    amount0Desired,
    amount1Desired,
    buy,
    qty,
    buy2,
    qty2,
):

    # Set fee to 0 since this when an arb is most likely to work
    vault.setDepositFee(0, {"from": gov})
    vault.setStreamingFee(0, {"from": gov})

    # Simulate deposit and random price move
    vault.deposit(1e16, 1e18, 0, 0, user, {"from": user})
    vault.rebalance({"from": gov})
    router.swap(pool, buy, qty, {"from": user})

    # Store totals before
    total0, total1 = vault.getTotalAmounts()

    # Deposit
    tx = vault.deposit(amount0Desired, amount1Desired, 0, 0, user, {"from": user})
    shares, amount0Deposit, amount1Deposit = tx.return_value

    # Rebalance
    vault.rebalance({"from": gov})

    # Withdraw all
    tx = vault.withdraw(shares, 0, 0, user, {"from": user})
    amount0Withdraw, amount1Withdraw = tx.return_value
    total0After, total1After = vault.getTotalAmounts()

    assert not (amount0Deposit < amount0Withdraw and amount1Deposit <= amount1Withdraw)
    assert not (amount0Deposit <= amount0Withdraw and amount1Deposit < amount1Withdraw)

    assert total0 <= total0After + 1
    assert total1 <= total1After + 1
