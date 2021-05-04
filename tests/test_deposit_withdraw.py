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

    # Mint
    tx = vault.deposit(shares, 1 << 255, 1 << 255, recipient, {"from": user})
    amount0, amount1 = tx.return_value

    # Check return values
    assert shares == vault.balanceOf(recipient) > 0
    assert amount0 == balance0 - tokens[0].balanceOf(user)
    assert amount1 == balance1 - tokens[1].balanceOf(user)

    # Check event
    assert tx.events["Deposit"] == {
        "sender": user,
        "to": recipient,
        "shares": shares,
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
    with reverts("maxAmount0"):
        vault.deposit(1e8, 0, 1 << 255, recipient, {"from": user})
    with reverts("maxAmount1"):
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
    base0, skew0 = getPositions(vault)

    # Mint
    tx = vault.deposit(shares, 1 << 255, 1 << 255, recipient, {"from": user})
    amount0, amount1 = tx.return_value

    # Check return values
    assert shares == vault.balanceOf(recipient) > 0
    assert amount0 == balance0 - tokens[0].balanceOf(user)
    assert amount1 == balance1 - tokens[1].balanceOf(user)

    # Check liquidity and balances are in proportion
    base1, skew1 = getPositions(vault)
    ratio = (totalSupply + shares) / totalSupply
    assert approx(base1[0] / base0[0]) == ratio
    assert approx(skew1[0] / skew0[0]) == ratio

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
    base0, skew0 = getPositions(vault)

    # Mint
    tx = vault.deposit(shares, 1 << 255, 1 << 255, recipient, {"from": user})
    amount0, amount1 = tx.return_value

    # Check return values
    assert shares == vault.balanceOf(recipient) > 0
    assert amount0 == balance0 - tokens[0].balanceOf(user) == 0
    assert amount1 == balance1 - tokens[1].balanceOf(user) > 0

    # Check liquidity and balances are in proportion
    base1, skew1 = getPositions(vault)
    ratio = (totalSupply + shares) / totalSupply
    assert base0[0] == base1[0] == 0
    assert approx(skew1[0] / skew0[0], rel=1e-5) == ratio


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
    base0, skew0 = getPositions(vault)

    # Mint
    tx = vault.deposit(shares, 1 << 255, 1 << 255, recipient, {"from": user})
    amount0, amount1 = tx.return_value

    # Check return values
    assert shares == vault.balanceOf(recipient) > 0
    assert amount0 == balance0 - tokens[0].balanceOf(user) > 0
    assert amount1 == balance1 - tokens[1].balanceOf(user) == 0

    # Check liquidity and balances are in proportion
    base1, skew1 = getPositions(vault)
    ratio = (totalSupply + shares) / totalSupply
    assert base0[0] == base1[0] == 0
    assert approx(skew1[0] / skew0[0], rel=1e-5) == ratio


def test_deposit_existing_checks(vaultAfterPriceMove, user, recipient):
    with reverts("shares"):
        vaultAfterPriceMove.deposit(0, 1 << 255, 1 << 255, recipient, {"from": user})
    with reverts("maxAmount0"):
        vaultAfterPriceMove.deposit(1e8, 0, 1 << 255, recipient, {"from": user})
    with reverts("maxAmount1"):
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

    # Mint and rebalance
    shares = 1e8
    tx = vault.deposit(shares, 1 << 255, 1 << 255, user, {"from": user})
    vault.rebalance({"from": gov})

    # Store balances, supply and positions
    balance0 = tokens[0].balanceOf(recipient)
    balance1 = tokens[1].balanceOf(recipient)
    totalSupply = vault.totalSupply()
    base0, skew0 = getPositions(vault)

    # Burn
    tx = vault.withdraw(shares, recipient, {"from": user})
    amount0, amount1 = tx.return_value
    assert vault.balanceOf(user) == 0

    # Check liquidity in pool
    base1, skew1 = getPositions(vault)
    assert approx((totalSupply - shares) / totalSupply) == base1[0] / base0[0]
    assert approx((totalSupply - shares) / totalSupply) == skew1[0] / skew0[0]

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


def test_cannot_withdraw_all(vault, gov):

    # Fast-forward 24 hours to avoid cooldown
    chain.sleep(24 * 60 * 60)

    # Mint
    shares = 1e8
    tx = vault.deposit(shares, 1 << 255, 1 << 255, gov, {"from": gov})

    # Burn all
    with reverts("MIN_TOTAL_SUPPLY"):
        vault.withdraw(shares, gov, {"from": gov})
