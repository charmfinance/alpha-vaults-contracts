from brownie import reverts


def test_constructor(AlphaStrategy, vault, gov, keeper):
    strategy = gov.deploy(AlphaStrategy, vault, 2400, 1200, 600, 500, 300, keeper)
    assert strategy.vault() == vault
    assert strategy.pool() == vault.pool()
    assert strategy.baseThreshold() == 2400
    assert strategy.limitThreshold() == 1200
    assert strategy.minLastTickDeviation() == 600
    assert strategy.maxTwapDeviation() == 500
    assert strategy.twapDuration() == 300
    assert strategy.keeper() == keeper


def test_constructor_checks(AlphaStrategy, vault, gov, keeper):
    with reverts("threshold not tick multiple"):
        gov.deploy(AlphaStrategy, vault, 2401, 1200, 600, 500, 300, keeper)

    with reverts("threshold not tick multiple"):
        gov.deploy(AlphaStrategy, vault, 2400, 1201, 600, 500, 300, keeper)

    with reverts("threshold not positive"):
        gov.deploy(AlphaStrategy, vault, 0, 1200, 600, 500, 300, keeper)

    with reverts("threshold not positive"):
        gov.deploy(AlphaStrategy, vault, 2400, 0, 600, 500, 300, keeper)

    with reverts("threshold too high"):
        gov.deploy(AlphaStrategy, vault, 887280, 1200, 600, 500, 300, keeper)

    with reverts("threshold too high"):
        gov.deploy(AlphaStrategy, vault, 2400, 887280, 600, 500, 300, keeper)

    with reverts("minLastTickDeviation"):
        gov.deploy(AlphaStrategy, vault, 2400, 1200, -1, 500, 300, keeper)

    with reverts("maxTwapDeviation"):
        gov.deploy(AlphaStrategy, vault, 2400, 1200, 600, -1, 300, keeper)

    with reverts("twapDuration"):
        gov.deploy(AlphaStrategy, vault, 2400, 1200, 600, 500, 0, keeper)
