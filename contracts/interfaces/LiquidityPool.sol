// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import {ERC20} from "./ERC20.sol";
import {GovernanceRouter} from "./GovernanceRouter.sol";

interface LiquidityPool is ERC20 {
    enum MintReason {DEPOSIT, PROTOCOL_FEE, INITIAL_LIQUIDITY}
    event Mint(address indexed to, uint256 value, MintReason reason);

    // ORDER_CLOSED reasons are all odd, other reasons are even
    // it allows to check ORDER_CLOSED reasons as (reason & ORDER_CLOSED) != 0
    enum BreakReason {
        NONE,
        ORDER_CLOSED,
        ORDER_ADDED,
        ORDER_CLOSED_BY_STOP_LOSS,
        SWAP,
        ORDER_CLOSED_BY_REQUEST,
        MINT,
        ORDER_CLOSED_BY_HISTORY_LIMIT,
        BURN,
        ORDER_CLOSED_BY_GOVERNOR
    }

    function poolBalances()
        external
        view
        returns (
            uint256 balanceALocked,
            uint256 poolFlowSpeedA, // flow speed: (amountAIn * 2^32)/second
            uint256 balanceBLocked,
            uint256 poolFlowSpeedB, // flow speed: (amountBIn * 2^32)/second
            uint256 totalBalanceA,
            uint256 totalBalanceB,
            uint256 delayedSwapsIncome,
            uint256 rootKLastTotalSupply
        );

    function governanceRouter() external returns (GovernanceRouter);

    function minimumLiquidity() external returns (uint256);

    function aIsWETH() external returns (bool);

    function mint(address to) external returns (uint256 liquidityOut);

    function burn(address to, bool extractETH) external returns (uint256 amountAOut, uint256 amountBOut);

    function swap(
        address to,
        bool extractETH,
        uint256 amountAOut,
        uint256 amountBOut,
        bytes calldata externalData
    ) external returns (uint256 amountAIn, uint256 amountBIn);

    function tokenA() external view returns (ERC20);

    function tokenB() external view returns (ERC20);
}
