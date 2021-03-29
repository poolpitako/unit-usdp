// SPDX-License-Identifier: bsl-1.1

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface VaultParameters {
    // map token to stability fee percentage; 3 decimals
    function stabilityFee(address) external view returns (uint256);

    // map token to liquidation fee percentage, 0 decimals
    function liquidationFee(address) external view returns (uint256);

    // map token to USDP mint limit
    function tokenDebtLimit(address) external view returns (uint256);

    // permissions to modify the Vault
    function canModifyVault(address) external view returns (bool);

    // managers
    function isManager(address) external view returns (bool);

    // enabled oracle types
    function isOracleTypeEnabled(uint256, address) external view returns (bool);

    // address of the Vault
    function vault() external view returns (address payable);
}

interface VaultManagerParameters {
    // determines the minimum percentage of COL token part in collateral, 0 decimals
    function minColPercent(address) external view returns (uint256);

    // determines the maximum percentage of COL token part in collateral, 0 decimals
    function maxColPercent(address) external view returns (uint256);

    // map token to initial collateralization ratio; 0 decimals
    function initialCollateralRatio(address) external view returns (uint256);

    // map token to liquidation ratio; 0 decimals
    function liquidationRatio(address) external view returns (uint256);

    // map token to liquidation discount; 3 decimals
    function liquidationDiscount(address) external view returns (uint256);

    // map token to devaluation period in blocks
    function devaluationPeriod(address) external view returns (uint256);
}

/**
 * @title Vault
 * @author Unit Protocol: Ivan Zakharov (@34x4p08)
 * @notice Vault is the core of Unit Protocol USDP Stablecoin system
 * @notice Vault stores and manages collateral funds of all positions and counts debts
 * @notice Only Vault can manage supply of USDP token
 * @notice Vault will not be changed/upgraded after initial deployment for the current stablecoin version
 **/
interface UVault {
    function weth() external view returns (address payable);

    function col() external view returns (address);

    function usdp() external view returns (address);

    // collaterals whitelist
    function collaterals(address, address) external view returns (uint256);

    // COL token collaterals
    function colToken(address, address) external view returns (uint256);

    // user debts
    function debts(address, address) external view returns (uint256);

    // block number of liquidation trigger
    function liquidationBlock(address, address) external view returns (uint256);

    // initial price of collateral
    function liquidationPrice(address, address) external view returns (uint256);

    // debts of tokens
    function tokenDebts(address) external view returns (uint256);

    // stability fee pinned to each position
    function stabilityFee(address, address) external view returns (uint256);

    // liquidation fee pinned to each position, 0 decimals
    function liquidationFee(address, address) external view returns (uint256);

    // type of using oracle pinned for each position
    function oracleType(address, address) external view returns (uint256);

    // timestamp of the last update
    function lastUpdate(address, address) external view returns (uint256);

    /**
     * @dev Calculates the total amount of position's debt based on elapsed time
     * @param asset The address of the main collateral token
     * @param user The address of a position's owner
     * @return user debt of a position plus accumulated fee
     **/
    function getTotalDebt(address asset, address user)
        external
        view
        returns (uint256);

    /**
     * @dev Calculates the amount of fee based on elapsed time and repayment amount
     * @param asset The address of the main collateral token
     * @param user The address of a position's owner
     * @param amount The repayment amount
     * @return fee amount
     **/
    function calculateFee(
        address asset,
        address user,
        uint256 amount
    ) external view returns (uint256);
}

interface VaultManagerKeep3rMainAsset {
    function vault() external view returns (address);

    function vaultManagerParameters() external view returns (address);

    function oracle() external view returns (address);

    function ORACLE_TYPE() external view returns (uint256);

    function Q112() external view returns (uint256);

    /**
     * @notice Cannot be used for already spawned positions
     * @notice Token using as main collateral must be whitelisted
     * @notice Depositing tokens must be pre-approved to vault address
     * @notice position actually considered as spawned only when usdpAmount > 0
     * @dev Spawns new positions
     * @param asset The address of token using as main collateral
     * @param mainAmount The amount of main collateral to deposit
     * @param colAmount The amount of COL token to deposit
     * @param usdpAmount The amount of USDP token to borrow
     **/
    function spawn(
        address asset,
        uint256 mainAmount,
        uint256 colAmount,
        uint256 usdpAmount
    ) external;

    /**
     * @notice Cannot be used for already spawned positions
     * @notice WETH must be whitelisted as collateral
     * @notice COL must be pre-approved to vault address
     * @notice position actually considered as spawned only when usdpAmount > 0
     * @dev Spawns new positions using ETH
     * @param colAmount The amount of COL token to deposit
     * @param usdpAmount The amount of USDP token to borrow
     **/
    function spawn_Eth(uint256 colAmount, uint256 usdpAmount) external payable;

    /**
     * @notice Position should be spawned (USDP borrowed from position) to call this method
     * @notice Depositing tokens must be pre-approved to vault address
     * @notice Token using as main collateral must be whitelisted
     * @dev Deposits collaterals and borrows USDP to spawned positions simultaneously
     * @param asset The address of token using as main collateral
     * @param mainAmount The amount of main collateral to deposit
     * @param colAmount The amount of COL token to deposit
     * @param usdpAmount The amount of USDP token to borrow
     **/
    function depositAndBorrow(
        address asset,
        uint256 mainAmount,
        uint256 colAmount,
        uint256 usdpAmount
    ) external;

    /**
     * @notice Position should be spawned (USDP borrowed from position) to call this method
     * @notice Depositing tokens must be pre-approved to vault address
     * @notice Token using as main collateral must be whitelisted
     * @dev Deposits collaterals and borrows USDP to spawned positions simultaneously
     * @param colAmount The amount of COL token to deposit
     * @param usdpAmount The amount of USDP token to borrow
     **/
    function depositAndBorrow_Eth(uint256 colAmount, uint256 usdpAmount)
        external
        payable;

    /**
     * @notice Tx sender must have a sufficient USDP balance to pay the debt
     * @dev Withdraws collateral and repays specified amount of debt simultaneously
     * @param asset The address of token using as main collateral
     * @param mainAmount The amount of main collateral token to withdraw
     * @param colAmount The amount of COL token to withdraw
     * @param usdpAmount The amount of USDP token to repay
     **/
    function withdrawAndRepay(
        address asset,
        uint256 mainAmount,
        uint256 colAmount,
        uint256 usdpAmount
    ) external;

    /**
     * @notice Tx sender must have a sufficient USDP balance to pay the debt
     * @dev Withdraws collateral and repays specified amount of debt simultaneously converting WETH to ETH
     * @param ethAmount The amount of ETH to withdraw
     * @param colAmount The amount of COL token to withdraw
     * @param usdpAmount The amount of USDP token to repay
     **/
    function withdrawAndRepay_Eth(
        uint256 ethAmount,
        uint256 colAmount,
        uint256 usdpAmount
    ) external;

    /**
     * @notice Tx sender must have a sufficient USDP and COL balances and allowances to pay the debt
     * @dev Repays specified amount of debt paying fee in COL
     * @param asset The address of token using as main collateral
     * @param usdpAmount The amount of USDP token to repay
     **/
    function repayUsingCol(address asset, uint256 usdpAmount) external;

    /**
     * @notice Tx sender must have a sufficient USDP and COL balances and allowances to pay the debt
     * @dev Withdraws collateral
     * @dev Repays specified amount of debt paying fee in COL
     * @param asset The address of token using as main collateral
     * @param mainAmount The amount of main collateral token to withdraw
     * @param colAmount The amount of COL token to withdraw
     * @param usdpAmount The amount of USDP token to repay
     **/
    function withdrawAndRepayUsingCol(
        address asset,
        uint256 mainAmount,
        uint256 colAmount,
        uint256 usdpAmount
    ) external;

    /**
     * @notice Tx sender must have a sufficient USDP and COL balances to pay the debt
     * @dev Withdraws collateral converting WETH to ETH
     * @dev Repays specified amount of debt paying fee in COL
     * @param ethAmount The amount of ETH to withdraw
     * @param colAmount The amount of COL token to withdraw
     * @param usdpAmount The amount of USDP token to repay
     **/
    function withdrawAndRepayUsingCol_Eth(
        uint256 ethAmount,
        uint256 colAmount,
        uint256 usdpAmount
    ) external;
}

interface VaultManagerStandard {
    /**
     * @notice Depositing token must be pre-approved to vault address
     * @notice Token using as main collateral must be whitelisted
     * @dev Deposits collaterals
     * @param asset The address of token using as main collateral
     * @param mainAmount The amount of main collateral to deposit
     **/
    function deposit(address asset, uint256 mainAmount) external;

    /**
     * @notice Token using as main collateral must be whitelisted
     * @dev Deposits collaterals converting ETH to WETH
     **/
    function deposit_Eth() external payable;

    /**
     * @notice Tx sender must have a sufficient USDP balance to pay the debt
     * @dev Repays specified amount of debt
     * @param asset The address of token using as main collateral
     * @param usdpAmount The amount of USDP token to repay
     **/
    function repay(address asset, uint256 usdpAmount) external;

    /**
     * @notice Tx sender must have a sufficient USDP balance to pay the debt
     * @notice USDP approval is NOT needed
     * @dev Repays total debt and withdraws collaterals
     * @param asset The address of token using as main collateral
     * @param mainAmount The amount of main collateral token to withdraw
     **/
    function repayAllAndWithdraw(address asset, uint256 mainAmount) external;

    /**
     * @notice Tx sender must have a sufficient USDP balance to pay the debt
     * @notice USDP approval is NOT needed
     * @dev Repays total debt and withdraws collaterals
     * @param ethAmount The ETH amount to withdraw
     **/
    function repayAllAndWithdraw_Eth(uint256 ethAmount) external;
}

interface ChainlinkedOracleSimple {
    function WETH() external view returns (address);

    function Q112() external view returns (uint256);

    function ETH_USD_DENOMINATOR() external view returns (uint256);

    // returns ordinary value
    function ethToUsd(uint256 ethAmount) external view returns (uint256);

    // returns Q112-encoded value
    function assetToEth(address asset, uint256 amount)
        external
        view
        returns (uint256);

    function assetToUsd(address asset, uint256 amount)
        external
        view
        returns (uint256);
}
