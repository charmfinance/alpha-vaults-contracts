from brownie import chain, reverts, ZERO_ADDRESS
import pytest
from pytest import approx


def test_constructor(PassiveRebalanceVault, pool, gov):
    vault = gov.deploy(
        PassiveRebalanceVault, pool, 2400, 1200, 600, 12 * 60 * 60, 100e18
    )
    assert vault.pool() == pool
    assert vault.token0() == pool.token0()
    assert vault.token1() == pool.token1()
    assert vault.fee() == pool.fee()
    assert vault.tickSpacing() == pool.tickSpacing()

    assert vault.baseThreshold() == 2400
    assert vault.rebalanceThreshold() == 1200
    assert vault.twapDuration() == 600
    assert vault.refreshCooldown() == 12 * 60 * 60
    assert vault.totalSupplyCap() == 100e18
    assert vault.governance() == gov

    tick = pool.slot0()[1] // 60 * 60
    assert vault.baseRange() == (tick - 2400, tick + 2460)
    assert vault.rebalanceRange() == (0, 0)

    assert vault.name() == "Passive Rebalance Vault"
    assert vault.symbol() == "PRV"
    assert vault.decimals() == 18


def test_constructor_checks(PassiveRebalanceVault, pool, gov):
    with reverts("baseThreshold"):
        gov.deploy(PassiveRebalanceVault, pool, 2401, 1200, 600, 23 * 60 * 60, 100e18)

    with reverts("rebalanceThreshold"):
        gov.deploy(PassiveRebalanceVault, pool, 2400, 1201, 600, 23 * 60 * 60, 100e18)

    with reverts("baseThreshold"):
        gov.deploy(PassiveRebalanceVault, pool, 0, 1200, 600, 23 * 60 * 60, 100e18)

    with reverts("rebalanceThreshold"):
        gov.deploy(PassiveRebalanceVault, pool, 2400, 0, 600, 23 * 60 * 60, 100e18)


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
    tx = vault.mint(maxAmount0, maxAmount1, recipient, {"from": user})
    shares = tx.return_value

    # Check shares
    assert shares == vault.balanceOf(recipient) > 0

    # Check spent right amount
    dbalance0 = balance0 - tokens[0].balanceOf(user)
    dbalance1 = balance1 - tokens[1].balanceOf(user)
    zeroTight = dbalance0 / maxAmount0 > dbalance1 / maxAmount1
    if zeroTight:
        assert dbalance0 == maxAmount0
        assert dbalance1 < maxAmount1
    else:
        assert dbalance0 < maxAmount0
        assert dbalance1 == maxAmount1


def test_mint_initial_checks(vault, user, recipient):
    with reverts("shares"):
        vault.mint(0, 1e8, recipient, {"from": user})
    with reverts("shares"):
        vault.mint(1e8, 0, recipient, {"from": user})
    with reverts("to"):
        vault.mint(1e8, 1e8, ZERO_ADDRESS, {"from": user})


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
    base0, rebalance0 = getPositions(vault)

    # Mint
    tx = vault.mint(maxAmount0, maxAmount1, recipient, {"from": user})
    shares = tx.return_value

    # Check shares
    assert shares == vault.balanceOf(recipient) > 0

    # Check spent right amount
    dbalance0 = balance0 - tokens[0].balanceOf(user)
    dbalance1 = balance1 - tokens[1].balanceOf(user)
    zeroTight = dbalance0 / maxAmount0 > dbalance1 / maxAmount1
    if zeroTight:
        # Max amount 0 is the tight constraint
        assert approx(dbalance0, abs=3) == maxAmount0
        assert dbalance0 <= maxAmount0
        assert dbalance1 <= maxAmount1
    else:
        # Max amount 1 is the tight constraint
        assert approx(dbalance1, abs=3) == maxAmount1
        assert dbalance0 <= maxAmount0
        assert dbalance1 <= maxAmount1

    # Check liquidity and balances are in proportion
    base1, rebalance1 = getPositions(vault)
    ratio = (totalSupply + shares) / totalSupply
    assert approx(base1[0] / base0[0]) == ratio
    assert approx(rebalance1[0] / rebalance0[0]) == ratio


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
    base0, rebalance0 = getPositions(vault)

    # Mint
    tx = vault.mint(maxAmount0, maxAmount1, recipient, {"from": user})
    shares = tx.return_value

    # Check shares
    assert shares == vault.balanceOf(recipient) > 0

    # Check spent right amount
    dbalance0 = balance0 - tokens[0].balanceOf(user)
    dbalance1 = balance1 - tokens[1].balanceOf(user)
    assert approx(dbalance1, rel=1e-5, abs=10) == maxAmount1
    assert dbalance0 < 10
    assert dbalance1 <= maxAmount1

    # Check liquidity and balances are in proportion
    base1, rebalance1 = getPositions(vault)
    ratio = (totalSupply + shares) / totalSupply
    assert base0[0] == base1[0] == 0
    assert approx(rebalance1[0] / rebalance0[0], rel=1e-5) == ratio


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
    base0, rebalance0 = getPositions(vault)

    # Mint
    tx = vault.mint(maxAmount0, maxAmount1, recipient, {"from": user})
    shares = tx.return_value

    # Check shares
    assert shares == vault.balanceOf(recipient) > 0

    # Check spent right amount
    dbalance0 = balance0 - tokens[0].balanceOf(user)
    dbalance1 = balance1 - tokens[1].balanceOf(user)
    assert approx(dbalance0, abs=10) == maxAmount0
    assert dbalance0 <= maxAmount0
    assert dbalance1 == 0

    # Check liquidity and balances are in proportion
    base1, rebalance1 = getPositions(vault)
    ratio = (totalSupply + shares) / totalSupply
    assert base0[0] == base1[0] == 0
    assert approx(rebalance1[0] / rebalance0[0], rel=1e-5) == ratio


def test_mint_existing_checks(vaultAfterPriceMove, user, recipient):
    with reverts("shares"):
        vaultAfterPriceMove.mint(0, 1e8, recipient, {"from": user})
    with reverts("shares"):
        vaultAfterPriceMove.mint(1e8, 0, recipient, {"from": user})
    with reverts("to"):
        vaultAfterPriceMove.mint(1e8, 1e8, ZERO_ADDRESS, {"from": user})


def test_mint_existing_checks_when_price_up(vaultAfterPriceUp, user, recipient):
    with reverts("shares"):
        vaultAfterPriceUp.mint(1e8, 0, recipient, {"from": user})
    vaultAfterPriceUp.mint(0, 1e8, recipient, {"from": user})


def test_mint_existing_checks_when_price_down(vaultAfterPriceDown, user, recipient):
    with reverts("shares"):
        vaultAfterPriceDown.mint(0, 1e8, recipient, {"from": user})
    vaultAfterPriceDown.mint(1e8, 0, recipient, {"from": user})


def test_burn(
    vaultAfterPriceMove, pool, tokens, router, getPositions, gov, user, recipient
):
    vault = vaultAfterPriceMove

    # Fast-forward 24 hours to avoid cooldown
    chain.sleep(24 * 60 * 60)

    # Mint and refresh
    tx = vault.mint(1e6, 1e8, user, {"from": user})
    shares = tx.return_value
    vault.refresh({"from": gov})

    # Store balances, supply and positions
    balance0 = tokens[0].balanceOf(recipient)
    balance1 = tokens[1].balanceOf(recipient)
    totalSupply = vault.totalSupply()
    base0, rebalance0 = getPositions(vault)

    # Burn
    vault.burn(shares, recipient, {"from": user})
    assert vault.balanceOf(user) == 0

    # Check liquidity in pool
    base1, rebalance1 = getPositions(vault)
    assert approx((totalSupply - shares) / totalSupply) == base1[0] / base0[0]
    assert approx((totalSupply - shares) / totalSupply) == rebalance1[0] / rebalance0[0]

    # Check recipient has received tokens
    assert tokens[0].balanceOf(recipient) > balance0
    assert tokens[1].balanceOf(recipient) > balance1


def test_refresh_when_empty_then_mint(
    vault, pool, tokens, getPositions, gov, user, recipient
):

    # Fast-forward 24 hours to avoid cooldown
    chain.sleep(24 * 60 * 60)

    # Refresh
    vault.refresh({"from": gov})

    tx = vault.mint(1e6, 1e8, user, {"from": user})
    shares = tx.return_value

    # Check liquidity in pool
    base, rebalance = getPositions(vault)
    assert base[0] > 0
    assert rebalance[0] == 0


def test_burn_all(vault, pool, tokens, getPositions, gov, user, recipient):

    # Fast-forward 24 hours to avoid cooldown
    chain.sleep(24 * 60 * 60)

    # Mint
    tx = vault.mint(1e17, 1e19, gov, {"from": gov})
    shares = tx.return_value

    # Refresh
    vault.refresh({"from": gov})

    # Burn all
    vault.burn(shares, gov, {"from": gov})

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
def test_refresh(vault, pool, tokens, router, getPositions, gov, user, buy, big):

    # Mint some liquidity
    vault.mint(1e17, 1e19, gov, {"from": gov})

    # Do a swap to move the price
    qty = 1e16 * [100, 1][buy] * [1, 100][big]
    router.swap(pool, buy, qty, {"from": gov})

    # Rebalance
    vault.refresh({"from": gov})

    # Check ranges are set correctly
    tick = pool.slot0()[1] // 60 * 60
    assert vault.baseRange() == (tick - 2400, tick + 60 + 2400)
    if buy:
        assert vault.rebalanceRange() == (tick + 60, tick + 60 + 1200)
    else:
        assert vault.rebalanceRange() == (tick - 1200, tick)

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
    vault.mint(maxAmount0, maxAmount1, recipient, {"from": user})

    # Check amounts match values
    dbalance0 = balance0 - tokens[0].balanceOf(user)
    dbalance1 = balance1 - tokens[1].balanceOf(user)
    damount0 = vault.getTotalAmounts()[0] - total0
    damount1 = vault.getTotalAmounts()[1] - total1
    assert approx(dbalance0, abs=1) == damount0
    assert approx(dbalance1, abs=1) == damount1


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
    vault.mint(maxAmount0, maxAmount1, recipient, {"from": user})

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
def test_values_do_not_change_after_refresh(
    vault, pool, tokens, router, getPositions, gov, user, buy, big
):

    # Mint some liquidity
    vault.mint(1e17, 1e19, gov, {"from": gov})

    # Do a swap to move the price
    qty = 1e16 * [100, 1][buy] * [1, 100][big]
    router.swap(pool, buy, qty, {"from": gov})

    # Rebalance
    total0, total1 = vault.getTotalAmounts()
    vault.refresh({"from": gov})

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


def test_update_cooldown(vault, gov):
    vault.refresh({"from": gov})

    # After 22 hours, cannot refresh yet
    chain.sleep(22 * 60 * 60)
    with reverts("cooldown"):
        vault.refresh({"from": gov})

    # Mint some liquidity
    vault.mint(1e17, 1e19, gov, {"from": gov})

    # Do a swap to move the price
    qty = 1e16 * [100, 1][buy] * [1, 100][big]
    router.swap(pool, buy, qty, {"from": gov})
    tick = pool.slot0()[1] // 60 * 60

    # Rebalance
    vault.refresh({"from": gov})
    tick2 = pool.slot0()[1] // 60 * 60
    assert tick == tick2

    # After another 2 hours, refresh works
    chain.sleep(2 * 60 * 60)
    vault.refresh({"from": gov})


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
        vault.setRebalanceThreshold(0, {"from": user})
    with reverts("rebalanceThreshold"):
        vault.setRebalanceThreshold(1201, {"from": gov})
    with reverts("rebalanceThreshold"):
        vault.setRebalanceThreshold(0, {"from": gov})
    vault.setRebalanceThreshold(600, {"from": gov})
    assert vault.rebalanceThreshold() == 600

    with reverts("governance"):
        vault.setTwapDuration(800, {"from": user})
    vault.setTwapDuration(800, {"from": gov})
    assert vault.twapDuration() == 800

    with reverts("governance"):
        vault.setRefreshCooldown(12 * 60 * 60, {"from": user})
    vault.setRefreshCooldown(12 * 60 * 60, {"from": gov})
    assert vault.refreshCooldown() == 12 * 60 * 60

    with reverts("governance"):
        vault.setTotalSupplyCap(0, {"from": user})
    vault.setTotalSupplyCap(0, {"from": gov})
    assert vault.totalSupplyCap() == 0

    with reverts("governance"):
        vault.setGovernance(recipient, {"from": user})
    vault.setGovernance(recipient, {"from": gov})

    with reverts("pendingGovernance"):
        vault.acceptGovernance({"from": user})
    vault.acceptGovernance({"from": recipient})
    assert vault.governance() == recipient
