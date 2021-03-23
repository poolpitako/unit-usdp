import pytest
from brownie import config, Wei, Contract


@pytest.fixture
def gov(accounts):
    # ychad.eth
    yield accounts.at('0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52', force=True)


@pytest.fixture
def rewards(gov):
    yield gov  # TODO: Add rewards contract


@pytest.fixture
def guardian(accounts):
    # dev.ychad.eth
    yield accounts.at('0x846e211e8ba920B353FB717631C015cf04061Cc9', force=True)


@pytest.fixture
def management(accounts):
    # dev.ychad.eth
    yield accounts.at('0x846e211e8ba920B353FB717631C015cf04061Cc9', force=True)


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    token_address = "[token address]"
    yield Contract(token_address)


@pytest.fixture
def amount(accounts, token, whale):
    amount = 10_000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = whale
    yield amount


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy(accounts, strategist, keeper, vault, Strategy, gov):
    strategy = strategist.deploy(Strategy, vault)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture
def whale(accounts):
    # binance7 wallet
    # acc = accounts.at('0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8', force=True)

    # binance8 wallet
    #acc = accounts.at('0xf977814e90da44bfa03b6295a0616a897441acec', force=True)

    # where does the whale from
    acc = accounts.at('[whale address]', force=True)
    yield acc


@pytest.fixture
def usdp_vault():
    yield Contract('[yvusdp address]')


@pytest.fixture
def usdp():
    yield Contract('0x1456688345527bE1f37E9e627DA0837D6f08C925')

