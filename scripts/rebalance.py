from brownie import accounts, AlphaStrategy
from brownie.network.gas.strategies import GasNowScalingStrategy
import os


STRATEGIES = [
    "0x40C36799490042b31Efc4D3A7F8BDe5D3cB03526",
]


def getAccount(account, pw):
    from web3.auto import w3

    with open(account, "r") as f:
        return accounts.add(w3.eth.account.decrypt(f.read(), pw))


def main():
    keeper = getAccount(os.environ["KEEPER_ACCOUNT"], os.environ["KEEPER_PW"])
    # keeper = accounts.load(input("Brownie account: "))

    gas_strategy = GasNowScalingStrategy()

    balance = keeper.balance()

    for address in STRATEGIES:
        print(f"Running for strategy: {address}")
        strategy = AlphaStrategy.at(address)

        tick = strategy.getTick()
        lastTick = strategy.lastTick()
        print(f"Tick: {tick}")
        print(f"Last tick: {lastTick}")

        # shouldRebalance = abs(tick - lastTick) > strategy.limitThreshold() // 4
        shouldRebalance = abs(tick - lastTick) > 200

        if shouldRebalance:
            print("Rebalancing...")
            strategy.rebalance({"from": keeper, "gas_price": gas_strategy})
        else:
            print("Deviation too low so skipping")

    print(f"Gas used: {(balance - keeper.balance()) / 1e18:.4f} ETH")
    print(f"New balance: {keeper.balance() / 1e18:.4f} ETH")
