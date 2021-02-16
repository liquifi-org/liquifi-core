// SPDX-License-Identifier: GPL-3.0
pragma solidity >= 0.7.0 <0.8.0;

import { LiquifiLiquidityPool } from "../LiquifiLiquidityPool.sol";
import { ERC20 } from "../interfaces/ERC20.sol";
import { Liquifi } from "../libraries/Liquifi.sol";
import { PoolFactory } from "../interfaces/PoolFactory.sol";

contract TestLiquidityPool is LiquifiLiquidityPool {
    Liquifi.PoolState public savedState;
    string public override constant symbol = 'Liquifi Test Pool Token';

    constructor(address tokenAAddress, address tokenBAddress, address _governanceRouter) 
        LiquifiLiquidityPool(tokenAAddress, tokenBAddress, false, _governanceRouter) public {
        savedState.notFee = 997; // fee = 0.3%
        savedState.packed = (
            /*instantSwapFee*/uint96(3) << 88 | // 0.03%
            /*fee*/uint96(3) << 80 | // 0.03%
            /*maxPeriod*/uint96(1 hours) << 40 |
            /*desiredMaxHistory*/uint96(100) << 24
        );
    }

    function totalSupply() external override view returns (uint) {
        return uint128(savedBalances.rootKLastTotalSupply);
    }

    function actualizeBalances(Liquifi.ErrorArg) internal override(LiquifiLiquidityPool) view 
        returns (Liquifi.PoolBalances memory _balances, Liquifi.PoolState memory _state, uint availableBalanceA, uint availableBalanceB) {
        _state=savedState;
        _balances=savedBalances;
        availableBalanceA = _balances.totalBalanceA;
        availableBalanceB = _balances.totalBalanceB;
    }
    
    function changedBalances(BreakReason, Liquifi.PoolBalances memory _balances, Liquifi.PoolState memory _state, uint) internal override(LiquifiLiquidityPool) {
        savedBalances = _balances;
        savedState = _state;
    }
}