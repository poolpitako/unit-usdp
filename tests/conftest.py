import pytest
from brownie import config, Wei, Contract


@pytest.fixture
def gov(accounts):
    # ychad.eth
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def rewards(gov):
    yield gov  # TODO: Add rewards contract


@pytest.fixture
def guardian(accounts):
    # dev.ychad.eth
    yield accounts.at("0x846e211e8ba920B353FB717631C015cf04061Cc9", force=True)


@pytest.fixture
def management(accounts):
    # dev.ychad.eth
    yield accounts.at("0x846e211e8ba920B353FB717631C015cf04061Cc9", force=True)


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    yield Contract("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")


@pytest.fixture
def amount(accounts, token):
    amount = 100 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
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
def strategy(accounts, strategist, keeper, vault, Strategy, gov, usdp_vault):
    strategy = strategist.deploy(Strategy, vault, usdp_vault)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture
def whale(accounts):
    yield accounts.at("0x2F0b23f53734252Bda2277357e97e1517d6B042A", force=True)


@pytest.fixture
def usdp_whale(accounts):
    yield accounts.at("0x42d7025938bec20b69cbae5a77421082407f053a", force=True)


@pytest.fixture
def usdp_vault(pm, gov, rewards, guardian, management, usdp):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(usdp, gov, rewards, "", "", guardian)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def usdp():
    yield Contract("0x1456688345527bE1f37E9e627DA0837D6f08C925")
