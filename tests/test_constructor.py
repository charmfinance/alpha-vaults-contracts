from brownie import reverts


def test_constructor(PassiveRebalanceVault, pool, gov):
    vault = gov.deploy(
        PassiveRebalanceVault, pool, 2400, 1200, 500, 600, 10000, 20000, 100e18
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
    assert vault.depositFee() == 10000
    assert vault.streamingFee() == 20000
    assert vault.streamingFee() == 20000
    assert vault.maxTotalSupply() == 100e18
    assert vault.governance() == gov

    assert vault.name() == "Alpha Vault"
    assert vault.symbol() == "AV"
    assert vault.decimals() == 18

    assert vault.getTotalAmounts() == (0, 0)


def test_constructor_checks(PassiveRebalanceVault, pool, gov):
    with reverts("threshold not tick multiple"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2401, 1200, 500, 600, 10000, 20000, 100e18
        )

    with reverts("threshold not tick multiple"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1201, 500, 600, 10000, 20000, 100e18
        )

    with reverts("threshold not positive"):
        gov.deploy(PassiveRebalanceVault, pool, 0, 1200, 500, 600, 10000, 20000, 100e18)

    with reverts("threshold not positive"):
        gov.deploy(PassiveRebalanceVault, pool, 2400, 0, 500, 600, 10000, 20000, 100e18)

    with reverts("threshold too high"):
        gov.deploy(
            PassiveRebalanceVault, pool, 887280, 1200, 500, 600, 10000, 20000, 100e18
        )

    with reverts("threshold too high"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2400, 887280, 500, 600, 10000, 20000, 100e18
        )

    with reverts("maxTwapDeviation"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1200, -1, 600, 10000, 20000, 100e18
        )

    with reverts("twapDuration"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1200, 500, 0, 10000, 20000, 100e18
        )

    with reverts("depositFee"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1200, 500, 600, 1e6, 20000, 100e18
        )

    with reverts("streamingFee"):
        gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1200, 500, 600, 10000, 1e6, 100e18
        )


def test_price_is_min_or_max_tick_checks(PassiveRebalanceVault, poolFromPrice, gov):
    # min sqrt ratio from TickMath.sol
    pool = poolFromPrice(4295128739)
    with reverts("price too low"):
        vault = gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1200, 200000, 600, 10000, 20000, 100e18
        )

    # max sqrt ratio from TickMath.sol
    pool = poolFromPrice(1461446703485210103287273052203988822378723970342 - 1)
    with reverts("price too high"):
        vault = gov.deploy(
            PassiveRebalanceVault, pool, 2400, 1200, 200000, 600, 10000, 20000, 100e18
        )
