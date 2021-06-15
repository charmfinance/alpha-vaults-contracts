from brownie.test import given, strategy
from hypothesis import settings
from pytest import approx


MAX_EXAMPLES = 5  # faster
# MAX_EXAMPLES = 50


def getPrice(pool):
    sqrtPrice = pool.slot0()[0] / (1 << 96)
    return sqrtPrice ** 2


@given(
    amount0Desired=strategy("uint256", min_value=0, max_value=1e18),
    amount1Desired=strategy("uint256", min_value=0, max_value=1e18),
    buy=strategy("bool"),
    qty=strategy("uint256", min_value=1e3, max_value=1e18),
)
@settings(max_examples=MAX_EXAMPLES)
def test_deposit_invariants(
    vault,
    strategy,
    pool,
    router,
    gov,
    user,
    keeper,
    tokens,
    amount0Desired,
    amount1Desired,
    buy,
    qty,
):
    # Set fee to 0 since this when an arb is most likely to work
    vault.setProtocolFee(0, {"from": gov})

    # Simulate deposit and random price move
    vault.deposit(1e16, 1e18, 0, 0, user, {"from": user})
    strategy.rebalance({"from": keeper})
    router.swap(pool, buy, qty, {"from": user})

    # Poke Uniswap amounts owed to include fees
    shares = vault.balanceOf(user)
    vault.withdraw(shares // 2, 0, 0, user, {"from": user})

    # Store totals
    total0, total1 = vault.getTotalAmounts()
    totalSupply = vault.totalSupply()

    # Ignore when output shares is 0:
    if amount1Desired < 2 and total1 > 0:
        return
    if amount0Desired < 2 and total0 > 0:
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
    if amount0 > 1e6 and amount1 > 1e6:
        assert approx(amount1 * total0) == amount0 * total1
        assert approx(amount0 * totalSupply) == shares * total0
        assert approx(amount1 * totalSupply) == shares * total1

    # Check doesn't under-pay
    assert amount0 * totalSupply >= shares * total0
    assert amount1 * totalSupply >= shares * total1


@given(
    amount0Desired=strategy("uint256", min_value=1e8, max_value=1e18),
    amount1Desired=strategy("uint256", min_value=1e8, max_value=1e18),
    buy=strategy("bool"),
    qty=strategy("uint256", min_value=1e3, max_value=1e18),
)
@settings(max_examples=MAX_EXAMPLES)
def test_rebalance_invariants(
    vault,
    strategy,
    pool,
    router,
    gov,
    user,
    keeper,
    tokens,
    amount0Desired,
    amount1Desired,
    buy,
    qty,
):
    # Set fee to 0 since this when an arb is most likely to work
    vault.setProtocolFee(0, {"from": gov})

    # Simulate random deposit and random price move
    vault.deposit(amount0Desired, amount1Desired, 0, 0, user, {"from": user})
    strategy.rebalance({"from": keeper})
    router.swap(pool, buy, qty, {"from": user})

    # Ignore TWAP deviation
    strategy.setMaxTwapDeviation(1 << 22, {"from": gov})

    # Poke Uniswap amounts owed to include fees
    shares = vault.balanceOf(user)
    vault.withdraw(shares // 2, 0, 0, user, {"from": user})

    # Store totals
    total0, total1 = vault.getTotalAmounts()

    strategy.rebalance({"from": keeper})

    # Check leftover balances is low
    assert tokens[0].balanceOf(vault) - vault.accruedProtocolFees0() < 10000
    assert tokens[1].balanceOf(vault) - vault.accruedProtocolFees1() < 10000

    # Check total amounts haven't changed
    newTotal0, newTotal1 = vault.getTotalAmounts()
    assert approx(total0, abs=1000) == newTotal0
    assert approx(total1, abs=1000) == newTotal1
    assert total0 - 2 <= newTotal0 <= total0
    assert total1 - 2 <= newTotal1 <= total1


@given(
    amount0Desired=strategy("uint256", min_value=1e8, max_value=1e18),
    amount1Desired=strategy("uint256", min_value=1e8, max_value=1e18),
    buy=strategy("bool"),
    qty=strategy("uint256", min_value=1e3, max_value=1e18),
)
@settings(max_examples=MAX_EXAMPLES)
def test_cannot_make_instant_profit_from_deposit_then_withdraw(
    vault,
    strategy,
    pool,
    router,
    gov,
    user,
    keeper,
    tokens,
    amount0Desired,
    amount1Desired,
    buy,
    qty,
):
    # Set fee to 0 since this when an arb is most likely to work
    vault.setProtocolFee(0, {"from": gov})

    # Simulate deposit and random price move
    vault.deposit(1e16, 1e18, 0, 0, user, {"from": user})
    strategy.rebalance({"from": keeper})
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
    assert approx(amount0Deposit, abs=1000) == amount0Withdraw
    assert approx(amount1Deposit, abs=1000) == amount1Withdraw


@given(
    amount0Desired=strategy("uint256", min_value=1e8, max_value=1e18),
    amount1Desired=strategy("uint256", min_value=1e8, max_value=1e18),
    buy=strategy("bool"),
    buy2=strategy("bool"),
    qty=strategy("uint256", min_value=1e3, max_value=1e18),
    qty2=strategy("uint256", min_value=1e3, max_value=1e18),
    manipulateBack=strategy("bool"),
)
@settings(max_examples=MAX_EXAMPLES)
def test_cannot_make_instant_profit_from_manipulated_deposit(
    vault,
    strategy,
    pool,
    router,
    gov,
    user,
    keeper,
    tokens,
    amount0Desired,
    amount1Desired,
    buy,
    qty,
    buy2,
    qty2,
    manipulateBack,
):

    # Set fee to 0 since this when an arb is most likely to work
    vault.setProtocolFee(0, {"from": gov})

    # Simulate deposit and random price move
    vault.deposit(1e16, 1e18, 0, 0, user, {"from": user})
    strategy.rebalance({"from": keeper})
    router.swap(pool, buy, qty, {"from": user})

    # Store balances and totals before
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)
    total0, total1 = vault.getTotalAmounts()
    price = getPrice(pool)

    # Manipulate
    router.swap(pool, buy2, qty2, {"from": user})

    # Deposit
    tx = vault.deposit(amount0Desired, amount1Desired, 0, 0, user, {"from": user})
    shares, _, _ = tx.return_value

    # Manipulate price back
    if manipulateBack:
        router.swap(pool, not buy2, -qty2 * 0.997, {"from": user})

    # Withdraw all
    vault.withdraw(shares, 0, 0, user, {"from": user})

    # Store balances and totals after
    balance0After = tokens[0].balanceOf(user)
    balance1After = tokens[1].balanceOf(user)
    total0After, total1After = vault.getTotalAmounts()

    # Check attacker did not make a profit
    dbalance0 = balance0After - balance0
    dbalance1 = balance1After - balance1
    assert dbalance0 * price + dbalance1 <= 0

    # Check vault can't be griefed
    dtotal0 = total0After - total0
    dtotal1 = total1After - total1
    assert dtotal0 * price + dtotal1 >= 0


@given(
    amount0Desired=strategy("uint256", min_value=1e8, max_value=1e18),
    amount1Desired=strategy("uint256", min_value=1e8, max_value=1e18),
    buy=strategy("bool"),
    buy2=strategy("bool"),
    qty=strategy("uint256", min_value=1e3, max_value=1e18),
    qty2=strategy("uint256", min_value=1e3, max_value=1e18),
    manipulateBack=strategy("bool"),
)
@settings(max_examples=MAX_EXAMPLES)
def test_cannot_make_instant_profit_from_manipulated_withdraw(
    vault,
    strategy,
    pool,
    router,
    gov,
    user,
    keeper,
    tokens,
    amount0Desired,
    amount1Desired,
    buy,
    qty,
    buy2,
    qty2,
    manipulateBack,
):
    # Set fee to 0 since this when an arb is most likely to work
    vault.setProtocolFee(0, {"from": gov})

    # Simulate deposit and random price move
    vault.deposit(1e16, 1e18, 0, 0, user, {"from": user})
    strategy.rebalance({"from": keeper})
    router.swap(pool, buy, qty, {"from": user})

    # Store initial balances
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)
    total0, total1 = vault.getTotalAmounts()
    price = getPrice(pool)

    # Deposit
    tx = vault.deposit(amount0Desired, amount1Desired, 0, 0, user, {"from": user})
    shares, _, _ = tx.return_value

    # Manipulate
    router.swap(pool, buy2, qty2, {"from": user})

    # Withdraw all
    vault.withdraw(shares, 0, 0, user, {"from": user})

    # Manipulate back
    if manipulateBack:
        router.swap(pool, not buy2, -qty2, {"from": user})

    balance0After = tokens[0].balanceOf(user)
    balance1After = tokens[1].balanceOf(user)
    total0After, total1After = vault.getTotalAmounts()

    # Check attacker did not make a profit
    dbalance0 = balance0After - balance0
    dbalance1 = balance1After - balance1
    assert dbalance0 * price + dbalance1 <= 0

    # Check vault can't be griefed
    dtotal0 = total0After - total0
    dtotal1 = total1After - total1
    assert dtotal0 * price + dtotal1 >= 0


@given(
    amount0Desired=strategy("uint256", min_value=1e8, max_value=1e18),
    amount1Desired=strategy("uint256", min_value=1e8, max_value=1e18),
    buy=strategy("bool"),
    buy2=strategy("bool"),
    qty=strategy("uint256", min_value=1e3, max_value=1e18),
    qty2=strategy("uint256", min_value=1e3, max_value=1e18),
)
@settings(max_examples=MAX_EXAMPLES)
def test_cannot_make_instant_profit_around_rebalance(
    vault,
    strategy,
    pool,
    router,
    gov,
    user,
    keeper,
    tokens,
    amount0Desired,
    amount1Desired,
    buy,
    qty,
    buy2,
    qty2,
):
    # Set fee to 0 since this when an arb is most likely to work
    vault.setProtocolFee(0, {"from": gov})

    # Simulate deposit and random price move
    vault.deposit(1e16, 1e18, 0, 0, user, {"from": user})
    strategy.rebalance({"from": keeper})
    router.swap(pool, buy, qty, {"from": user})

    # Poke Uniswap amounts owed to include fees
    shares = vault.balanceOf(user)
    vault.withdraw(shares // 2, 0, 0, user, {"from": user})

    # Store totals before
    total0, total1 = vault.getTotalAmounts()

    # Deposit
    tx = vault.deposit(amount0Desired, amount1Desired, 0, 0, user, {"from": user})
    shares, amount0Deposit, amount1Deposit = tx.return_value

    # Rebalance
    strategy.rebalance({"from": keeper})

    # Withdraw all
    tx = vault.withdraw(shares, 0, 0, user, {"from": user})
    amount0Withdraw, amount1Withdraw = tx.return_value
    total0After, total1After = vault.getTotalAmounts()

    assert not (amount0Deposit < amount0Withdraw and amount1Deposit <= amount1Withdraw)
    assert not (amount0Deposit <= amount0Withdraw and amount1Deposit < amount1Withdraw)

    assert total0 <= total0After + 2
    assert total1 <= total1After + 2
    assert approx(total0) == total0After
    assert approx(total1) == total1After
