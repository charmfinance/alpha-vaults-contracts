from brownie import accounts, PassiveRebalanceVault
from brownie.network.gas.strategies import GasNowScalingStrategy
import os


POOL = "0xD4B4568615CB365bcA926910ebc30EA2161067Cf"


def getAccount(account, pw):
    from web3.auto import w3

    with open(account, "r") as f:
        return accounts.add(w3.eth.account.decrypt(f.read(), pw))


def main():
    keeper = getAccount(os.environ["KEEPER_ACCOUNT"], os.environ["KEEPER_PW"])
    # keeper = accounts.load(input("Brownie account: "))

    gas_strategy = GasNowScalingStrategy()

    balance = keeper.balance()

    pool = CubePool.at(POOL)
    pool.updateAll({"from": keeper, "gas_price": gas_strategy})

    print(f"Gas used: {(balance - keeper.balance()) / 1e18:.4f} ETH")
    print(f"New balance: {keeper.balance() / 1e18:.4f} ETH")
