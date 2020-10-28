// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.0;

interface LiquifiCallee {
    // availableBalance contains 128 bits of availableBalanceA and 128 bits of availableBalanceB
    // delayedSwapsIncome contains 128 bits of delayedSwapsIncomeA and 128 bits of delayedSwapsIncomeB
    function onLiquifiSwap(bytes calldata data, address sender, uint availableBalance, uint delayedSwapsIncome, uint instantNotFee) external;
}