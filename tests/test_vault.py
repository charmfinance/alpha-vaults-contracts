from brownie import chain, reverts, ZERO_ADDRESS
import pytest
from pytest import approx


def test_constructor(PassiveRebalanceVault, pool, gov):
    vault = gov.deploy(
        PassiveRebalanceVault, pool, 2400, 1200, 500, 600, 12 * 60 * 60, 100e18
    )
    assert vault.pool() == pool
    assert vault.token0() == pool.token0()
    assert vault.token1() == pool.token1()
    assert vault.fee() == pool.fee()
    assert vault.tickSpacing() == pool.tickSpacing()

    assert vault.baseThreshold() == 2400
    assert vault.skewThreshold() == 1200
    assert vault.maxTwapDeviation() == 500
    assert vault.twapDuration() == 600
    assert vault.rebalanceCooldown() == 12 * 60 * 60
    assert vault.maxTotalSupply() == 100e18
    assert vault.governance() == gov

    tick = pool.slot0()[1] // 60 * 60
    assert vault.baseLower() == tick - 2400
    assert vault.baseUpper() == tick + 2460
    assert vault.skewLower() == tick + 60
    assert vault.skewUpper() == tick + 60 + 1200

    assert vault.name() == "PassiveRebalanceVault"
    assert vault.symbol() == "PR"
    assert vault.decimals() == 18


def test_constructor_checks(PassiveRebalanceVault, pool, gov):
    with reverts("baseThreshold"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2401, 1200, 500, 600, 23 * 60 * 60, 100e18
        )

    with reverts("skewThreshold"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1201, 500, 600, 23 * 60 * 60, 100e18
        )

    with reverts("baseThreshold"):
        gov.deploy(PassiveRebalanceVault, pool, 0, 1200, 500, 600, 23 * 60 * 60, 100e18)

    with reverts("skewThreshold"):
        gov.deploy(PassiveRebalanceVault, pool, 2400, 0, 500, 600, 23 * 60 * 60, 100e18)

    # check works with small thresholds
    gov.deploy(PassiveRebalanceVault, pool, 60, 1200, 500, 600, 23 * 60 * 60, 100e18)
    gov.deploy(PassiveRebalanceVault, pool, 2400, 60, 500, 600, 23 * 60 * 60, 100e18)

    with reverts("maxTwapDeviation"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1200, -1, 600, 23 * 60 * 60, 100e18
        )


@pytest.mark.parametrize(
    "maxAmount0,maxAmount1", [[1e3, 1e10], [1e7, 1e10], [1e9, 1e10], [1e10, 1e3]]
)
def test_mint_initial(
    vault, pool, tokens, gov, user, recipient, maxAmount0, maxAmount1
):

    # Store balances
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)

    # Mint
    tx = vault.deposit(maxAmount0, maxAmount1, recipient, {"from": user})
    shares, amount0, amount1 = tx.return_value

    # Check return values
    assert shares == vault.balanceOf(recipient) > 0
    assert amount0 == balance0 - tokens[0].balanceOf(user)
    assert amount1 == balance1 - tokens[1].balanceOf(user)

    # Check spent right amount
    zeroTight = amount0 / maxAmount0 > amount1 / maxAmount1
    if zeroTight:
        assert amount0 == maxAmount0
        assert amount1 < maxAmount1
    else:
        assert amount0 < maxAmount0
        assert amount1 == maxAmount1

    # Check event
    assert tx.events["Deposit"] == {
        "sender": user,
        "to": recipient,
        "shares": shares,
        "amount0": amount0,
        "amount1": amount1,
    }


def test_mint_initial_checks(vault, user, recipient):
    with reverts("shares"):
        vault.deposit(0, 1e8, recipient, {"from": user})
    with reverts("shares"):
        vault.deposit(1e8, 0, recipient, {"from": user})
    with reverts("to"):
        vault.deposit(1e8, 1e8, ZERO_ADDRESS, {"from": user})


@pytest.mark.parametrize(
    "maxAmount0,maxAmount1", [[1e3, 1e10], [1e7, 1e10], [1e9, 1e10], [1e10, 1e3]]
)
def test_mint_existing(
    vaultAfterPriceMove,
    pool,
    tokens,
    getPositions,
    router,
    gov,
    user,
    recipient,
    maxAmount0,
    maxAmount1,
):
    vault = vaultAfterPriceMove

    # Store balances, supply and positions
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)
    totalSupply = vault.totalSupply()
    base0, skew0 = getPositions(vault)

    # Mint
    tx = vault.deposit(maxAmount0, maxAmount1, recipient, {"from": user})
    shares, amount0, amount1 = tx.return_value

    # Check return values
    assert shares == vault.balanceOf(recipient) > 0
    assert amount0 == balance0 - tokens[0].balanceOf(user)
    assert amount1 == balance1 - tokens[1].balanceOf(user)

    # Check spent right amount
    zeroTight = amount0 / maxAmount0 > amount1 / maxAmount1
    if zeroTight:
        # Max amount 0 is the tight constraint
        assert approx(amount0, abs=3) == maxAmount0
    else:
        # Max amount 1 is the tight constraint
        assert approx(amount1, abs=3) == maxAmount1

    # Check amounts are less than max
    assert amount0 <= maxAmount0
    assert amount1 <= maxAmount1

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
    "maxAmount0,maxAmount1",
    [[1e3, 1e10], [1e7, 1e10], [1e9, 1e10], [0, 1e10], [1, 1e10], [2, 1e10]],
)
def test_mint_existing_when_price_up(
    vaultAfterPriceUp,
    pool,
    tokens,
    getPositions,
    router,
    gov,
    user,
    recipient,
    maxAmount0,
    maxAmount1,
):
    vault = vaultAfterPriceUp

    # Store balances, supply and positions
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)
    totalSupply = vault.totalSupply()
    base0, skew0 = getPositions(vault)

    # Mint
    tx = vault.deposit(maxAmount0, maxAmount1, recipient, {"from": user})
    shares, amount0, amount1 = tx.return_value

    # Check return values
    assert shares == vault.balanceOf(recipient) > 0
    assert amount0 == balance0 - tokens[0].balanceOf(user)
    assert amount1 == balance1 - tokens[1].balanceOf(user)

    # Check spent right amount
    assert approx(amount1, rel=1e-5, abs=10) == maxAmount1
    assert amount0 < 10
    assert amount1 <= maxAmount1

    # Check liquidity and balances are in proportion
    base1, skew1 = getPositions(vault)
    ratio = (totalSupply + shares) / totalSupply
    assert base0[0] == base1[0] == 0
    assert approx(skew1[0] / skew0[0], rel=1e-5) == ratio


@pytest.mark.parametrize(
    "maxAmount0,maxAmount1",
    [[1e3, 1e10], [1e7, 1e10], [1e9, 1e10], [1e10, 1e3], [1e8, 0], [1e8, 1], [1e8, 2]],
)
def test_mint_existing_when_price_down(
    vaultAfterPriceDown,
    pool,
    tokens,
    getPositions,
    router,
    gov,
    user,
    recipient,
    maxAmount0,
    maxAmount1,
):
    vault = vaultAfterPriceDown

    # Store balances, supply and positions
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)
    totalSupply = vault.totalSupply()
    base0, skew0 = getPositions(vault)

    # Mint
    tx = vault.deposit(maxAmount0, maxAmount1, recipient, {"from": user})
    shares, amount0, amount1 = tx.return_value

    # Check return values
    assert shares == vault.balanceOf(recipient) > 0
    assert amount0 == balance0 - tokens[0].balanceOf(user)
    assert amount1 == balance1 - tokens[1].balanceOf(user)

    # Check spent right amount
    assert approx(amount0, abs=10) == maxAmount0
    assert amount0 <= maxAmount0
    assert amount1 == 0

    # Check liquidity and balances are in proportion
    base1, skew1 = getPositions(vault)
    ratio = (totalSupply + shares) / totalSupply
    assert base0[0] == base1[0] == 0
    assert approx(skew1[0] / skew0[0], rel=1e-5) == ratio


def test_mint_existing_checks(vaultAfterPriceMove, user, recipient):
    with reverts("shares"):
        vaultAfterPriceMove.deposit(0, 1e8, recipient, {"from": user})
    with reverts("shares"):
        vaultAfterPriceMove.deposit(1e8, 0, recipient, {"from": user})
    with reverts("to"):
        vaultAfterPriceMove.deposit(1e8, 1e8, ZERO_ADDRESS, {"from": user})


def test_mint_existing_checks_when_price_up(vaultAfterPriceUp, user, recipient):
    with reverts("shares"):
        vaultAfterPriceUp.deposit(1e8, 0, recipient, {"from": user})
    vaultAfterPriceUp.deposit(0, 1e8, recipient, {"from": user})


def test_mint_existing_checks_when_price_down(vaultAfterPriceDown, user, recipient):
    with reverts("shares"):
        vaultAfterPriceDown.deposit(0, 1e8, recipient, {"from": user})
    vaultAfterPriceDown.deposit(1e8, 0, recipient, {"from": user})


def test_burn(
    vaultAfterPriceMove, pool, tokens, router, getPositions, gov, user, recipient
):
    vault = vaultAfterPriceMove

    # Fast-forward 24 hours to avoid cooldown
    chain.sleep(24 * 60 * 60)

    # Mint and rebalance
    tx = vault.deposit(1e6, 1e8, user, {"from": user})
    shares, _, _ = tx.return_value
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


def test_rebalance_when_empty_then_mint(
    vault, pool, tokens, getPositions, gov, user, recipient
):

    # Fast-forward 24 hours to avoid cooldown
    chain.sleep(24 * 60 * 60)

    # Rebalance
    vault.rebalance({"from": gov})

    vault.deposit(1e6, 1e8, user, {"from": user})

    # Check liquidity in pool
    base, rebalance = getPositions(vault)
    assert base[0] > 0
    assert rebalance[0] == 0


def test_burn_all(vault, pool, tokens, getPositions, gov, user, recipient):

    # Fast-forward 24 hours to avoid cooldown
    chain.sleep(24 * 60 * 60)

    # Mint
    tx = vault.deposit(1e17, 1e19, gov, {"from": gov})
    shares, _, _ = tx.return_value

    # Rebalance
    vault.rebalance({"from": gov})

    # Burn all
    vault.withdraw(shares, gov, {"from": gov})

    # Check vault is empty
    assert vault.totalSupply() == 0
    assert tokens[0].balanceOf(vault) == 0
    assert tokens[1].balanceOf(vault) == 0

    base, rebalance = getPositions(vault)
    assert base[0] == 0
    assert rebalance[0] == 0


def test_balances_when_empty():
    1


@pytest.mark.parametrize("buy", [False, True])
@pytest.mark.parametrize("big", [False, True])
def test_rebalance(vault, pool, tokens, router, getPositions, gov, user, buy, big):

    # Mint some liquidity
    vault.deposit(1e17, 1e19, gov, {"from": gov})

    # Do a swap to move the price
    qty = 1e16 * [100, 1][buy] * [1, 100][big]
    router.swap(pool, buy, qty, {"from": gov})

    # Rebalance
    tx = vault.rebalance({"from": gov})

    # Check ranges are set correctly
    tick = pool.slot0()[1]
    tickFloor = tick // 60 * 60
    assert vault.baseLower() == tickFloor - 2400
    assert vault.baseUpper() == tickFloor + 60 + 2400
    if buy:
        assert vault.skewLower() == tickFloor + 60
        assert vault.skewUpper() == tickFloor + 60 + 1200
    else:
        assert vault.skewLower() == tickFloor - 1200
        assert vault.skewUpper() == tickFloor

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


# TODO: FIX THIS TEST
# @pytest.mark.parametrize("buy", [False, True])
# def test_rebalance_when_price_limit(vault, pool, tokens, router, getPositions, gov, user, buy):
#
#     # Mint some liquidity
#     vault.deposit(1e17, 1e19, gov, {"from": gov})
#
#     # Do a huge swap to move the price to min or max tick
#     qty = 1 << 127
#     tokens[0].mint(gov, qty)
#     tokens[1].mint(gov, qty)
#     router.swap(pool, buy, qty, {"from": gov})
#
#     # Rebalance
#     tx = vault.rebalance({"from": gov})
#
#     # Check ranges are set correctly
#     tick = pool.slot0()[1]
#     tickFloor = tick // 60 * 60
#     assert vault.baseRange() == (tickFloor - 2400, tickFloor + 60 + 2400)
#     if buy:
#         assert vault.skewRange() == (tickFloor + 60, tickFloor + 60 + 1200)
#     else:
#         assert vault.skewRange() == (tickFloor - 1200, tickFloor)


@pytest.mark.parametrize("buy", [False, True])
def test_rebalance_twap_check(
    vault, pool, tokens, router, getPositions, gov, user, buy
):

    # Reduce max deviation
    vault.setMaxTwapDeviation(500, {"from": gov})

    # Mint some liquidity
    vault.deposit(1e17, 1e19, gov, {"from": gov})

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


@pytest.mark.parametrize(
    "maxAmount0,maxAmount1",
    [[1e3, 1e10], [1e7, 1e10], [1e9, 1e10], [1e10, 1e3]],
)
def test_values(vaultAfterPriceMove, tokens, user, recipient, maxAmount0, maxAmount1):
    vault = vaultAfterPriceMove

    # Store balances and values
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)
    total0, total1 = vault.getTotalAmounts()

    # Mint some liquidity
    tx = vault.deposit(maxAmount0, maxAmount1, recipient, {"from": user})
    _, amount0, amount1 = tx.return_value

    # Check amounts match values
    assert approx(amount0, abs=1) == vault.getTotalAmounts()[0] - total0
    assert approx(amount1, abs=1) == vault.getTotalAmounts()[1] - total1


@pytest.mark.parametrize(
    "maxAmount0,maxAmount1",
    [
        [1e3, 1e10],
        [1e7, 1e10],
        [1e9, 1e10],
        [1e10, 1e3],
        [3, 1e10],
        [1e10, 10],
        [3, 10],
    ],
)
def test_values_per_share_do_not_increase(
    vaultAfterPriceMove, tokens, user, recipient, maxAmount0, maxAmount1
):
    vault = vaultAfterPriceMove

    # Store balances and values
    total0, total1 = vault.getTotalAmounts()
    supply = vault.totalSupply()
    valuePerShare0 = total0 / supply
    valuePerShare1 = total1 / supply

    # Mint some liquidity
    vault.deposit(maxAmount0, maxAmount1, recipient, {"from": user})

    # Check amounts match values
    total0, total1 = vault.getTotalAmounts()
    supply = vault.totalSupply()
    newValuePerShare0 = total0 / supply
    newValuePerShare1 = total1 / supply
    assert newValuePerShare0 <= valuePerShare0
    assert newValuePerShare1 <= valuePerShare1
    assert approx(newValuePerShare0, abs=1) == valuePerShare0
    assert approx(newValuePerShare1, abs=1) == valuePerShare1


@pytest.mark.parametrize("buy", [False, True])
@pytest.mark.parametrize("big", [False, True])
def test_values_do_not_change_after_rebalance(
    vault, pool, tokens, router, getPositions, gov, user, buy, big
):

    # Mint some liquidity
    vault.deposit(1e17, 1e19, gov, {"from": gov})

    # Do a swap to move the price
    qty = 1e16 * [100, 1][buy] * [1, 100][big]
    router.swap(pool, buy, qty, {"from": gov})

    # Rebalance
    total0, total1 = vault.getTotalAmounts()
    vault.rebalance({"from": gov})

    # Check values haven't changed - they should only increase a bit due to fees earned
    newTotal0, newTotal1 = vault.getTotalAmounts()
    if buy:
        assert approx(total1) == newTotal1
        assert approx(total0, rel=1e-2) == newTotal0
        assert total0 < newTotal0
    else:
        assert approx(total0) == newTotal0
        assert approx(total1, rel=1e-2) == newTotal1
        assert total1 < newTotal1


def test_rebalance_cooldown(vault, gov):
    vault.rebalance({"from": gov})

    # After 22 hours, cannot rebalance yet
    chain.sleep(22 * 60 * 60)
    with reverts("cooldown"):
        vault.rebalance({"from": gov})

    # After another 2 hours, rebalance works
    chain.sleep(2 * 60 * 60)
    vault.rebalance({"from": gov})


def test_governance_methods(vault, tokens, gov, user, recipient):
    with reverts("governance"):
        vault.setBaseThreshold(0, {"from": user})
    with reverts("baseThreshold"):
        vault.setBaseThreshold(2401, {"from": gov})
    with reverts("baseThreshold"):
        vault.setBaseThreshold(0, {"from": gov})
    vault.setBaseThreshold(4800, {"from": gov})
    assert vault.baseThreshold() == 4800

    with reverts("governance"):
        vault.setSkewThreshold(0, {"from": user})
    with reverts("skewThreshold"):
        vault.setSkewThreshold(1201, {"from": gov})
    with reverts("skewThreshold"):
        vault.setSkewThreshold(0, {"from": gov})
    vault.setSkewThreshold(600, {"from": gov})
    assert vault.skewThreshold() == 600

    with reverts("governance"):
        vault.setMaxTwapDeviation(1000, {"from": user})
    with reverts("maxTwapDeviation"):
        vault.setMaxTwapDeviation(-1, {"from": gov})
    vault.setMaxTwapDeviation(1000, {"from": gov})
    assert vault.maxTwapDeviation() == 1000

    with reverts("governance"):
        vault.setTwapDuration(800, {"from": user})
    vault.setTwapDuration(800, {"from": gov})
    assert vault.twapDuration() == 800

    with reverts("governance"):
        vault.setRebalanceCooldown(12 * 60 * 60, {"from": user})
    vault.setRebalanceCooldown(12 * 60 * 60, {"from": gov})
    assert vault.rebalanceCooldown() == 12 * 60 * 60

    with reverts("governance"):
        vault.setMaxTotalSupply(0, {"from": user})
    vault.setMaxTotalSupply(0, {"from": gov})
    assert vault.maxTotalSupply() == 0

    tokens[0].transfer(vault, 1e18, {"from": gov})
    with reverts("governance"):
        vault.emergencyWithdraw(tokens[0], 1e18, {"from": user})
    balance = tokens[0].balanceOf(gov)
    vault.emergencyWithdraw(tokens[0], 1e18, {"from": gov})
    assert tokens[0].balanceOf(gov) == balance + 1e18

    vault.deposit(1e8, 1e8, gov, {"from": gov})
    with reverts("governance"):
        vault.emergencyBurn(vault.baseLower(), vault.baseUpper(), 1e3, {"from": user})
    balance0 = tokens[0].balanceOf(gov)
    balance1 = tokens[1].balanceOf(gov)
    vault.emergencyBurn(vault.baseLower(), vault.baseUpper(), 1e3, {"from": gov})
    assert tokens[0].balanceOf(gov) > balance0
    assert tokens[1].balanceOf(gov) > balance1

    with reverts("governance"):
        vault.finalize({"from": user})
    assert not vault.finalized()
    vault.finalize({"from": gov})
    assert vault.finalized()
    with reverts("finalized"):
        vault.emergencyWithdraw(tokens[0], 1e18, {"from": gov})
    with reverts("finalized"):
        vault.emergencyBurn(vault.baseLower(), vault.baseUpper(), 1e8, {"from": gov})

    with reverts("governance"):
        vault.setGovernance(recipient, {"from": user})
    vault.setGovernance(recipient, {"from": gov})

    with reverts("pendingGovernance"):
        vault.acceptGovernance({"from": user})
    vault.acceptGovernance({"from": recipient})
    assert vault.governance() == recipient
