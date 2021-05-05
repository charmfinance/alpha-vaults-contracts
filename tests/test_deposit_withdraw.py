from brownie import chain, reverts, ZERO_ADDRESS
import pytest
from pytest import approx


@pytest.mark.parametrize(
    "shares",
    [1e4, 1e18],
)
def test_deposit_initial(
    vault,
    pool,
    tokens,
    gov,
    user,
    recipient,
    shares,
):

    # Store balances
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)

    # Deposit
    tx = vault.deposit(shares, 1 << 255, 1 << 255, recipient, {"from": user})
    amount0, amount1 = tx.return_value

    # Check return values
    assert approx(shares - 1000) == vault.balanceOf(recipient) > 0
    assert amount0 == balance0 - tokens[0].balanceOf(user)
    assert amount1 == balance1 - tokens[1].balanceOf(user)

    # Check event
    assert tx.events["Deposit"] == {
        "sender": user,
        "to": recipient,
        "shares": shares - 1000,
        "amount0": amount0,
        "amount1": amount1,
    }


def test_deposit_initial_checks(vault, user, recipient):
    with reverts("shares"):
        vault.deposit(0, 1e8, 1e8, recipient, {"from": user})
    with reverts("MIN_TOTAL_SUPPLY"):
        vault.deposit(1, 1e8, 1e8, recipient, {"from": user})
    with reverts("to"):
        vault.deposit(1e8, 1 << 255, 1 << 255, ZERO_ADDRESS, {"from": user})
    with reverts("amount0Max"):
        vault.deposit(1e8, 0, 1 << 255, recipient, {"from": user})
    with reverts("amount1Max"):
        vault.deposit(1e8, 1 << 255, 0, recipient, {"from": user})


@pytest.mark.parametrize(
    "shares",
    [1e4, 1e18],
)
def test_deposit_existing(
    vaultAfterPriceMove,
    pool,
    tokens,
    getPositions,
    router,
    gov,
    user,
    recipient,
    shares,
):
    vault = vaultAfterPriceMove

    # Store balances, supply and positions
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)
    totalSupply = vault.totalSupply()
    base0, limit0 = getPositions(vault)

    # Deposit
    tx = vault.deposit(shares, 1 << 255, 1 << 255, recipient, {"from": user})
    amount0, amount1 = tx.return_value

    # Check return values
    assert shares == vault.balanceOf(recipient) > 0
    assert amount0 == balance0 - tokens[0].balanceOf(user)
    assert amount1 == balance1 - tokens[1].balanceOf(user)

    # Check liquidity and balances are in proportion
    base1, limit1 = getPositions(vault)
    ratio = (totalSupply + shares) / totalSupply
    assert approx(base1[0] / base0[0]) == ratio
    assert approx(limit1[0] / limit0[0]) == ratio

    # Check event
    assert tx.events["Deposit"] == {
        "sender": user,
        "to": recipient,
        "shares": shares,
        "amount0": amount0,
        "amount1": amount1,
    }


@pytest.mark.parametrize(
    "shares",
    [1e4, 1e18],
)
def test_deposit_existing_when_price_up(
    vaultAfterPriceUp,
    pool,
    tokens,
    getPositions,
    router,
    gov,
    user,
    recipient,
    shares,
):
    vault = vaultAfterPriceUp

    # Store balances, supply and positions
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)
    totalSupply = vault.totalSupply()
    base0, limit0 = getPositions(vault)

    # Deposit
    tx = vault.deposit(shares, 1 << 255, 1 << 255, recipient, {"from": user})
    amount0, amount1 = tx.return_value

    # Check return values
    assert shares == vault.balanceOf(recipient) > 0
    assert amount0 == balance0 - tokens[0].balanceOf(user) == 0
    assert amount1 == balance1 - tokens[1].balanceOf(user) > 0

    # Check liquidity and balances are in proportion
    base1, limit1 = getPositions(vault)
    ratio = (totalSupply + shares) / totalSupply
    assert base0[0] == base1[0] == 0
    assert approx(limit1[0] / limit0[0], rel=1e-5) == ratio


@pytest.mark.parametrize(
    "shares",
    [1e4, 1e18],
)
def test_deposit_existing_when_price_down(
    vaultAfterPriceDown,
    pool,
    tokens,
    getPositions,
    router,
    gov,
    user,
    recipient,
    shares,
):
    vault = vaultAfterPriceDown

    # Store balances, supply and positions
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)
    totalSupply = vault.totalSupply()
    base0, limit0 = getPositions(vault)

    # Deposit
    tx = vault.deposit(shares, 1 << 255, 1 << 255, recipient, {"from": user})
    amount0, amount1 = tx.return_value

    # Check return values
    assert shares == vault.balanceOf(recipient) > 0
    assert amount0 == balance0 - tokens[0].balanceOf(user) > 0
    assert amount1 == balance1 - tokens[1].balanceOf(user) == 0

    # Check liquidity and balances are in proportion
    base1, limit1 = getPositions(vault)
    ratio = (totalSupply + shares) / totalSupply
    assert base0[0] == base1[0] == 0
    assert approx(limit1[0] / limit0[0], rel=1e-5) == ratio


@pytest.mark.parametrize(
    "shares",
    [1e12, 1e18, 1e19],
)
def test_unused_deposit(vault, gov, user, recipient, tokens, shares):

    # Initial deposit
    vault.deposit(1e18, 1 << 255, 1 << 255, recipient, {"from": user})

    # Deposit and withdraw and record expected amounts
    tx = vault.deposit(shares, 1 << 255, 1 << 255, user, {"from": user})
    vault.withdraw(shares, 0, 0, user, {"from": user})
    exp0, exp1 = tx.return_value

    # Store balances
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)

    # Give vault excess tokens
    tokens[0].transfer(vault, 1e8, {"from": gov})
    tokens[1].transfer(vault, 1e10, {"from": gov})

    # Deposit
    tx = vault.deposit(shares, 1 << 255, 1 << 255, recipient, {"from": user})
    amount0, amount1 = tx.return_value

    # Check unused amounts were also deposited
    assert approx(amount0) == exp0 + 1e8 * shares / 1e18
    assert approx(amount1) == exp1 + 1e10 * shares / 1e18

    # Check balances match amounts
    assert amount0 == balance0 - tokens[0].balanceOf(user) > 0
    assert amount1 == balance1 - tokens[1].balanceOf(user) > 0


def test_deposit_existing_checks(vaultAfterPriceMove, user, recipient):
    with reverts("shares"):
        vaultAfterPriceMove.deposit(0, 1 << 255, 1 << 255, recipient, {"from": user})
    with reverts("amount0Max"):
        vaultAfterPriceMove.deposit(1e8, 0, 1 << 255, recipient, {"from": user})
    with reverts("amount1Max"):
        vaultAfterPriceMove.deposit(1e8, 1 << 255, 0, recipient, {"from": user})
    with reverts("to"):
        vaultAfterPriceMove.deposit(
            1e8, 1 << 255, 1 << 255, ZERO_ADDRESS, {"from": user}
        )


def test_withdraw(
    vaultAfterPriceMove, pool, tokens, router, getPositions, gov, user, recipient
):
    vault = vaultAfterPriceMove

    # Fast-forward 24 hours to avoid cooldown
    chain.sleep(24 * 60 * 60)

    # Deposit and rebalance
    shares = 1e8
    tx = vault.deposit(shares, 1 << 255, 1 << 255, user, {"from": user})
    vault.rebalance({"from": gov})

    # Store balances, supply and positions
    balance0 = tokens[0].balanceOf(recipient)
    balance1 = tokens[1].balanceOf(recipient)
    totalSupply = vault.totalSupply()
    base0, limit0 = getPositions(vault)

    # Withdraw
    tx = vault.withdraw(shares, 0, 0, recipient, {"from": user})
    amount0, amount1 = tx.return_value
    assert vault.balanceOf(user) == 0

    # Check liquidity in pool
    base1, limit1 = getPositions(vault)
    assert approx((totalSupply - shares) / totalSupply) == base1[0] / base0[0]
    assert approx((totalSupply - shares) / totalSupply) == limit1[0] / limit0[0]

    # Check recipient has received tokens
    assert tokens[0].balanceOf(recipient) - balance0 == amount0 > 0
    assert tokens[1].balanceOf(recipient) - balance1 == amount1 > 0

    # Check event
    assert tx.events["Withdraw"] == {
        "sender": user,
        "to": recipient,
        "shares": shares,
        "amount0": amount0,
        "amount1": amount1,
    }


@pytest.mark.parametrize(
    "shares",
    [1e6, 1e12, 1e17],
)
def test_unused_withdraw(vault, gov, user, recipient, tokens, shares):

    # Initial deposit
    vault.deposit(1e18, 1 << 255, 1 << 255, user, {"from": user})

    # Deposit and withdraw and record expected amounts
    vault.deposit(shares, 1 << 255, 1 << 255, user, {"from": user})
    tx = vault.withdraw(shares, 0, 0, user, {"from": user})
    exp0, exp1 = tx.return_value

    # Store balances, supply and positions
    balance0 = tokens[0].balanceOf(recipient)
    balance1 = tokens[1].balanceOf(recipient)

    # Vault somehow has excess unused tokens
    tokens[0].transfer(vault, 1e8, {"from": gov})
    tokens[1].transfer(vault, 1e10, {"from": gov})

    # Withdraw
    tx = vault.withdraw(shares, 0, 0, recipient, {"from": user})
    amount0, amount1 = tx.return_value

    # Check half of unused tokens were also withdrawn
    assert approx(amount0) == exp0 + 1e8 * shares / 1e18
    assert approx(amount1) == exp1 + 1e10 * shares / 1e18

    # Check balances match amounts
    assert amount0 == tokens[0].balanceOf(recipient) - balance0 > 0
    assert amount1 == tokens[1].balanceOf(recipient) - balance1 > 0


def test_withdraw_checks(vault, user, recipient):
    shares = 1e8
    vault.deposit(shares, 1 << 255, 1 << 255, user, {"from": user})

    with reverts("shares"):
        vault.withdraw(0, 0, 0, recipient, {"from": user})
    with reverts("to"):
        vault.withdraw(shares - 1000, 0, 0, ZERO_ADDRESS, {"from": user})
    with reverts("amount0Min"):
        vault.withdraw(shares - 1000, 1e18, 0, recipient, {"from": user})
    with reverts("amount1Min"):
        vault.withdraw(shares - 1000, 0, 1e18, recipient, {"from": user})
