from brownie import reverts


def test_governance_methods(vault, strategy, gov, user, recipient):

    # Check setting base threshold
    with reverts("governance"):
        strategy.setBaseThreshold(0, {"from": user})
    with reverts("threshold not tick multiple"):
        strategy.setBaseThreshold(2401, {"from": gov})
    with reverts("threshold not positive"):
        strategy.setBaseThreshold(0, {"from": gov})
    with reverts("threshold too high"):
        strategy.setBaseThreshold(887280, {"from": gov})
    strategy.setBaseThreshold(4800, {"from": gov})
    assert strategy.baseThreshold() == 4800

    # Check setting limit threshold
    with reverts("governance"):
        strategy.setLimitThreshold(0, {"from": user})
    with reverts("threshold not tick multiple"):
        strategy.setLimitThreshold(1201, {"from": gov})
    with reverts("threshold not positive"):
        strategy.setLimitThreshold(0, {"from": gov})
    with reverts("threshold too high"):
        strategy.setLimitThreshold(887280, {"from": gov})
    strategy.setLimitThreshold(600, {"from": gov})
    assert strategy.limitThreshold() == 600

    # Check setting max twap deviation
    with reverts("governance"):
        strategy.setMaxTwapDeviation(1000, {"from": user})
    with reverts("maxTwapDeviation"):
        strategy.setMaxTwapDeviation(-1, {"from": gov})
    strategy.setMaxTwapDeviation(1000, {"from": gov})
    assert strategy.maxTwapDeviation() == 1000

    # Check setting twap duration
    with reverts("governance"):
        strategy.setTwapDuration(800, {"from": user})
    strategy.setTwapDuration(800, {"from": gov})
    assert strategy.twapDuration() == 800

    # Check setting keeper
    with reverts("governance"):
        strategy.setKeeper(recipient, {"from": user})
    assert strategy.keeper() != recipient
    strategy.setKeeper(recipient, {"from": gov})
    assert strategy.keeper() == recipient

    # Check gov changed in vault
    vault.setGovernance(user, {"from": gov})
    vault.acceptGovernance({"from": user})
    with reverts("governance"):
        strategy.setKeeper(recipient, {"from": gov})
    strategy.setKeeper(recipient, {"from": user})
