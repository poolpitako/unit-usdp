from brownie import Wei, reverts
from useful_methods import state_of_vault, state_of_strategy
import brownie


def test_operation(
    web3,
    chain,
    vault,
    strategy,
    token,
    amount,
    usdp,
    usdp_vault,
    whale,
    gov,
    guardian,
    strategist,
):

    # whale approve weth vault to use weth
    token.approve(vault, 2 ** 256 - 1, {"from": whale})

    # start deposit
    vault.deposit(amount, {"from": whale})
    print(f"whale deposit done with {amount/1e18} weth\n")

    print(f"\n****** Initial Status ******")
    print(f"\n****** {token.symbol()} ******")
    state_of_strategy(strategy, token, vault)
    state_of_vault(vault, token)
    print(f"\n****** usdp ******")
    state_of_vault(usdp_vault, usdp)

    print(f"\n****** Harvest {token.symbol()} ******")
    strategy.harvest({"from": strategist})

    print(f"\n****** {token.symbol()} ******")
    state_of_strategy(strategy, token, vault)
    state_of_vault(vault, token)
    print(f"\n****** usdp ******")
    state_of_vault(usdp_vault, usdp)

    # withdraw {token.symbol()}
    print(f"\n****** withdraw {token.symbol()} ******")
    print(f"whale's {token.symbol()} vault share: {vault.balanceOf(whale)/1e18}")
    vault.withdraw(Wei("1 ether"), {"from": whale})
    print(f"withdraw 1 {token.symbol()} done")
    print(f"whale's {token.symbol()} vault share: {vault.balanceOf(whale)/1e18}")

    # transfer usdp to strategy due to rounding issue
    usdp.transfer(strategy, Wei("1 wei"), {"from": gov})

    # withdraw all {token.symbol()}
    print(f"\n****** withdraw all {token.symbol()} ******")
    print(f"whale's {token.symbol()} vault share: {vault.balanceOf(whale)/1e18}")
    vault.withdraw({"from": whale})
    print(f"withdraw all {token.symbol()}")
    print(f"whale's {token.symbol()} vault share: {vault.balanceOf(whale)/1e18}")

    # try call tend
    print(f"\ncall tend")
    strategy.tend()
    print(f"tend done")
