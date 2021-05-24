from brownie import accounts, AlphaVault, AlphaStrategy


# POOL = "0x8ad599c3a0ff1de082011efddc58f1908eb6e6d8"  # USDC / ETH
POOL = "0x4e68ccd3e89f51c3074ca5072bbac773960dfa36"  # ETH / USDT

PROTOCOL_FEE = 5000
MAX_TOTAL_SUPPLY = 2e17

BASE_THRESHOLD = 3600
LIMIT_THRESHOLD = 1200
MAX_TWAP_DEVIATION = 100
TWAP_DURATION = 60
KEEPER = "0x04c82c5791bbbdfbdda3e836ccbef567fdb2ea07"


def main():
    deployer = accounts.load("deployer")
    balance = deployer.balance()

    vault = deployer.deploy(
        AlphaVault,
        POOL,
        PROTOCOL_FEE,
        MAX_TOTAL_SUPPLY,
        publish_source=True,
    )
    strategy = deployer.deploy(
        AlphaStrategy,
        vault,
        BASE_THRESHOLD,
        LIMIT_THRESHOLD,
        MAX_TWAP_DEVIATION,
        TWAP_DURATION,
        KEEPER,
        publish_source=True,
    )
    vault.setStrategy(strategy, {"from": deployer})

    print(f"Gas used: {(balance - deployer.balance()) / 1e18:.4f} ETH")
    print(f"Vault address: {vault.address}")
