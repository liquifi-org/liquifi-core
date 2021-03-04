// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

interface ActivityReporter {
    event Deposit(address indexed user, address indexed pool, uint256 amount);
    event Withdraw(address indexed user, address indexed pool, uint256 amount);
    event LiquidityETHPriceChanged(address indexed pool);

    function liquidityEthPriceChanged(
        uint256 effectiveTime,
        uint256 availableBalanceEth,
        uint256 totalSupply
    ) external;

    function deposit(address pool, uint128 amount) external;

    function withdraw(address pool, uint128 amount) external;
}
