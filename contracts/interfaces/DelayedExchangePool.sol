// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import {LiquidityPool} from "./LiquidityPool.sol";

interface DelayedExchangePool is LiquidityPool {
    event FlowBreakEvent(
        address sender,
        // total balance contains 128 bit of totalBalanceA and 128 bit of totalBalanceB
        uint256 totalBalance,
        // contains 128 bits of rootKLast and 128 bits of totalSupply
        uint256 rootKLastTotalSupply,
        uint256 indexed orderId,
        // breakHash is computed over all fields below

        bytes32 lastBreakHash,
        // availableBalance consists of 128 bits of availableBalanceA and 128 bits of availableBalanceB
        uint256 availableBalance,
        // flowSpeed consists of 144 bits of poolFlowSpeedA and 112 higher bits of poolFlowSpeedB
        uint256 flowSpeed,
        // others consists of 32 lower bits of poolFlowSpeedB, 16 bit of notFee, 64 bit of time, 64 bit of orderId, 76 higher bits of packed and 4 bit of reason (BreakReason)
        uint256 others
    );

    event OrderClaimedEvent(uint256 indexed orderId, address to);
    event OperatingInInvalidState(uint256 location, uint256 invalidStateReason);
    event GovernanceApplied(uint256 packedGovernance);

    function addOrder(
        address owner,
        uint256 orderFlags,
        uint256 prevByStopLoss,
        uint256 prevByTimeout,
        uint256 stopLossAmount,
        uint256 period
    ) external returns (uint256 id);

    // availableBalance contains 128 bits of availableBalanceA and 128 bits of availableBalanceB
    // delayedSwapsIncome contains 128 bits of delayedSwapsIncomeA and 128 bits of delayedSwapsIncomeB
    function processDelayedOrders()
        external
        returns (
            uint256 availableBalance,
            uint256 delayedSwapsIncome,
            uint256 packed
        );

    function claimOrder(
        bytes32 previousBreakHash,
        // see LiquifyPoolRegister.claimOrder for breaks list details
        uint256[] calldata breaksHistory
    )
        external
        returns (
            address owner,
            uint256 amountAOut,
            uint256 amountBOut
        );

    function applyGovernance(uint256 packedGovernanceFields) external;

    function sync() external;

    function closeOrder(uint256 id) external;

    function poolQueue()
        external
        view
        returns (
            uint256 firstByTokenAStopLoss,
            uint256 lastByTokenAStopLoss, // linked list of orders sorted by (amountAIn/stopLossAmount) ascending
            uint256 firstByTokenBStopLoss,
            uint256 lastByTokenBStopLoss, // linked list of orders sorted by (amountBIn/stopLossAmount) ascending
            uint256 firstByTimeout,
            uint256 lastByTimeout // linked list of orders sorted by timeouts ascending
        );

    function lastBreakHash() external view returns (bytes32);

    function poolState()
        external
        view
        returns (
            bytes32 _prevBlockBreakHash,
            uint256 packed, // see Liquifi.PoolState for details
            uint256 notFee,
            uint256 lastBalanceUpdateTime,
            uint256 nextBreakTime,
            uint256 maxHistory,
            uint256 ordersToClaimCount,
            uint256 breaksCount
        );

    function findOrder(uint256 orderId)
        external
        view
        returns (
            uint256 nextByTimeout,
            uint256 prevByTimeout,
            uint256 nextByStopLoss,
            uint256 prevByStopLoss,
            uint256 stopLossAmount,
            uint256 amountIn,
            uint256 period,
            address owner,
            uint256 timeout,
            uint256 flags
        );
}
