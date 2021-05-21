from brownie import accounts, AlphaVault


POOL = "0x8ad599c3a0ff1de082011efddc58f1908eb6e6d8"  # USDC / ETH

PROTOCOL_FEE = 10000
MAX_TOTAL_SUPPLY = 1e17

BASE_THRESHOLD = 1800
LIMIT_THRESHOLD = 600
MIN_LAST_TICK_DEVIATION = 300
MAX_TWAP_DEVIATION = 100
TWAP_DURATION = 60
KEEPER = ZERO_ADDRESS


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
        MIN_LAST_TICK_DEVIATION,
        MAX_TWAP_DEVIATION,
        TWAP_DURATION,
        KEEPER,
        publish_source=True,
    )

    print(f"Gas used: {(balance - deployer.balance()) / 1e18:.4f} ETH")
    print(f"Vault address: {vault.address}")
