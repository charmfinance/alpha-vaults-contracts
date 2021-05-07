from brownie import reverts


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
    assert vault.limitThreshold() == 1200
    assert vault.maxTwapDeviation() == 500
    assert vault.twapDuration() == 600
    assert vault.rebalanceCooldown() == 12 * 60 * 60
    assert vault.maxTotalSupply() == 100e18
    assert vault.governance() == gov

    tick = pool.slot0()[1] // 60 * 60
    assert vault.baseLower() == tick - 2400
    assert vault.baseUpper() == tick + 2460
    assert vault.limitLower() == tick - 1200
    assert vault.limitUpper() == tick

    assert vault.name() == "Alpha Vault"
    assert vault.symbol() == "AV"
    assert vault.decimals() == 18


def test_constructor_checks(PassiveRebalanceVault, pool, gov):
    with reverts("threshold not tick multiple"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2401, 1200, 500, 600, 23 * 60 * 60, 100e18
        )

    with reverts("threshold not tick multiple"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1201, 500, 600, 23 * 60 * 60, 100e18
        )

    with reverts("threshold not positive"):
        gov.deploy(PassiveRebalanceVault, pool, 0, 1200, 500, 600, 23 * 60 * 60, 100e18)

    with reverts("threshold not positive"):
        gov.deploy(PassiveRebalanceVault, pool, 2400, 0, 500, 600, 23 * 60 * 60, 100e18)

    with reverts("threshold too high"):
        gov.deploy(
            PassiveRebalanceVault, pool, 887280, 1200, 500, 600, 23 * 60 * 60, 100e18
        )

    with reverts("threshold too high"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2400, 887280, 500, 600, 23 * 60 * 60, 100e18
        )

    # check works with small thresholds
    gov.deploy(PassiveRebalanceVault, pool, 60, 1200, 500, 600, 23 * 60 * 60, 100e18)
    gov.deploy(PassiveRebalanceVault, pool, 2400, 60, 500, 600, 23 * 60 * 60, 100e18)

    with reverts("maxTwapDeviation"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1200, -1, 600, 23 * 60 * 60, 100e18
        )


def test_price_is_min_or_max_tick_checks(PassiveRebalanceVault, poolFromPrice, gov):
    # min sqrt ratio from TickMath.sol
    pool = poolFromPrice(4295128739)

    with reverts("price too low"):
        vault = gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1200, 200000, 600, 23 * 60 * 60, 100e18
        )

    # max sqrt ratio from TickMath.sol
    pool = poolFromPrice(1461446703485210103287273052203988822378723970342 - 1)
    with reverts("price too high"):
        vault = gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1200, 200000, 600, 23 * 60 * 60, 100e18
        )
