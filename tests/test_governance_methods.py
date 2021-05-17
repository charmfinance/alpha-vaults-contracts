from brownie import reverts


def test_governance_methods(vault, tokens, gov, user, recipient):

    # Check setting base threshold
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

    # Check setting limit threshold
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

    # Check setting max twap deviation
    with reverts("governance"):
        vault.setMaxTwapDeviation(1000, {"from": user})
    with reverts("maxTwapDeviation"):
        vault.setMaxTwapDeviation(-1, {"from": gov})
    vault.setMaxTwapDeviation(1000, {"from": gov})
    assert vault.maxTwapDeviation() == 1000

    # Check setting twap duration
    with reverts("governance"):
        vault.setTwapDuration(800, {"from": user})
    vault.setTwapDuration(800, {"from": gov})
    assert vault.twapDuration() == 800

    # Check setting protocol fee
    with reverts("governance"):
        vault.setProtocolFee(0, {"from": user})
    with reverts("protocolFee"):
        vault.setProtocolFee(1e6, {"from": gov})
    vault.setProtocolFee(0, {"from": gov})
    assert vault.protocolFee() == 0

    # Check setting max total supply
    with reverts("governance"):
        vault.setMaxTotalSupply(1 << 255, {"from": user})
    vault.setMaxTotalSupply(1 << 255, {"from": gov})
    assert vault.maxTotalSupply() == 1 << 255

    # Check emergency withdraw
    tokens[0].transfer(vault, 1e18, {"from": gov})
    with reverts("governance"):
        vault.emergencyWithdraw(tokens[0], 1e18, {"from": user})
    balance = tokens[0].balanceOf(gov)
    vault.emergencyWithdraw(tokens[0], 1e18, {"from": gov})
    assert tokens[0].balanceOf(gov) == balance + 1e18

    vault.deposit(1e8, 1e10, 0, 0, gov, {"from": gov})
    vault.rebalance({"from": gov})

    # Check emergency burn
    with reverts("governance"):
        vault.emergencyBurn(vault.baseLower(), vault.baseUpper(), 1e4, {"from": user})
    balance0 = tokens[0].balanceOf(gov)
    balance1 = tokens[1].balanceOf(gov)
    vault.emergencyBurn(vault.baseLower(), vault.baseUpper(), 1e4, {"from": gov})
    assert tokens[0].balanceOf(gov) > balance0
    assert tokens[1].balanceOf(gov) > balance1

    # Check finalize
    with reverts("governance"):
        vault.finalize({"from": user})
    assert not vault.finalized()
    vault.finalize({"from": gov})
    assert vault.finalized()
    with reverts("finalized"):
        vault.emergencyWithdraw(tokens[0], 1e18, {"from": gov})
    with reverts("finalized"):
        vault.emergencyBurn(vault.baseLower(), vault.baseUpper(), 1e8, {"from": gov})

    # Check setting keeper
    with reverts("governance"):
        vault.setKeeper(recipient, {"from": user})
    assert vault.keeper() != recipient
    vault.setKeeper(recipient, {"from": gov})
    assert vault.keeper() == recipient

    # Check setting governance
    with reverts("governance"):
        vault.setGovernance(recipient, {"from": user})
    assert vault.pendingGovernance() != recipient
    vault.setGovernance(recipient, {"from": gov})
    assert vault.pendingGovernance() == recipient

    # Check accepting governance
    with reverts("pendingGovernance"):
        vault.acceptGovernance({"from": user})
    assert vault.governance() != recipient
    vault.acceptGovernance({"from": recipient})
    assert vault.governance() == recipient


def test_collect_protocol_fees(pool, vault, router, tokens, gov, user, recipient):
    vault.setMaxTwapDeviation(1 << 20, {"from": gov})
    vault.deposit(1e18, 1e20, 0, 0, gov, {"from": gov})
    tx = vault.rebalance({"from": gov})

    router.swap(pool, True, 1e16, {"from": gov})
    router.swap(pool, False, 1e18, {"from": gov})
    tx = vault.rebalance({"from": gov})
    protocolFees0, protocolFees1 = vault.protocolFees0(), vault.protocolFees1()

    balance0 = tokens[0].balanceOf(recipient)
    balance1 = tokens[1].balanceOf(recipient)
    with reverts("governance"):
        vault.collectProtocol(1e3, 1e4, recipient, {"from": user})
    with reverts("SafeMath: subtraction overflow"):
        vault.collectProtocol(1e18, 1e4, recipient, {"from": gov})
    with reverts("SafeMath: subtraction overflow"):
        vault.collectProtocol(1e3, 1e18, recipient, {"from": gov})
    vault.collectProtocol(1e3, 1e4, recipient, {"from": gov})
    assert vault.protocolFees0() == protocolFees0 - 1e3
    assert vault.protocolFees1() == protocolFees1 - 1e4
    assert tokens[0].balanceOf(recipient) - balance0 == 1e3
    assert tokens[1].balanceOf(recipient) - balance1 == 1e4 > 0
