from brownie import reverts


def test_governance_methods(vault, strategy, tokens, gov, user, recipient, keeper):

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

    # Check emergency burn
    vault.deposit(1e8, 1e10, 0, 0, gov, {"from": gov})
    strategy.rebalance({"from": keeper})

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

    # Check setting strategy
    with reverts("governance"):
        vault.setStrategy(recipient, {"from": user})
    assert vault.strategy() != recipient
    vault.setStrategy(recipient, {"from": gov})
    assert vault.strategy() == recipient

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


def test_collect_protocol_fees(
    vault, pool, strategy, router, tokens, gov, user, recipient, keeper
):
    strategy.setMaxTwapDeviation(1 << 20, {"from": gov})
    vault.deposit(1e18, 1e20, 0, 0, gov, {"from": gov})
    tx = strategy.rebalance({"from": keeper})

    router.swap(pool, True, 1e16, {"from": gov})
    router.swap(pool, False, 1e18, {"from": gov})
    tx = strategy.rebalance({"from": keeper})
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
