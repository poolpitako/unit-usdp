// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/unit/Unit.sol";
import "../interfaces/yearn/yVault.sol";
import "../interfaces/uniswap/Uni.sol";

// import "../interfaces/curve/Curve.sol";

interface IERC20Metadata {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow, so we distribute
        return (a / 2) + (b / 2) + (((a % 2) + (b % 2)) / 2);
    }
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // want = address(0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e)
    address public constant weth =
        address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public constant usdp =
        address(0x1456688345527bE1f37E9e627DA0837D6f08C925);
    address public constant dai =
        address(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    VaultParameters public constant vaultParameters =
        VaultParameters(0xB46F8CF42e504Efe8BEf895f848741daA55e9f1D);
    VaultManagerParameters public constant vaultManagerParameters =
        VaultManagerParameters(0x203153522B9EAef4aE17c6e99851EE7b2F7D312E);
    VaultManagerStandard public constant standard =
        VaultManagerStandard(0x3e7f1d12a7893Ba8eb9478b779b648DA2bD38ae6);
    VaultManagerKeep3rMainAsset public constant cdp =
        VaultManagerKeep3rMainAsset(0x211A6d4D4F49c0C5814451589d6378FdA614Adb9);
    UVault public constant uVault =
        UVault(0xb1cFF81b9305166ff1EFc49A129ad2AfCd7BCf19);

    ChainlinkedOracleSimple public immutable oracle;
    yVault public yvusdp;

    Uni public constant uniswap =
        Uni(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    Uni public constant sushiswap =
        Uni(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    uint256 public constant DENOMINATOR = 100;

    uint256 public c;
    uint256 public c_safe;
    uint256 public buffer;
    uint256 public cdpId;
    Uni public dex;

    constructor(address _vault, address _usdp_vault)
        public
        BaseStrategy(_vault)
    {
        minReportDelay = 1 days;
        maxReportDelay = 3 days;
        profitFactor = 1000;

        yvusdp = yVault(_usdp_vault);
        oracle = ChainlinkedOracleSimple(cdp.oracle());
        c = vaultManagerParameters.liquidationRatio(address(want)).sub(16);
        c_safe = vaultManagerParameters.liquidationRatio(address(want)).mul(2);
        buffer = 5;
        dex = sushiswap;
        _approveAll();
    }

    function _approveAll() internal {
        want.approve(address(uVault), type(uint256).max);
        IERC20(usdp).approve(address(yvusdp), type(uint256).max);
        IERC20(usdp).approve(address(uniswap), type(uint256).max);
        IERC20(usdp).approve(address(sushiswap), type(uint256).max);
        // TODO: Let's discuss this approval
        IERC20(usdp).approve(
            address(vaultParameters.foundation()),
            type(uint256).max
        );
    }

    function name() external view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "Unit",
                    IERC20Metadata(address(want)).symbol(),
                    "UDSPDelegate"
                )
            );
    }

    function setBorrowCollateralizationRatio(uint256 _c)
        external
        onlyAuthorized
    {
        c = _c;
    }

    function setWithdrawCollateralizationRatio(uint256 _c_safe)
        external
        onlyAuthorized
    {
        c_safe = _c_safe;
    }

    function setBuffer(uint256 _buffer) external onlyAuthorized {
        buffer = _buffer;
    }

    function switchDex(bool isUniswap) external onlyAuthorized {
        if (isUniswap) dex = uniswap;
        else dex = sushiswap;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfCdp());
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfCdp() public view returns (uint256) {
        return uVault.collaterals(address(want), address(this));
    }

    function delegatedAssets() external view override returns (uint256) {
        // TODO
        return estimatedTotalAssets();
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _profit = want.balanceOf(address(this));
        uint256 v = getUnderlying();
        uint256 d = getTotalDebtAmount();
        if (v > d) {
            _withdrawUnderlying(v.sub(d));
            _swap(IERC20(usdp).balanceOf(address(this)));

            _profit = want.balanceOf(address(this));
        }

        if (_debtOutstanding > 0) {
            (_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        _deposit();

        if (shouldDraw()) draw();
        else if (shouldRepay()) repay();
    }

    function _deposit() internal {
        uint256 _token = want.balanceOf(address(this));
        if (_token == 0) return;

        uint256 p = _getPrice();
        uint256 _draw = _token.mul(p).mul(c).div(DENOMINATOR).div(1e18);
        _draw = _adjustDrawAmount(_draw);

        // first time
        // Since we don't have a cdp yet, _adjustDrawAmount will return 0
        // We need to mine something so we mine 1 wei and return
        if (_draw == 0 && getTotalDebtAmount() == 0) {
            cdp.spawn(address(want), _token, 0, 1);
            yvusdp.deposit();
            return;
        }

        if (_draw == 0) {
            standard.deposit(address(want), _token);
            return;
        }

        cdp.depositAndBorrow(address(want), _token, 0, _draw);
        if (IERC20(usdp).balanceOf(address(this)) > 0) {
            yvusdp.deposit();
        }
    }

    function _getPrice() internal view returns (uint256 p) {
        uint256 _unit = uint256(10)**IERC20Metadata(address(want)).decimals();
        uint256 price_q112 = oracle.assetToUsd(address(want), _unit);
        p = price_q112.div(cdp.Q112()).div(_unit);
    }

    function _adjustDrawAmount(uint256 amount)
        internal
        view
        returns (uint256 _available)
    {
        // main collateral value of the position in USD
        uint256 mainUsdValue_q112 =
            oracle.assetToUsd(
                address(want),
                uVault.collaterals(address(want), address(this))
            );
        // COL token value of the position in USD
        uint256 colUsdValue_q112 =
            oracle.assetToUsd(
                uVault.col(),
                uVault.colToken(address(want), address(this))
            );
        uint256 _canSafeDraw =
            _ensureCollateralization(
                address(want),
                address(this),
                mainUsdValue_q112,
                colUsdValue_q112
            );

        uint256 limit = vaultParameters.tokenDebtLimit(address(want));
        uint256 debt = uVault.tokenDebts(address(want));
        uint256 _remaining = limit > debt ? limit - debt : 0;

        _available = Math.min(_canSafeDraw, _remaining);
        _available = Math.min(amount, _available);
    }

    // ensures that borrowed value is in desired range
    function _ensureCollateralization(
        address asset,
        address user,
        uint256 mainUsdValue_q112,
        uint256 colUsdValue_q112
    ) internal view returns (uint256) {
        uint256 mainUsdUtilized_q112;
        uint256 colUsdUtilized_q112;

        uint256 minColPercent = vaultManagerParameters.minColPercent(asset);
        if (minColPercent != 0) {
            // main limit by COL
            uint256 mainUsdLimit_q112 =
                colUsdValue_q112.mul(100 - minColPercent).div(minColPercent);
            mainUsdUtilized_q112 = Math.min(
                mainUsdValue_q112,
                mainUsdLimit_q112
            );
        } else {
            mainUsdUtilized_q112 = mainUsdValue_q112;
        }

        uint256 maxColPercent = vaultManagerParameters.maxColPercent(asset);
        if (maxColPercent < 100) {
            // COL limit by main
            uint256 colUsdLimit_q112 =
                mainUsdValue_q112.mul(maxColPercent).div(100 - maxColPercent);
            colUsdUtilized_q112 = Math.min(colUsdValue_q112, colUsdLimit_q112);
        } else {
            colUsdUtilized_q112 = colUsdValue_q112;
        }

        // USD limit of the position
        uint256 usdLimit =
            SafeMath.add(
                mainUsdUtilized_q112.mul(
                    vaultManagerParameters.initialCollateralRatio(asset)
                ),
                colUsdUtilized_q112.mul(
                    vaultManagerParameters.initialCollateralRatio(uVault.col())
                )
            );
        usdLimit = usdLimit.div(cdp.Q112()).div(100);
        // revert if collateralization is not enough
        require(
            uVault.getTotalDebt(asset, user) <= usdLimit,
            "Unit Protocol: UNDERCOLLATERALIZED"
        );
        return usdLimit - uVault.getTotalDebt(asset, user);
    }

    function shouldDraw() public view returns (bool) {
        // buffer to avoid deposit/rebalance loops
        bool _drawable =
            getCdpRatio(0) < c.mul(DENOMINATOR.sub(buffer)).div(DENOMINATOR);
        return _drawable && _adjustDrawAmount(drawAmount()) > 0;
    }

    function drawAmount() public view returns (uint256) {
        // amount to draw to reach target ratio not accounting for debt ceiling
        uint256 _safe = c;
        uint256 _current = getCdpRatio(0);
        if (_current < _safe) {
            uint256 diff = _safe.sub(_current);
            return balanceOfCdp().mul(_getPrice()).mul(diff).div(DENOMINATOR);
        }
        return 0;
    }

    function draw() internal {
        uint256 _drawD = _adjustDrawAmount(drawAmount());
        if (_drawD > 0) {
            cdp.depositAndBorrow(address(want), 0, 0, _drawD);
            yvusdp.deposit();
        }
    }

    function shouldRepay() public view returns (bool) {
        // buffer to avoid deposit/rebalance loops
        return getCdpRatio(0) > c.mul(DENOMINATOR.add(buffer)).div(DENOMINATOR);
    }

    function repayAmount() public view returns (uint256) {
        uint256 _safe = c;
        uint256 _current = getCdpRatio(0);
        if (_current > _safe) {
            uint256 diff = _current.sub(_safe);
            return balanceOfCdp().mul(_getPrice()).mul(diff).div(DENOMINATOR);
        }
        return 0;
    }

    function repay() internal {
        uint256 _free = repayAmount();
        if (_free > 0) {
            _withdrawUnderlying(_free);
            standard.repay(
                address(want),
                IERC20(usdp).balanceOf(address(this))
            );
        }
    }

    event LP(uint256 amount, uint256 balance);

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        if (_amountNeeded == 0) return (0, 0);

        if (getTotalDebtAmount() != 0 && getCdpRatio(_amountNeeded) < c_safe) {
            uint256 p = _getPrice();
            _withdrawUnderlying(_amountNeeded.mul(p));
        }

        emit LP(_amountNeeded, IERC20(usdp).balanceOf(address(this)));
        cdp.withdrawAndRepay(
            address(want),
            _amountNeeded,
            0,
            IERC20(usdp).balanceOf(address(this))
        );

        emit LP(_amountNeeded, balanceOfWant());
        _liquidatedAmount = _amountNeeded;
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    function tendTrigger(uint256 callCost) public view override returns (bool) {
        if (balanceOfCdp() == 0) return false;
        else
            return
                shouldRepay() ||
                (shouldDraw() &&
                    _adjustDrawAmount(drawAmount()) >
                    callCost.mul(_getPrice()).mul(profitFactor).div(1e18));
    }

    function prepareMigration(address _newStrategy) internal override {
        yvusdp.withdraw();
        standard.repayAllAndWithdraw(
            address(want),
            IERC20(usdp).balanceOf(address(this))
        );
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](2);
        protected[0] = address(yvusdp);
        protected[1] = usdp;
        return protected;
    }

    function forceRebalance(uint256 _amount) external onlyAuthorized {
        if (_amount > 0) _withdrawUnderlying(_amount);
        standard.repay(address(want), IERC20(usdp).balanceOf(address(this)));
    }

    function getTotalDebtAmount() public view returns (uint256) {
        return uVault.getTotalDebt(address(want), address(this));
    }

    function getCdpRatio(uint256 amount) public view returns (uint256) {
        uint256 numerator = getTotalDebtAmount();
        if (numerator == 0) return 0;

        uint256 _balance = balanceOfCdp();
        if (_balance < amount) return type(uint256).max;
        else _balance = _balance.sub(amount);

        if (_balance == 0) {
            return 0;
        }

        // main collateral value of the position in USD
        uint256 mainUsdValue_q112 = oracle.assetToUsd(address(want), _balance);
        return numerator.mul(1e2).mul(cdp.Q112()).div(mainUsdValue_q112);
    }

    function getUnderlying() public view returns (uint256) {
        return
            IERC20(address(yvusdp))
                .balanceOf(address(this))
                .mul(yvusdp.pricePerShare())
                .div(1e18);
    }

    function _withdrawUnderlying(uint256 _amount) internal returns (uint256) {
        uint256 _shares = _amount.mul(1e18).div(yvusdp.pricePerShare());

        uint256 _reserve = IERC20(address(yvusdp)).balanceOf(address(this));
        if (_shares > _reserve) _shares = _reserve;

        uint256 _before = IERC20(usdp).balanceOf(address(this));
        yvusdp.withdraw(_shares);
        uint256 _after = IERC20(usdp).balanceOf(address(this));
        return _after.sub(_before);
    }

    function _swap(uint256 _amountIn) internal {
        // TODO
        address[] memory path = new address[](3);
        path[0] = usdp;
        path[1] = weth;
        path[2] = address(want);

        dex.swapExactTokensForTokens(_amountIn, 0, path, address(this), now);
    }
}
