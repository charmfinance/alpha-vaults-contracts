from brownie import reverts


def test_governance_methods(vault, tokens, gov, user, recipient):
    with reverts("governance"):
        vault.setBaseThreshold(0, {"from": user})
    with reverts("threshold not tick multiple"):
        vault.setBaseThreshold(2401, {"from": gov})
    with reverts("threshold not positive"):
        vault.setBaseThreshold(0, {"from": gov})
    with reverts("threshold too high"):
        vault.setBaseThreshold(887280, {"from": gov})
    vault.setBaseThreshold(4800, {"from": gov})
    assert vault.baseThreshold() == 4800

    with reverts("governance"):
        vault.setLimitThreshold(0, {"from": user})
    with reverts("threshold not tick multiple"):
        vault.setLimitThreshold(1201, {"from": gov})
    with reverts("threshold not positive"):
        vault.setLimitThreshold(0, {"from": gov})
    with reverts("threshold too high"):
        vault.setLimitThreshold(887280, {"from": gov})
    vault.setLimitThreshold(600, {"from": gov})
    assert vault.limitThreshold() == 600

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

    vault.deposit(1e8, 1 << 255, 1 << 255, gov, {"from": gov})
    with reverts("governance"):
        vault.emergencyBurn(vault.baseLower(), vault.baseUpper(), 1e4, {"from": user})
    balance0 = tokens[0].balanceOf(gov)
    balance1 = tokens[1].balanceOf(gov)
    vault.emergencyBurn(vault.baseLower(), vault.baseUpper(), 1e4, {"from": gov})
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
