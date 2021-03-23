// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
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
        return (a / 2) + (b / 2) + ((a % 2 + b % 2) / 2);
    }
}


contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // want = address(0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e)
    address constant public weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address constant public usdp = address(0x1456688345527bE1f37E9e627DA0837D6f08C925);
    address constant public dai = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    VaultParameters public constant vaultParameters = VaultParameters(0xB46F8CF42e504Efe8BEf895f848741daA55e9f1D);
    VaultManagerParameters public constant vaultManagerParameters = VaultManagerParameters(0x203153522B9EAef4aE17c6e99851EE7b2F7D312E);
    VaultManagerStandard public constant standard = VaultManagerStandard(0x3e7f1d12a7893Ba8eb9478b779b648DA2bD38ae6);
    VaultManagerKeep3rMainAsset public constant cdp = VaultManagerKeep3rMainAsset(0x211A6d4D4F49c0C5814451589d6378FdA614Adb9);
    UVault public constant uVault = UVault(0xb1cFF81b9305166ff1EFc49A129ad2AfCd7BCf19);
    ChainlinkedOracleSimple public immutable oracle;

    yVault public constant yvusdp = yVault(0x0000000000000000000000000000000000000000); // TODO
    Uni constant public uniswap = Uni(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    Uni constant public sushiswap = Uni(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    uint constant public DENOMINATOR = 100;

    uint public c;
    uint public c_safe;
    uint public buffer;
    uint public cdpId;
    Uni public dex;

    constructor(address _vault) public BaseStrategy(_vault) {
        minReportDelay = 1 days;
        maxReportDelay = 3 days;
        profitFactor = 1000;

        oracle = ChainlinkedOracleSimple(cdp.oracle());
        c = vaultManagerParameters.liquidationRatio(address(want)).sub(16);
        c_safe = vaultManagerParameters.liquidationRatio(address(want)).mul(2);
        buffer = 5;
        dex = sushiswap;
        _approveAll();
    }

    function _approveAll() internal {
        want.approve(address(uVault), uint(-1));
        IERC20(usdp).approve(address(yvusdp), uint(-1));
        IERC20(usdp).approve(address(uniswap), uint(-1));
        IERC20(usdp).approve(address(sushiswap), uint(-1));
    }

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("Unit", IERC20Metadata(address(want)).symbol(), "UDSPDelegate"));
    }

    function setBorrowCollateralizationRatio(uint _c) external onlyAuthorized {
        c = _c;
    }

    function setWithdrawCollateralizationRatio(uint _c_safe) external onlyAuthorized {
        c_safe = _c_safe;
    }

    function setBuffer(uint _buffer) external onlyAuthorized {
        buffer = _buffer;
    }

    function switchDex(bool isUniswap) external onlyAuthorized {
        if (isUniswap) dex = uniswap;
        else dex = sushiswap;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfCdp());
    }

    function balanceOfWant() public view returns (uint) {
        return want.balanceOf(address(this));
    }

    function balanceOfCdp() public view returns (uint) {
        return uVault.collaterals(address(want), address(this));
    }

    function delegatedAssets() external override view returns (uint256) {
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
        uint v = getUnderlying();
        uint d = getTotalDebtAmount();
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
        uint _token = want.balanceOf(address(this));
        if (_token == 0) return;

        uint p = _getPrice();
        uint _draw = _token.mul(p).mul(c).div(DENOMINATOR).div(1e18);
        _draw = _adjustDrawAmount(_draw);
        if (_draw == 0) {
            standard.deposit(address(want), _token);
            return;
        }

        // first time
        if (getTotalDebtAmount() == 0) {
            cdp.spawn(address(want), _token, 0, _draw);
            yvusdp.deposit();
            return;
        }

        cdp.depositAndBorrow(address(want), _token, 0, _draw);
        yvusdp.deposit();
    }

    function _getPrice() internal view returns (uint p) {
        uint _unit = uint(10) ** IERC20Metadata(address(want)).decimals();
        uint price_q112 = oracle.assetToUsd(address(want), _unit);
        p = price_q112.div(cdp.Q112()).div(_unit);
    }

    function _adjustDrawAmount(uint amount) internal view returns (uint _available) {
        // main collateral value of the position in USD
        uint mainUsdValue_q112 = oracle.assetToUsd(address(want), uVault.collaterals(address(want), address(this)));
        // COL token value of the position in USD
        uint colUsdValue_q112 = oracle.assetToUsd(uVault.col(), uVault.colToken(address(want), address(this)));
        uint _canSafeDraw = _ensureCollateralization(address(want), address(this), mainUsdValue_q112, colUsdValue_q112);

        uint limit = vaultParameters.tokenDebtLimit(address(want));
        uint debt = uVault.tokenDebts(address(want));
        uint _remaining = limit > debt ? limit - debt: 0;

        _available = Math.min(_canSafeDraw, _remaining);
        _available = Math.min(amount, _available);
    }

    // ensures that borrowed value is in desired range
    function _ensureCollateralization(
        address asset,
        address user,
        uint mainUsdValue_q112,
        uint colUsdValue_q112
    )
    internal
    view
    returns (uint)
    {
        uint mainUsdUtilized_q112;
        uint colUsdUtilized_q112;

        uint minColPercent = vaultManagerParameters.minColPercent(asset);
        if (minColPercent != 0) {
            // main limit by COL
            uint mainUsdLimit_q112 = colUsdValue_q112.mul(100 - minColPercent).div(minColPercent);
            mainUsdUtilized_q112 = Math.min(mainUsdValue_q112, mainUsdLimit_q112);
        } else {
            mainUsdUtilized_q112 = mainUsdValue_q112;
        }

        uint maxColPercent = vaultManagerParameters.maxColPercent(asset);
        if (maxColPercent < 100) {
            // COL limit by main
            uint colUsdLimit_q112 = mainUsdValue_q112.mul(maxColPercent).div(100 - maxColPercent);
            colUsdUtilized_q112 = Math.min(colUsdValue_q112, colUsdLimit_q112);
        } else {
            colUsdUtilized_q112 = colUsdValue_q112;
        }

        // USD limit of the position
        uint usdLimit = SafeMath.add(
            mainUsdUtilized_q112.mul(vaultManagerParameters.initialCollateralRatio(asset)), 
            colUsdUtilized_q112.mul(vaultManagerParameters.initialCollateralRatio(uVault.col()))
        );
        usdLimit = usdLimit.div(cdp.Q112()).div(100);
        // revert if collateralization is not enough
        require(uVault.getTotalDebt(asset, user) <= usdLimit, "Unit Protocol: UNDERCOLLATERALIZED");
        return usdLimit - uVault.getTotalDebt(asset, user);
    }

    function shouldDraw() public view returns (bool) {
        // buffer to avoid deposit/rebalance loops
        bool _drawable = getCdpRatio(0) < c.mul(DENOMINATOR.sub(buffer)).div(DENOMINATOR);
        return _drawable && _adjustDrawAmount(drawAmount()) > 0;
    }

    function drawAmount() public view returns (uint) {
        // amount to draw to reach target ratio not accounting for debt ceiling
        uint _safe = c;
        uint _current = getCdpRatio(0);
        if (_current < _safe) {
            uint diff = _safe.sub(_current);
            return balanceOfCdp().mul(_getPrice()).mul(diff).div(DENOMINATOR);
        }
        return 0;
    }

    function draw() internal {
        uint _drawD = _adjustDrawAmount(drawAmount());
        if (_drawD > 0) {
            cdp.depositAndBorrow(address(want), 0, 0, _drawD);
            yvusdp.deposit();
        }
    }

    function shouldRepay() public view returns (bool) {
        // buffer to avoid deposit/rebalance loops
        return getCdpRatio(0) > c.mul(DENOMINATOR.add(buffer)).div(DENOMINATOR);
    }
    
    function repayAmount() public view returns (uint) {
        uint _safe = c;
        uint _current = getCdpRatio(0);
        if (_current > _safe) {
            uint diff = _current.sub(_safe);
            return balanceOfCdp().mul(_getPrice()).mul(diff).div(DENOMINATOR);
        }
        return 0;
    }
    
    function repay() internal {
        uint _free = repayAmount();
        if (_free > 0) {
            _withdrawUnderlying(_free);
            standard.repay(address(want), IERC20(usdp).balanceOf(address(this)));
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        if (_amountNeeded == 0) return (0, 0);
        if (getTotalDebtAmount() != 0 && 
            getCdpRatio(_amountNeeded) < c_safe) {
            uint p = _getPrice();
            _withdrawUnderlying(_amountNeeded.mul(p).div(1e18));
        }
        
        cdp.withdrawAndRepay(address(want), _amountNeeded, 0, IERC20(usdp).balanceOf(address(this)));
        _liquidatedAmount = _amountNeeded;
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    function tendTrigger(uint256 callCost) public override view returns (bool) {
        if (balanceOfCdp() == 0) return false;
        else return shouldRepay() || (shouldDraw() && _adjustDrawAmount(drawAmount()) > callCost.mul(_getPrice()).mul(profitFactor).div(1e18));
    }

    function prepareMigration(address _newStrategy) internal override {
        yvusdp.withdraw();
        standard.repayAllAndWithdraw(address(want), IERC20(usdp).balanceOf(address(this)));
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

    function forceRebalance(uint _amount) external onlyAuthorized {
        if (_amount > 0) _withdrawUnderlying(_amount);
        standard.repay(address(want), IERC20(usdp).balanceOf(address(this)));
    }

    function getTotalDebtAmount() public view returns (uint) {
        return uVault.getTotalDebt(address(want), address(this));
    }

    function getCdpRatio(uint amount) public view returns (uint) {
        uint numerator = getTotalDebtAmount();
        if (numerator == 0) return 0;

        uint _balance = balanceOfCdp();
        if (_balance < amount) return uint(-1); // _balance = 0;
        else _balance = _balance.sub(amount);

        // main collateral value of the position in USD
        uint mainUsdValue_q112 = oracle.assetToUsd(address(want), _balance);
        return numerator.mul(1e2).mul(cdp.Q112()).div(mainUsdValue_q112);
    }

    function getUnderlying() public view returns (uint) {
        return IERC20(address(yvusdp)).balanceOf(address(this))
                .mul(yvusdp.pricePerShare())
                .div(1e18);
    }

    function _withdrawUnderlying(uint _amount) internal returns (uint) {
        uint _shares = _amount
                        .mul(1e18)
                        .div(yvusdp.pricePerShare());

        uint _reserve = IERC20(address(yvusdp)).balanceOf(address(this));
        if (_shares > _reserve) _shares = _reserve;

        uint _before = IERC20(usdp).balanceOf(address(this));
        yvusdp.withdraw(_shares);
        uint _after = IERC20(usdp).balanceOf(address(this));
        return _after.sub(_before);
    }

    function _swap(uint _amountIn) internal {
        // TODO
        address[] memory path = new address[](3);
        path[0] = usdp;
        path[1] = weth;
        path[2] = address(want);

        dex.swapExactTokensForTokens(_amountIn, 0, path, address(this), now);
    }
}
