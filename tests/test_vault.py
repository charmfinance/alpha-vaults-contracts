from brownie import chain, reverts
import pytest
from pytest import approx


def test_constructor(Vault, pool, gov):
    vault = gov.deploy(Vault, pool, 2400, 1200, 12*60*60, 600)
    assert vault.pool() == pool
    assert vault.token0() == pool.token0()
    assert vault.token1() == pool.token1()
    assert vault.fee() == pool.fee()
    assert vault.tickSpacing() == pool.tickSpacing()

    assert vault.baseThreshold() == 2400
    assert vault.rebalanceThreshold() == 1200
    assert vault.updateCooldown() == 12*60*60
    assert vault.twapDuration() == 600
    assert vault.governance() == gov

    tick = pool.slot0()[1] // 60 * 60
    assert vault.baseRange() == (tick - 2400, tick + 2460, True)
    assert vault.rebalanceRange() == (0, 0, False)

    assert vault.name() == "name"
    assert vault.symbol() == "symbol"
    assert vault.decimals() == 18


def test_constructor_checks(Vault, pool, gov):
    with reverts("baseThreshold"):
        gov.deploy(Vault, pool, 2401, 1200, 23*60*60, 600)

    with reverts("rebalanceThreshold"):
        gov.deploy(Vault, pool, 2400, 1201, 23*60*60, 600)

    with reverts("baseThreshold"):
        gov.deploy(Vault, pool, 0, 1200, 23*60*60, 600)

    with reverts("rebalanceThreshold"):
        gov.deploy(Vault, pool, 2400, 0, 23*60*60, 600)


def test_mint_new_vault(vault, pool, tokens, getPositions, gov, user, recipient):

    # Store balances
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)

    # Mint 1e8 shares
    vault.mint(1e8, recipient, {"from": user})
    assert vault.balanceOf(recipient) == 1e8

    # Check liquidity in pool
    base, rebalance = getPositions(vault)
    assert base[0] == 1e8
    assert rebalance[0] == 0

    # Check user has spent tokens
    assert tokens[0].balanceOf(user) < balance0
    assert tokens[1].balanceOf(user) < balance1


def test_mint_updated_vault(vault, pool, tokens, router, getPositions, gov, user, recipient):

    # Mint and update to simulate existing activity
    vault.mint(1e18, gov, {"from": gov})
    router.swap(pool, True, 1e16, {"from": gov})
    vault.update()

    # Store balances, supply and positions
    balance0 = tokens[0].balanceOf(user)
    balance1 = tokens[1].balanceOf(user)
    totalSupply = vault.totalSupply()
    base0, rebalance0 = getPositions(vault)

    # Mint
    shares = 1e17
    vault.mint(shares, recipient, {"from": user})
    assert vault.balanceOf(recipient) == shares

    # Check liquidity in pool
    base1, rebalance1 = getPositions(vault)
    assert (totalSupply + shares) / totalSupply == base1[0] / base0[0]
    assert (totalSupply + shares) / totalSupply == rebalance1[0] / rebalance0[0]

    # Check user has spent tokens
    assert tokens[0].balanceOf(user) < balance0
    assert tokens[1].balanceOf(user) < balance1


def test_burn(vault, pool, tokens, router, getPositions, gov, user, recipient):

    # Mint and update to simulate existing activity
    vault.mint(1e18, gov, {"from": gov})
    router.swap(pool, True, 1e16, {"from": gov})
    vault.update()

    # Fast-forward 24 hours to avoid cooldown
    chain.sleep(24*60*60)

    # Mint and update
    shares = 1e17
    vault.mint(shares, user, {"from": user})
    vault.update()

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
    assert (totalSupply - shares) / totalSupply == base1[0] / base0[0]
    assert (totalSupply - shares) / totalSupply == rebalance1[0] / rebalance0[0]

    # Check recipient has received tokens
    assert tokens[0].balanceOf(recipient) > balance0
    assert tokens[1].balanceOf(recipient) > balance1


def test_rebalance_when_empty_then_mint(vault, pool, tokens, getPositions, gov, user, recipient):

    # Fast-forward 24 hours to avoid cooldown
    chain.sleep(24*60*60)

    # Update
    vault.update()

    shares = 1e17
    vault.mint(shares, user, {"from": user})

    # Check liquidity in pool
    base, rebalance = getPositions(vault)
    assert base[0] > 0
    assert rebalance[0] == 0


def test_balances_when_empty():
    1

@pytest.mark.parametrize("buy", [False, True])
@pytest.mark.parametrize("big", [False, True])
def test_update(vault, pool, tokens, router, getPositions, gov, user, buy, big):

    # Mint some liquidity
    vault.mint(1e18, gov, {"from": gov})

    # Do a swap to move the price
    prevTick = pool.slot0()[1] // 60 * 60
    qty = 1e16 * [100, 1][buy] * [1, 100][big]
    router.swap(pool, buy, qty, {"from": gov})

    # Check price did indeed move
    tick = pool.slot0()[1] // 60 * 60
    assert tick != prevTick

    # Rebalance
    vault.update()
    tick2 = pool.slot0()[1] // 60 * 60
    assert tick == tick2

    # Check ranges are set correctly
    assert vault.baseRange() == (tick - 2400, tick + 60 + 2400, True)
    if buy:
        assert vault.rebalanceRange() == (tick + 60, tick + 60 + 1200, True)
    else:
        assert vault.rebalanceRange() == (tick - 1200, tick, True)

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


def test_update_cooldown(vault, gov):
    vault.update({"from": gov})

    # After 22 hours, cannot update yet
    chain.sleep(22*60*60)
    with reverts("cooldown"):
        vault.update({"from": gov})

    # After another 2 hours, update works
    chain.sleep(2*60*60)
    vault.update({"from": gov})


def test_governance_methods(vault, tokens, gov, user, recipient):
    with reverts("!governance"):
        vault.setBaseThreshold(0, {"from": user})
    with reverts("baseThreshold"):
        vault.setBaseThreshold(2401, {"from": gov})
    with reverts("baseThreshold"):
        vault.setBaseThreshold(0, {"from": gov})
    vault.setBaseThreshold(4800, {"from": gov})
    assert vault.baseThreshold() == 4800

    with reverts("!governance"):
        vault.setRebalanceThreshold(0, {"from": user})
    with reverts("rebalanceThreshold"):
        vault.setRebalanceThreshold(1201, {"from": gov})
    with reverts("rebalanceThreshold"):
        vault.setRebalanceThreshold(0, {"from": gov})
    vault.setRebalanceThreshold(600, {"from": gov})
    assert vault.rebalanceThreshold() == 600

    with reverts("!governance"):
        vault.setUpdateCooldown(12*60*60, {"from": user})
    vault.setUpdateCooldown(12*60*60, {"from": gov})
    assert vault.updateCooldown() == 12*60*60

    with reverts("!governance"):
        vault.setTwapDuration(800, {"from": user})
    vault.setTwapDuration(800, {"from": gov})
    assert vault.twapDuration() == 800

    with reverts("!governance"):
        vault.setGovernance(recipient, {"from": user})
    vault.setGovernance(recipient, {"from": gov})

    with reverts("!pendingGovernance"):
        vault.acceptGovernance({"from": user})
    vault.acceptGovernance({"from": recipient})
    assert vault.governance() == recipient



