from brownie import PassiveRebalanceVault


def main():
    source = PassiveRebalanceVault.get_verification_info()["flattened_source"]

    with open("flat.sol", "w") as f:
        f.write(source)
