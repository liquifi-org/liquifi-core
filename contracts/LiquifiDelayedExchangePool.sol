// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import {Math} from "./libraries/Math.sol";
import {Liquifi} from "./libraries/Liquifi.sol";
//import { Debug } from "./libraries/Debug.sol";
import {ERC20} from "./interfaces/ERC20.sol";
import {LiquifiLiquidityPool} from "./LiquifiLiquidityPool.sol";
import {LiquidityPool} from "./interfaces/LiquidityPool.sol";
import {DelayedExchangePool} from "./interfaces/DelayedExchangePool.sol";
import {ActivityReporter} from "./interfaces/ActivityReporter.sol";
import {GovernanceRouter} from "./interfaces/GovernanceRouter.sol";

contract LiquifiDelayedExchangePool is LiquifiLiquidityPool, DelayedExchangePool {
    using Math for uint256;
    address public immutable activityReporter;

    mapping(uint256 => Liquifi.Order) private orders;
    Liquifi.PoolState private savedState;
    // BreakHash value computed last before current block
    // This field is useful for price oracles: it allows to calculate average price for arbitrary period in past
    // using FlowBreakEvent list provided by offchain code
    //
    // Also this field includes processing flag in the least valuable bit
    // So, only highest 255 bits should be used for hash validation
    // This word is always saved in enter()
    bytes32 private prevBlockBreakHash;
    uint256 private immutable poolIndex;

    constructor(
        address tokenAAddress,
        address tokenBAddress,
        bool _aIsWETH,
        address _governanceRouter,
        uint256 _index
    ) LiquifiLiquidityPool(tokenAAddress, tokenBAddress, _aIsWETH, _governanceRouter) {
        savedState.nextBreakTime = Liquifi.maxTime;
        poolIndex = _index;
        activityReporter = address(GovernanceRouter(_governanceRouter).activityReporter());
    }

    // use LPTXXXXXX symbols where XXXXXX is index in the pool factory
    // it takes much less bytecode than concatenation of tokens symbols
    function symbol() external view override returns (string memory _symbol) {
        bytes memory symbolBytes = "\x4c\x50\x54\x30\x30\x30\x30\x30\x30"; // LPT
        uint256 _index = poolIndex;
        uint256 pos = 8;
        while (pos > 2) {
            symbolBytes[pos--] = bytes1(uint8(48 + (_index % 10)));
            _index = _index / 10;
        }

        _symbol = string(symbolBytes);
    }

    function poolTime(Liquifi.PoolState memory _state) private view returns (uint256) {
        return
            Liquifi.checkFlag(_state, Liquifi.Flag.POOL_LOCKED)
                ? _state.lastBalanceUpdateTime
                : Liquifi.trimTime(block.timestamp);
    }

    function poolQueue()
        external
        view
        override
        returns (
            uint256 firstByTokenAStopLoss,
            uint256 lastByTokenAStopLoss, // linked list of orders sorted by (amountAIn/stopLossAmount) ascending
            uint256 firstByTokenBStopLoss,
            uint256 lastByTokenBStopLoss, // linked list of orders sorted by (amountBIn/stopLossAmount) ascending
            uint256 firstByTimeout,
            uint256 lastByTimeout // linked list of orders sorted by timeouts ascending
        )
    {
        firstByTokenAStopLoss = savedState.firstByTokenAStopLoss;
        lastByTokenAStopLoss = savedState.lastByTokenAStopLoss;
        firstByTokenBStopLoss = savedState.firstByTokenBStopLoss;
        lastByTokenBStopLoss = savedState.lastByTokenBStopLoss;

        firstByTimeout = savedState.firstByTimeout;
        lastByTimeout = savedState.lastByTimeout;
    }

    function lastBreakHash() external view override returns (bytes32) {
        return savedState.lastBreakHash;
    }

    function poolState()
        external
        view
        override
        returns (
            bytes32 _prevBlockBreakHash,
            uint256 packed, // see Liquifi.PoolState for details
            uint256 notFee,
            uint256 lastBalanceUpdateTime,
            uint256 nextBreakTime,
            uint256 maxHistory,
            uint256 ordersToClaimCount,
            uint256 breaksCount
        )
    {
        _prevBlockBreakHash = prevBlockBreakHash;

        packed = savedState.packed;
        notFee = savedState.notFee;

        lastBalanceUpdateTime = savedState.lastBalanceUpdateTime;
        nextBreakTime = savedState.nextBreakTime;
        maxHistory = savedState.maxHistory;
        ordersToClaimCount = savedState.ordersToClaimCount;
        breaksCount = savedState.breaksCount;
    }

    function findOrder(uint256 orderId)
        external
        view
        override
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
        )
    {
        Liquifi.Order storage order = orders[uint64(orderId)];
        nextByTimeout = order.nextByTimeout;
        prevByTimeout = order.prevByTimeout;
        nextByStopLoss = order.nextByStopLoss;
        prevByStopLoss = order.prevByStopLoss;

        stopLossAmount = order.stopLossAmount;
        amountIn = order.amountIn;
        period = order.period;

        owner = order.owner;
        timeout = order.timeout;
        flags = order.flags;
    }

    function totalSupply() external view override returns (uint256) {
        return uint128(savedBalances.rootKLastTotalSupply);
    }

    function applyGovernance(uint256 packedGovernanceFields) external override {
        (address governor, ) = governanceRouter.governance();
        Liquifi._require(msg.sender == governor, Liquifi.Error.Y_UNAUTHORIZED_SENDER, Liquifi.ErrorArg.S_BY_GOVERNANCE);
        savedState.packed = uint96(packedGovernanceFields);
        emit GovernanceApplied(packedGovernanceFields);
    }

    function addOrder(
        address owner,
        uint256 orderFlags,
        uint256 prevByStopLoss,
        uint256 prevByTimeout,
        uint256 stopLossAmount,
        uint256 period
    ) external override returns (uint256 id) {
        (Liquifi.PoolBalances memory _balances, Liquifi.PoolState memory _state, , ) =
            actualizeBalances(Liquifi.ErrorArg.E_IN_ADD_ORDER);
        {
            Liquifi.ErrorArg invalidState = Liquifi.checkInvalidState(_state);
            Liquifi._require(invalidState == Liquifi.ErrorArg.A_NONE, Liquifi.Error.J_INVALID_POOL_STATE, invalidState);
        }

        Liquifi._require(period > 0, Liquifi.Error.G_ZERO_PERIOD_VALUE, Liquifi.ErrorArg.E_IN_ADD_ORDER);
        Liquifi._require(stopLossAmount > 0, Liquifi.Error.F_ZERO_AMOUNT_VALUE, Liquifi.ErrorArg.D_STOP_LOSS_AMOUNT);

        uint256 amountIn;
        bool isTokenAIn = Liquifi.isTokenAIn(orderFlags);
        {
            // localize variables to reduce stack depth
            Liquifi.setFlag(_state, Liquifi.Flag.TOTALS_DIRTY);
            uint256 _totalBalance = isTokenAIn ? _balances.totalBalanceA : _balances.totalBalanceB;
            _balances.totalBalanceA = Liquifi.trimTotal(tokenA.balanceOf(address(this)), Liquifi.ErrorArg.O_TOKEN_A);
            _balances.totalBalanceB = Liquifi.trimTotal(tokenB.balanceOf(address(this)), Liquifi.ErrorArg.P_TOKEN_B);
            uint256 newTotalBalance = isTokenAIn ? _balances.totalBalanceA : _balances.totalBalanceB;

            Liquifi._require(
                newTotalBalance > _totalBalance,
                Liquifi.Error.F_ZERO_AMOUNT_VALUE,
                Liquifi.ErrorArg.B_IN_AMOUNT
            );

            amountIn = Liquifi.trimAmount(newTotalBalance.subWithClip(_totalBalance), Liquifi.ErrorArg.B_IN_AMOUNT);
            Liquifi._require(amountIn > 0, Liquifi.Error.F_ZERO_AMOUNT_VALUE, Liquifi.ErrorArg.B_IN_AMOUNT);

            if (isTokenAIn) {
                Liquifi.setFlag(_state, Liquifi.Flag.BALANCE_A_DIRTY);
                _balances.balanceALocked = Liquifi.trimAmount(
                    amountIn + _balances.balanceALocked,
                    Liquifi.ErrorArg.O_TOKEN_A
                );
                _balances.poolFlowSpeedA = Liquifi.trimFlowSpeed(
                    _balances.poolFlowSpeedA + (amountIn << 32) / period,
                    Liquifi.ErrorArg.O_TOKEN_A
                ); // multiply to 2^32 to keep precision
            } else {
                Liquifi.setFlag(_state, Liquifi.Flag.BALANCE_B_DIRTY);
                _balances.balanceBLocked = Liquifi.trimAmount(
                    amountIn + _balances.balanceBLocked,
                    Liquifi.ErrorArg.P_TOKEN_B
                );
                _balances.poolFlowSpeedB = Liquifi.trimFlowSpeed(
                    _balances.poolFlowSpeedB + (amountIn << 32) / period,
                    Liquifi.ErrorArg.P_TOKEN_B
                ); // multiply to 2^32 to keep precision
            }
        }

        (, , , uint256 maxPeriod, ) = Liquifi.unpackGovernance(_state);
        Liquifi._require(period <= maxPeriod, Liquifi.Error.D_TOO_BIG_PERIOD_VALUE, Liquifi.ErrorArg.E_IN_ADD_ORDER);
        Liquifi.trimAmount(stopLossAmount, Liquifi.ErrorArg.D_STOP_LOSS_AMOUNT); // check limits before usage

        id = saveOrder(
            _state,
            period,
            prevByTimeout,
            prevByStopLoss, // overflow only leads to position re-computing
            amountIn,
            stopLossAmount,
            isTokenAIn
        );

        {
            Liquifi.Order storage order = orders[id];
            (order.stopLossAmount, order.amountIn, order.period) = (
                uint112(stopLossAmount),
                uint112(amountIn),
                uint32(period)
            ); //already trimmed

            uint64 timeout = Liquifi.trimTime(poolTime(_state) + period);
            (order.owner, order.timeout, order.flags) = (owner, timeout, uint8(orderFlags));
        }

        changedBalances(BreakReason.ORDER_ADDED, _balances, _state, id);
    }

    function processDelayedOrders()
        external
        override
        returns (
            uint256 availableBalance,
            uint256 delayedSwapsIncome,
            uint256 packed
        )
    {
        Liquifi.PoolBalances memory _balances;
        Liquifi.PoolState memory _state;
        uint256 availableBalanceA;
        uint256 availableBalanceB;
        (_balances, _state, availableBalanceA, availableBalanceB) = actualizeBalances(
            Liquifi.ErrorArg.N_IN_PROCESS_DELAYED_ORDERS
        );
        availableBalance = (availableBalanceA << 128) | availableBalanceB;
        delayedSwapsIncome = _balances.delayedSwapsIncome;
        packed = _state.packed;
        exit(_balances, _state);
    }

    function claimOrder(
        bytes32 previousBreakHash,
        // availableBalance (0), flowSpeed (1), others (2)
        // uint256 others =
        //             (uint(_balances.poolFlowSpeedB) << 224) |
        //             (uint(_state.notFee) << 208) |
        //             (uint(time) << 144) |
        //             (uint(orderId) << 80) |
        //             (uint(_state.packed >> 20) << 4) |
        //             uint(reason);
        // uint availableBalance = (availableBalanceA << 128) | availableBalanceB;
        // uint flowSpeed = (uint(_balances.poolFlowSpeedA) << 112) | (_balances.poolFlowSpeedB >> 32);
        // see LiquifiPoolRegister.claimOrder for breaks list details
        uint256[] calldata breaksHistory
    )
        external
        override
        returns (
            address owner,
            uint256 amountAOut,
            uint256 amountBOut
        )
    {
        (Liquifi.PoolBalances memory _balances, Liquifi.PoolState memory _state) =
            enter(Liquifi.ErrorArg.M_IN_CLAIM_ORDER);

        uint256 lastIndex = breaksHistory.length;
        Liquifi._require(lastIndex != 0, Liquifi.Error.M_EMPTY_LIST, Liquifi.ErrorArg.H_IN_BREAKS_HISTORY);
        Liquifi._require(lastIndex % 3 == 0, Liquifi.Error.N_BAD_LENGTH, Liquifi.ErrorArg.H_IN_BREAKS_HISTORY);

        lastIndex = (lastIndex / 3) - 1;

        Liquifi.OrderClaim memory claim;
        claim.orderId = getBreakOrderId(breaksHistory, 0);
        bool partialHistory =
            getBreakOrderId(breaksHistory, lastIndex) != claim.orderId ||
                (uint8(getBreakReason(breaksHistory, lastIndex)) & uint8(BreakReason.ORDER_CLOSED) == 0); // check for any close reason

        // try to fail earlier if some more breaks happened after history collecting
        Liquifi._require(
            !partialHistory || getBreakTime(breaksHistory, lastIndex) == _state.nextBreakTime,
            Liquifi.Error.R_INCOMPLETE_HISTORY,
            Liquifi.ErrorArg.H_IN_BREAKS_HISTORY
        );

        Liquifi._require(
            getBreakReason(breaksHistory, 0) == BreakReason.ORDER_ADDED,
            Liquifi.Error.Q_ORDER_NOT_ADDED,
            Liquifi.ErrorArg.H_IN_BREAKS_HISTORY
        );

        // All orders are closed before fee change applying, so it is safe to use old fee for partial history
        // notFee is not saved on exit(), so it is safe to change it for current request only
        _state.notFee = uint16(getBreakFee(breaksHistory, 0));

        uint256 amountIn;
        {
            uint256 orderPeriod;
            Liquifi.Order storage order = orders[claim.orderId];

            (amountIn, orderPeriod) = (order.amountIn, order.period); // grouped read
            (owner, claim.flags) = (order.owner, order.flags); // grouped read

            Liquifi._require(
                orderPeriod > 0, // check a required property
                Liquifi.Error.V_ORDER_NOT_EXIST,
                Liquifi.ErrorArg.M_IN_CLAIM_ORDER
            );

            claim.orderFlowSpeed = (amountIn << 32) / orderPeriod; //= Sai' or = Sbi'
            claim.previousOthers = breaksHistory[2];
        }

        {
            uint256 index = 0;

            while (index <= lastIndex) {
                previousBreakHash = computeBreakHash(previousBreakHash, breaksHistory, index);
                appendSegmentToClaim(
                    breaksHistory[index * 3],
                    breaksHistory[index * 3 + 1],
                    breaksHistory[index * 3 + 2],
                    _state.notFee,
                    claim
                );
                index++;
            }
        }

        {
            bytes32 lashHash;
            if (partialHistory) {
                lashHash = _state.lastBreakHash;
                processBreaks(_balances, _state, claim);
                Liquifi._require(
                    claim.closeReason != 0,
                    Liquifi.Error.P_ORDER_NOT_CLOSED,
                    Liquifi.ErrorArg.M_IN_CLAIM_ORDER
                );
            } else {
                claim.closeReason = uint256(getBreakReason(breaksHistory, lastIndex));
                Liquifi.Order storage order = orders[claim.orderId];
                lashHash = bytes32(
                    (uint256(order.nextByTimeout) << 192) |
                        (uint256(order.prevByTimeout) << 128) |
                        (uint256(order.nextByStopLoss) << 64) |
                        uint256(order.prevByStopLoss)
                );
            }

            // compare all except for the lowest bit
            Liquifi._require(
                previousBreakHash >> 1 == lashHash >> 1,
                Liquifi.Error.O_HASH_MISMATCH,
                Liquifi.ErrorArg.H_IN_BREAKS_HISTORY
            );
        }

        {
            uint256 totalPeriod = extractBreakTime(claim.previousOthers) - getBreakTime(breaksHistory, 0);
            amountIn = claim.closeReason == uint256(BreakReason.ORDER_CLOSED)
                ? 0
                : amountIn.subWithClip((claim.orderFlowSpeed * totalPeriod) >> 32);
            (amountAOut, amountBOut) = Liquifi.isTokenAIn(claim.flags)
                ? (amountIn, claim.amountOut)
                : (claim.amountOut, amountIn);
        }

        {
            ERC20 token;
            if (amountAOut > 0) {
                token = tokenA;
                smartTransfer(
                    address(token),
                    owner,
                    amountAOut,
                    ((claim.flags & uint256(Liquifi.OrderFlag.EXTRACT_ETH) != 0) && aIsWETH)
                        ? Liquifi.ErrorArg.Q_TOKEN_ETH
                        : Liquifi.ErrorArg.O_TOKEN_A
                );
                _balances.totalBalanceA = Liquifi.trimTotal(token.balanceOf(address(this)), Liquifi.ErrorArg.O_TOKEN_A);
                _balances.balanceALocked = uint112(Math.subWithClip(_balances.balanceALocked, amountAOut));
                Liquifi.setFlag(_state, Liquifi.Flag.BALANCE_A_DIRTY);
            }

            if (amountBOut > 0) {
                token = tokenB;
                smartTransfer(address(token), owner, amountBOut, Liquifi.ErrorArg.P_TOKEN_B);
                _balances.totalBalanceB = Liquifi.trimTotal(token.balanceOf(address(this)), Liquifi.ErrorArg.P_TOKEN_B);
                _balances.balanceBLocked = uint112(Math.subWithClip(_balances.balanceBLocked, amountBOut));
                Liquifi.setFlag(_state, Liquifi.Flag.BALANCE_B_DIRTY);
            }

            Liquifi.setFlag(_state, Liquifi.Flag.TOTALS_DIRTY);
        }

        delete orders[claim.orderId];
        emit OrderClaimedEvent(claim.orderId, owner);
        _state.ordersToClaimCount -= 1;
        exit(_balances, _state);
    }

    bytes32 private constant one = bytes32(uint256(1));

    function enter(Liquifi.ErrorArg location)
        private
        returns (Liquifi.PoolBalances memory _balances, Liquifi.PoolState memory _state)
    {
        _state = savedState;
        _balances = savedBalances;

        bytes32 _prevBlockBreakHash = prevBlockBreakHash;
        bool mutexFlag1 = _prevBlockBreakHash & one == one;
        {
            bool mutexFlag2 = _state.breaksCount & 1 != 0;
            Liquifi._require(mutexFlag1 == mutexFlag2, Liquifi.Error.S_REENTRANCE_NOT_SUPPORTED, location);
        }

        if (!Liquifi.checkFlag(_state, Liquifi.Flag.GOVERNANCE_OVERRIDEN)) {
            (, uint96 defaultGovernancePacked) = governanceRouter.governance();
            _state.packed = defaultGovernancePacked;
        }

        _state.packed = ((_state.packed >> 20) << 20); // clear 20 transient bits

        if (Liquifi.checkFlag(_state, Liquifi.Flag.POOL_LOCKED)) {
            Liquifi.setInvalidState(_state, Liquifi.ErrorArg.W_POOL_LOCKED);
        }

        (, uint256 desiredOrdersFee, , , ) = Liquifi.unpackGovernance(_state);
        uint16 notFee = uint16(1000 - desiredOrdersFee);
        if (notFee != _state.notFee) {
            if (_state.firstByTimeout != 0) {
                // queue is not empty
                // no orders adding allowed
                Liquifi.setInvalidState(_state, Liquifi.ErrorArg.T_FEE_CHANGED_WITH_ORDERS_OPEN);
            } else {
                savedState.notFee = notFee;
                _state.notFee = notFee;
            }
        }

        // save hash if it was calculated in past
        if (_state.lastBalanceUpdateTime < poolTime(_state)) {
            _prevBlockBreakHash = _state.lastBreakHash;
        }
        // negate mutex bit in _prevBlockBreakHash and temporarly save it in Flags.MUTEX
        if (mutexFlag1) {
            Liquifi.clearFlag(_state, Liquifi.Flag.MUTEX);
            _prevBlockBreakHash = _prevBlockBreakHash & ~(one);
        } else {
            Liquifi.setFlag(_state, Liquifi.Flag.MUTEX);
            _prevBlockBreakHash = _prevBlockBreakHash | one;
        }

        prevBlockBreakHash = _prevBlockBreakHash;
    }

    function exit(Liquifi.PoolBalances memory _balances, Liquifi.PoolState memory _state) private {
        if (Liquifi.checkFlag(_state, Liquifi.Flag.HASH_DIRTY)) {
            savedState.lastBreakHash = _state.lastBreakHash;
        }

        if (Liquifi.checkFlag(_state, Liquifi.Flag.BALANCE_A_DIRTY)) {
            (savedBalances.balanceALocked, savedBalances.poolFlowSpeedA) = (
                _balances.balanceALocked,
                _balances.poolFlowSpeedA
            );
        }

        if (Liquifi.checkFlag(_state, Liquifi.Flag.BALANCE_B_DIRTY)) {
            (savedBalances.balanceBLocked, savedBalances.poolFlowSpeedB) = (
                _balances.balanceBLocked,
                _balances.poolFlowSpeedB
            );
        }

        if (Liquifi.checkFlag(_state, Liquifi.Flag.TOTALS_DIRTY)) {
            (savedBalances.totalBalanceA, savedBalances.totalBalanceB) = (
                _balances.totalBalanceA,
                _balances.totalBalanceB
            );
        }

        if (Liquifi.checkFlag(_state, Liquifi.Flag.SWAPS_INCOME_DIRTY)) {
            (savedBalances.delayedSwapsIncome) = (_balances.delayedSwapsIncome);
        }

        if (Liquifi.checkFlag(_state, Liquifi.Flag.TOTAL_SUPPLY_DIRTY)) {
            (savedBalances.rootKLastTotalSupply) = (_balances.rootKLastTotalSupply);
        }

        if (Liquifi.checkFlag(_state, Liquifi.Flag.QUEUE_STOPLOSS_DIRTY)) {
            (
                savedState.firstByTokenAStopLoss,
                savedState.lastByTokenAStopLoss,
                savedState.firstByTokenBStopLoss,
                savedState.lastByTokenBStopLoss
            ) = (
                _state.firstByTokenAStopLoss,
                _state.lastByTokenAStopLoss,
                _state.firstByTokenBStopLoss,
                _state.lastByTokenBStopLoss
            );
        }

        if (Liquifi.checkFlag(_state, Liquifi.Flag.QUEUE_TIMEOUT_DIRTY)) {
            (savedState.firstByTimeout, savedState.lastByTimeout) = (_state.firstByTimeout, _state.lastByTimeout);
        }

        // set mutex bit in breaksCount to same value as in prevBlockBreakHash
        if (Liquifi.checkFlag(_state, Liquifi.Flag.MUTEX)) {
            _state.breaksCount |= uint64(1);
        } else {
            _state.breaksCount &= ~uint64(1);
        }

        // last word of state is always saved
        (
            savedState.lastBalanceUpdateTime,
            savedState.nextBreakTime,
            savedState.maxHistory,
            savedState.ordersToClaimCount,
            savedState.breaksCount
        ) = (
            _state.lastBalanceUpdateTime,
            _state.nextBreakTime,
            _state.maxHistory,
            _state.ordersToClaimCount,
            _state.breaksCount
        );
    }

    function actualizeBalances(Liquifi.ErrorArg location)
        internal
        override(LiquifiLiquidityPool)
        returns (
            Liquifi.PoolBalances memory _balances,
            Liquifi.PoolState memory _state,
            uint256 availableBalanceA,
            uint256 availableBalanceB
        )
    {
        (_balances, _state) = enter(location);
        Liquifi.OrderClaim memory claim;
        processBreaks(_balances, _state, claim);
        (availableBalanceA, availableBalanceB) = updateBalanceLocked(poolTime(_state), _balances, _state);

        Liquifi.ErrorArg invalidState = Liquifi.checkInvalidState(_state);
        if (invalidState != Liquifi.ErrorArg.A_NONE) {
            emit OperatingInInvalidState(uint256(location), uint256(invalidState));
        }
    }

    function computeBreakHash(
        bytes32 previousBreakHash,
        uint256[] calldata breaks,
        uint256 index
    ) private pure returns (bytes32 breakHash) {
        index = index * 3;
        return
            keccak256(
                abi.encodePacked(
                    previousBreakHash,
                    uint256(breaks[index + 0]),
                    uint256(breaks[index + 1]),
                    uint256(breaks[index + 2])
                )
            );
    }

    function extractBreakTime(uint256 others) private pure returns (uint256) {
        return uint64(others >> 144);
    }

    function getBreakTime(uint256[] calldata breaks, uint256 i) private pure returns (uint256) {
        return extractBreakTime(breaks[i * 3 + 2]);
    }

    function getBreakOrderId(uint256[] calldata breaks, uint256 i) private pure returns (uint256) {
        return uint64(breaks[i * 3 + 2] >> 80);
    }

    function getBreakReason(uint256[] calldata breaks, uint256 i) private pure returns (BreakReason) {
        return BreakReason(uint8(breaks[i * 3 + 2]) & 15);
    }

    function getBreakFee(uint256[] calldata breaks, uint256 i) private pure returns (uint256 notFee) {
        return uint16(breaks[i * 3 + 2] >> 208);
    }

    function computeBreakRate(
        uint256 availableBalance,
        uint256 poolFlowSpeed,
        uint256 period,
        uint256 notFee
    ) private pure returns (uint256 balance) {
        return availableBalance + (((poolFlowSpeed * period) >> 32) * notFee) / 1000;
    }

    function appendSegmentToClaim(
        uint256 availableBalance,
        uint256 flowSpeed,
        uint256 others,
        uint256 notFee,
        Liquifi.OrderClaim memory claim
    ) private pure {
        uint256 poolFlowSpeedA = uint144(claim.previousFlowSpeed >> 112);
        uint256 poolFlowSpeedB = uint144(((claim.previousFlowSpeed << 144) >> 112) | (claim.previousOthers >> 224));
        uint256 availableBalanceA = uint128(claim.previousAvailableBalance >> 128);
        uint256 availableBalanceB = uint128(claim.previousAvailableBalance);
        uint256 period = extractBreakTime(others) - extractBreakTime(claim.previousOthers);
        claim.previousOthers = others;
        claim.previousAvailableBalance = availableBalance;
        claim.previousFlowSpeed = flowSpeed;

        uint256 rateNumerator = computeBreakRate(availableBalanceA, poolFlowSpeedA, period, notFee); // = x0 + Sa' * t * gamma
        uint256 rateDenominator = computeBreakRate(availableBalanceB, poolFlowSpeedB, period, notFee); // = y0 + Sb' * t * gamma

        if (rateNumerator != 0 && rateDenominator != 0) {
            uint256 tmp = (claim.orderFlowSpeed * period) >> 32; //= Sai' * t or = Sbi' * t
            tmp = (tmp * notFee) / 1000; // = (Sai' * t ) * gamma or = (Sbi' * t) * gamma
            tmp = Liquifi.isTokenAIn(claim.flags)
                ? (tmp * rateDenominator) / rateNumerator // = (Sai' * t ) * gamma * P
                : (tmp * rateNumerator) / rateDenominator; // = (Sbi' * t) * gamma * P
            claim.amountOut += tmp;
        }
    }

    function processBreaks(
        Liquifi.PoolBalances memory _balances,
        Liquifi.PoolState memory _state,
        Liquifi.OrderClaim memory claim
    ) private {
        if (_state.nextBreakTime > poolTime(_state)) {
            // also guarantees that there are some orders
            return;
        }

        Liquifi.Order storage order;
        uint64 _breakTime = _state.nextBreakTime;
        while (_breakTime <= poolTime(_state) && claim.closeReason == 0) {
            {
                (uint256 availableBalanceA, uint256 availableBalanceB) =
                    updateBalanceLocked(_breakTime, _balances, _state);
                // below this line [rate] = x0/y0 = availableBalanceA/availableBalanceB because t = [period since last update] = 0.
                order = orders[_state.firstByTimeout];
                if (order.timeout <= _breakTime) {
                    _closeOrder(
                        _state.firstByTimeout,
                        order,
                        BreakReason.ORDER_CLOSED,
                        _breakTime,
                        _balances,
                        _state,
                        claim
                    );
                } else if (
                    _state.firstByTokenAStopLoss != 0 &&
                    availableBalanceB > 0 &&
                    (((order = orders[_state.firstByTokenAStopLoss]).amountIn * _state.notFee) / 1000) *
                        availableBalanceB <=
                    availableBalanceA * order.stopLossAmount
                ) {
                    _closeOrder(
                        _state.firstByTokenAStopLoss,
                        order,
                        BreakReason.ORDER_CLOSED_BY_STOP_LOSS,
                        _breakTime,
                        _balances,
                        _state,
                        claim
                    );
                } else if (
                    _state.firstByTokenBStopLoss != 0 &&
                    availableBalanceA > 0 &&
                    (((order = orders[_state.firstByTokenBStopLoss]).amountIn * _state.notFee) / 1000) *
                        availableBalanceA <=
                    availableBalanceB * order.stopLossAmount
                ) {
                    _closeOrder(
                        _state.firstByTokenBStopLoss,
                        order,
                        BreakReason.ORDER_CLOSED_BY_STOP_LOSS,
                        _breakTime,
                        _balances,
                        _state,
                        claim
                    );
                }
            }
            //update nextBreakTime
            _breakTime = _state.firstByTimeout == 0 ? Liquifi.maxTime : orders[_state.firstByTimeout].timeout;

            if (_state.firstByTokenAStopLoss != 0) {
                order = orders[_state.firstByTokenAStopLoss];
                uint256 tokenAStopLoss =
                    computeStopLossTimeout(
                        ((order.amountIn * _state.notFee) / 1000),
                        order.stopLossAmount,
                        _balances,
                        _state
                    );
                if (tokenAStopLoss < _breakTime) {
                    _breakTime = uint64(tokenAStopLoss);
                }
            }

            if (_state.firstByTokenBStopLoss != 0) {
                order = orders[_state.firstByTokenBStopLoss];
                uint256 tokenBStopLoss =
                    computeStopLossTimeout(
                        order.stopLossAmount,
                        ((order.amountIn * _state.notFee) / 1000),
                        _balances,
                        _state
                    );
                if (tokenBStopLoss < _breakTime) {
                    _breakTime = uint64(tokenBStopLoss);
                }
            }

            _state.nextBreakTime = _breakTime;
        }
    }

    function computeStopLossTimeout(
        uint256 stopLossRateNumerator, // guaranteed to !=0
        uint256 stopLossRateDenominator, // guaranteed to !=0
        Liquifi.PoolBalances memory _balances,
        Liquifi.PoolState memory _state
    ) private pure returns (uint256 timeout) {
        // P = (gamma * Sa' * t + x0) / (gamma * Sb' * t + y0)   =>
        // => t = (x0 - y0 * P) / ((Sb' * P - Sa') * gamma)
        uint256 availableBalanceA = Math.subWithClip(_balances.totalBalanceA, _balances.balanceALocked);
        uint256 availableBalanceB = Math.subWithClip(_balances.totalBalanceB, _balances.balanceBLocked);

        int256 numerator =
            int256(availableBalanceA) - int256((availableBalanceB * stopLossRateNumerator) / stopLossRateDenominator); // = x0 - y0 * P
        int256 denominator =
            ((int256(((uint256(_balances.poolFlowSpeedB) * stopLossRateNumerator) / stopLossRateDenominator) >> 32) -
                int256(_balances.poolFlowSpeedA >> 32)) * _state.notFee) / 1000; // (Sb' * P - Sa') * gamma

        int256 period = denominator != 0 ? numerator / denominator : Liquifi.maxTime;
        return
            period >= 0 && period + _state.nextBreakTime + 1 <= Liquifi.maxTime
                ? uint256(period + _state.nextBreakTime + 1) // add one second to tolerate precision losses
                : Liquifi.maxTime;
    }

    function computeAvailableBalance(
        uint256 effectiveTime,
        Liquifi.PoolBalances memory _balances,
        Liquifi.PoolState memory _state
    ) private pure returns (uint256 availableBalanceA, uint256 availableBalanceB) {
        if (_balances.totalBalanceA < _balances.balanceALocked || _balances.totalBalanceB < _balances.balanceBLocked) {
            Liquifi.setInvalidState(_state, Liquifi.ErrorArg.V_INSUFFICIENT_TOTAL_BALANCE);
        }
        uint256 oldAvailableBalanceA = Math.subWithClip(_balances.totalBalanceA, _balances.balanceALocked); // = x0
        uint256 oldAvailableBalanceB = Math.subWithClip(_balances.totalBalanceB, _balances.balanceBLocked); // = y0
        Liquifi._require(
            effectiveTime <= _state.nextBreakTime,
            Liquifi.Error.H_BALANCE_AFTER_BREAK,
            Liquifi.ErrorArg.G_IN_COMPUTE_AVAILABLE_BALANCE
        );
        Liquifi._require(
            effectiveTime >= _state.lastBalanceUpdateTime,
            Liquifi.Error.I_BALANCE_OF_SAVED_UPD,
            Liquifi.ErrorArg.G_IN_COMPUTE_AVAILABLE_BALANCE
        );
        uint256 period = effectiveTime - _state.lastBalanceUpdateTime;
        if (period == 0) {
            return (oldAvailableBalanceA, oldAvailableBalanceB);
        }

        uint256 amountInA = _balances.poolFlowSpeedA * period; // = Sa' * t (premultiplied to 2^32)
        uint256 amountInB = _balances.poolFlowSpeedB * period; // = Sb' * t (premultiplied to 2^32)

        uint256 amountInAAdjusted = ((amountInA * _state.notFee) / 1000) >> 32; // = gamma * Sa' * t
        uint256 amountInBAdjusted = ((amountInB * _state.notFee) / 1000) >> 32; // = gamma * Sb' * t

        uint256 balanceIncreasedA = oldAvailableBalanceA.add(amountInAAdjusted); // = x0 + gamma * Sa' * t
        uint256 balanceIncreasedB = oldAvailableBalanceB.add(amountInBAdjusted); // = y0 + gamma * Sb' * t

        availableBalanceA = balanceIncreasedB == 0
            ? oldAvailableBalanceA
            : Liquifi.trimTotal(
                balanceIncreasedA.subWithClip(amountInBAdjusted.mul(balanceIncreasedA) / balanceIncreasedB),
                Liquifi.ErrorArg.O_TOKEN_A
            ); // = x0 + gamma * Sa' * t - gamma * Sb' * t * P
        availableBalanceB = balanceIncreasedA == 0
            ? oldAvailableBalanceB
            : Liquifi.trimTotal(
                balanceIncreasedB.subWithClip(amountInAAdjusted.mul(balanceIncreasedB) / balanceIncreasedA),
                Liquifi.ErrorArg.P_TOKEN_B
            ); // = y0 + gamma * Sb' * t - gamma * Sa' * t / P

        // Constant product check:
        // (x0 + gamma * Sa' * t - gamma * Sb' * t * P)*(y0 + gamma * Sb' * t - gamma * Sa' * t / P) >= x0 * y0
        if (availableBalanceA.mul(availableBalanceB) < oldAvailableBalanceA.mul(oldAvailableBalanceB)) {
            Liquifi.setInvalidState(_state, Liquifi.ErrorArg.U_BAD_EXCHANGE_RATE);
        }

        // And some additional check
        if (_balances.totalBalanceA < availableBalanceA || _balances.totalBalanceB < availableBalanceB) {
            Liquifi.setInvalidState(_state, Liquifi.ErrorArg.V_INSUFFICIENT_TOTAL_BALANCE);
        }
    }

    function changedBalances(
        BreakReason reason,
        Liquifi.PoolBalances memory _balances,
        Liquifi.PoolState memory _state,
        uint256 orderId
    ) internal override(LiquifiLiquidityPool) {
        Liquifi.OrderClaim memory claim;
        flowBroken(_balances, _state, poolTime(_state), orderId, reason, claim);
        exit(_balances, _state);
    }

    function updateBalanceLocked(
        uint256 effectiveTime,
        Liquifi.PoolBalances memory _balances,
        Liquifi.PoolState memory _state
    ) private pure returns (uint256 availableBalanceA, uint256 availableBalanceB) {
        (availableBalanceA, availableBalanceB) = computeAvailableBalance(effectiveTime, _balances, _state);
        if (effectiveTime == _state.lastBalanceUpdateTime) {
            return (availableBalanceA, availableBalanceB);
        }

        if (!Liquifi.checkFlag(_state, Liquifi.Flag.ARBITRAGEUR_FULL_FEE)) {
            uint256 period = effectiveTime - _state.lastBalanceUpdateTime;
            (uint256 delayedSwapsIncomeA, uint256 delayedSwapsIncomeB) =
                splitDelayedSwapsIncome(_balances.delayedSwapsIncome);
            _balances.delayedSwapsIncome =
                (uint256(
                    Liquifi.trimTotal(
                        delayedSwapsIncomeA + ((_balances.poolFlowSpeedA * period) >> 32),
                        Liquifi.ErrorArg.O_TOKEN_A
                    )
                ) << 128) |
                uint256(
                    Liquifi.trimTotal(
                        delayedSwapsIncomeB + ((_balances.poolFlowSpeedB * period) >> 32),
                        Liquifi.ErrorArg.P_TOKEN_B
                    )
                );
            Liquifi.setFlag(_state, Liquifi.Flag.SWAPS_INCOME_DIRTY);
        }

        _balances.balanceALocked = Liquifi.trimAmount(
            Math.subWithClip(_balances.totalBalanceA, availableBalanceA),
            Liquifi.ErrorArg.O_TOKEN_A
        );
        _balances.balanceBLocked = Liquifi.trimAmount(
            Math.subWithClip(_balances.totalBalanceB, availableBalanceB),
            Liquifi.ErrorArg.P_TOKEN_B
        );

        Liquifi.setFlag(_state, Liquifi.Flag.BALANCE_A_DIRTY);
        Liquifi.setFlag(_state, Liquifi.Flag.BALANCE_B_DIRTY);
        _state.lastBalanceUpdateTime = uint64(effectiveTime);
    }

    function flowBroken(
        // params ordered to reduce stack depth
        Liquifi.PoolBalances memory _balances,
        Liquifi.PoolState memory _state,
        uint256 time,
        uint256 orderId,
        BreakReason reason,
        Liquifi.OrderClaim memory claim
    ) private returns (bytes32 _lastBreakHash) {
        {
            uint256 availableBalance;
            {
                (uint256 availableBalanceA, uint256 availableBalanceB) =
                    computeAvailableBalance(time, _balances, _state);
                availableBalance = (availableBalanceA << 128) | availableBalanceB;
            }

            {
                uint256 others =
                    (uint256(_balances.poolFlowSpeedB) << 224) |
                        (uint256(_state.notFee) << 208) |
                        (uint256(time) << 144) |
                        (uint256(orderId) << 80) |
                        (uint256(_state.packed >> 20) << 4) |
                        uint256(reason);
                uint256 _totalBalance = (uint256(_balances.totalBalanceA) << 128) | uint256(_balances.totalBalanceB);
                uint256 flowSpeed = (uint256(_balances.poolFlowSpeedA) << 112) | (_balances.poolFlowSpeedB >> 32);

                emit FlowBreakEvent(
                    msg.sender,
                    _totalBalance,
                    _balances.rootKLastTotalSupply,
                    orderId,
                    // breakHash is computed over all fields below
                    _state.lastBreakHash,
                    availableBalance,
                    flowSpeed,
                    others
                );

                Liquifi.setFlag(_state, Liquifi.Flag.HASH_DIRTY);
                _state.lastBreakHash = _lastBreakHash = keccak256(
                    abi.encodePacked(_state.lastBreakHash, availableBalance, flowSpeed, others)
                );

                _state.nextBreakTime = (_balances.poolFlowSpeedA | _balances.poolFlowSpeedB == 0)
                    ? Liquifi.maxTime
                    : uint64(time);
                _state.breaksCount += 2; // not likely to have overflow here, but it is ok

                if (claim.orderId != 0 && claim.closeReason == 0) {
                    if (claim.orderId == orderId && (uint256(reason) & uint256(BreakReason.ORDER_CLOSED) != 0)) {
                        claim.closeReason = uint256(reason);
                    }
                    appendSegmentToClaim(availableBalance, flowSpeed, others, _state.notFee, claim);
                }
            }

            if (aIsWETH) {
                ActivityReporter(activityReporter).liquidityEthPriceChanged(
                    time,
                    uint128(availableBalance >> 128),
                    uint128(_balances.rootKLastTotalSupply)
                );
            }
        }
        // prevent order breaks history growth over maxHistory
        (, , , , uint256 desiredMaxHistory) = Liquifi.unpackGovernance(_state);
        if (_state.maxHistory < desiredMaxHistory) {
            _state.maxHistory = uint16(desiredMaxHistory);
        }

        while (reason != BreakReason.ORDER_CLOSED_BY_HISTORY_LIMIT) {
            uint256 closingId = (_state.breaksCount & ~uint64(1)) - (_state.maxHistory * 2); // valid id is always even;

            Liquifi.Order storage order = orders[closingId];

            if (
                orderId != closingId && // we're not changing this order right now
                order.period != 0 && // check order existance by required field 'period'
                order.prevByStopLoss & 1 == 0 // check that order is not closed: closed order has invalid id (odd) in prevByStopLoss
            ) {
                _closeOrder(
                    closingId,
                    order,
                    BreakReason.ORDER_CLOSED_BY_HISTORY_LIMIT,
                    time,
                    _balances,
                    _state,
                    claim
                );
                _state.breaksCount -= 2; // don't count breaks produced by closing orders by history
                break;
            }

            if (desiredMaxHistory == 0 || _state.maxHistory == desiredMaxHistory) {
                break;
            }

            _state.maxHistory--; // _state.maxHistory > desiredMaxHistory. Reduce it by one and try to close one more order
            desiredMaxHistory = 0;
        }
    }

    function closeOrder(uint256 id) external override {
        (Liquifi.PoolBalances memory _balances, Liquifi.PoolState memory _state, , ) =
            actualizeBalances(Liquifi.ErrorArg.R_IN_CLOSE_ORDER);

        Liquifi.Order memory order = orders[id];
        // check order existance by required field 'period'
        Liquifi._require(order.period > 0, Liquifi.Error.V_ORDER_NOT_EXIST, Liquifi.ErrorArg.R_IN_CLOSE_ORDER);

        BreakReason reason = BreakReason.ORDER_CLOSED_BY_REQUEST;
        if (msg.sender != order.owner) {
            (address governor, ) = governanceRouter.governance();
            Liquifi._require(
                msg.sender == governor,
                Liquifi.Error.Y_UNAUTHORIZED_SENDER,
                Liquifi.ErrorArg.R_IN_CLOSE_ORDER
            );
            reason = BreakReason.ORDER_CLOSED_BY_GOVERNOR;
        }

        // check that order is open: closed order has invalid id (odd) in prevByStopLoss
        Liquifi._require(
            order.prevByStopLoss & 1 == 0,
            Liquifi.Error.X_ORDER_ALREADY_CLOSED,
            Liquifi.ErrorArg.R_IN_CLOSE_ORDER
        );
        Liquifi.OrderClaim memory claim;

        _closeOrder(id, order, reason, poolTime(_state), _balances, _state, claim);

        exit(_balances, _state);
    }

    function _closeOrder(
        uint256 id,
        Liquifi.Order memory order,
        BreakReason reason,
        uint256 effectiveTime,
        Liquifi.PoolBalances memory _balances,
        Liquifi.PoolState memory _state,
        Liquifi.OrderClaim memory claim
    ) private {
        deleteOrderFromQueue(order, _state);
        {
            uint256 orderFlowSpeed = (uint256(order.amountIn) << 32) / order.period; // multiply to 2^32 to keep precision
            uint256 effectivePeriod = uint256(effectiveTime).subWithClip(order.timeout - order.period);
            uint256 orderIncome = orderFlowSpeed.mul(effectivePeriod);
            uint256 orderFee = (orderIncome >> 32).mul(1000 - _state.notFee) / 1000;

            if (Liquifi.isTokenAIn(order.flags)) {
                Liquifi.setFlag(_state, Liquifi.Flag.BALANCE_A_DIRTY);
                _balances.balanceALocked = uint112(Math.subWithClip(_balances.balanceALocked, orderFee));
                _balances.poolFlowSpeedA = uint144(Math.subWithClip(_balances.poolFlowSpeedA, orderFlowSpeed));
                subDelayedSwapsIncome(_balances, _state, orderIncome, 0);
            } else {
                Liquifi.setFlag(_state, Liquifi.Flag.BALANCE_B_DIRTY);

                _balances.balanceBLocked = uint112(Math.subWithClip(_balances.balanceBLocked, orderFee));
                _balances.poolFlowSpeedB = uint144(Math.subWithClip(_balances.poolFlowSpeedB, orderFlowSpeed));
                subDelayedSwapsIncome(_balances, _state, 0, orderIncome);
            }
        }

        bytes32 _lastBreakHash = flowBroken(_balances, _state, effectiveTime, id, reason, claim);

        Liquifi.Order storage storedOrder = orders[id];
        // save gas by re-using existing fields
        // set highest bit to 1 in nextByTimeout to mark order as closed
        storedOrder.nextByTimeout = uint64(uint256(_lastBreakHash) >> 192);
        storedOrder.prevByTimeout = uint64(uint256(_lastBreakHash) >> 128);
        storedOrder.nextByStopLoss = uint64(uint256(_lastBreakHash) >> 64);
        storedOrder.prevByStopLoss = uint64(uint256(_lastBreakHash) | 1);

        _state.ordersToClaimCount += 1;
    }

    function deleteOrderFromQueue(Liquifi.Order memory order, Liquifi.PoolState memory _state) private {
        bool isTokenA = Liquifi.isTokenAIn(order.flags);
        if (order.prevByTimeout == 0) {
            Liquifi.setFlag(_state, Liquifi.Flag.QUEUE_TIMEOUT_DIRTY);
            _state.firstByTimeout = order.nextByTimeout;
        } else {
            orders[order.prevByTimeout].nextByTimeout = order.nextByTimeout;
        }

        if (order.nextByTimeout == 0) {
            Liquifi.setFlag(_state, Liquifi.Flag.QUEUE_TIMEOUT_DIRTY);
            _state.lastByTimeout = order.prevByTimeout;
        } else {
            orders[order.nextByTimeout].prevByTimeout = order.prevByTimeout;
        }

        if (order.prevByStopLoss == 0) {
            Liquifi.setFlag(_state, Liquifi.Flag.QUEUE_STOPLOSS_DIRTY);
            if (isTokenA) {
                _state.firstByTokenAStopLoss = order.nextByStopLoss;
            } else {
                _state.firstByTokenBStopLoss = order.nextByStopLoss;
            }
        } else {
            orders[order.prevByStopLoss].nextByStopLoss = order.nextByStopLoss;
        }

        if (order.nextByStopLoss == 0) {
            Liquifi.setFlag(_state, Liquifi.Flag.QUEUE_STOPLOSS_DIRTY);
            if (isTokenA) {
                _state.lastByTokenAStopLoss = order.prevByStopLoss;
            } else {
                _state.lastByTokenBStopLoss = order.prevByStopLoss;
            }
        } else {
            orders[order.nextByStopLoss].prevByStopLoss = order.prevByStopLoss;
        }
    }

    function saveOrder(
        Liquifi.PoolState memory _state,
        uint256 period,
        uint256 prevByTimeout,
        uint256 prevByStopLoss,
        uint256 amountIn,
        uint256 stopLossAmount,
        bool isTokenA
    ) private returns (uint64 id) {
        uint256 timeout = Liquifi.trimTime(poolTime(_state) + period);
        id = (2 + _state.breaksCount) & ~uint64(1); // valid id is always even

        uint256 nextByTimeout;
        (prevByTimeout, nextByTimeout) = ensureTimeoutSort(_state, timeout, prevByTimeout);
        uint256 nextByStopLoss;
        (prevByStopLoss, nextByStopLoss) = ensureStopLossSort(
            _state,
            stopLossAmount,
            amountIn,
            isTokenA,
            prevByStopLoss
        );

        Liquifi.Order storage order = orders[id];
        (order.nextByTimeout, order.prevByTimeout, order.nextByStopLoss, order.prevByStopLoss) = (
            uint64(nextByTimeout),
            uint64(prevByTimeout),
            uint64(nextByStopLoss),
            uint64(prevByStopLoss)
        );

        if (prevByTimeout == 0) {
            Liquifi.setFlag(_state, Liquifi.Flag.QUEUE_TIMEOUT_DIRTY);
            _state.firstByTimeout = id;
        } else {
            orders[prevByTimeout].nextByTimeout = id;
        }

        if (nextByTimeout == 0) {
            Liquifi.setFlag(_state, Liquifi.Flag.QUEUE_TIMEOUT_DIRTY);
            _state.lastByTimeout = id;
        } else {
            orders[nextByTimeout].prevByTimeout = id;
        }

        if (prevByStopLoss == 0) {
            Liquifi.setFlag(_state, Liquifi.Flag.QUEUE_STOPLOSS_DIRTY);
            if (isTokenA) {
                _state.firstByTokenAStopLoss = id;
            } else {
                _state.firstByTokenBStopLoss = id;
            }
        } else {
            orders[prevByStopLoss].nextByStopLoss = id;
        }

        if (nextByStopLoss == 0) {
            Liquifi.setFlag(_state, Liquifi.Flag.QUEUE_STOPLOSS_DIRTY);
            if (isTokenA) {
                _state.lastByTokenAStopLoss = id;
            } else {
                _state.lastByTokenBStopLoss = id;
            }
        } else {
            orders[nextByStopLoss].prevByStopLoss = id;
        }
    }

    // find position in linked list sorted by timeouts ascending
    function ensureTimeoutSort(
        Liquifi.PoolState memory _state,
        uint256 timeout,
        uint256 prevByTimeout
    ) private view returns (uint256 _prevByTimeout, uint256 _nextByTimeout) {
        _nextByTimeout = _state.firstByTimeout;
        _prevByTimeout = prevByTimeout;

        if (_prevByTimeout != 0) {
            Liquifi.Order memory prevByTimeoutOrder = orders[_prevByTimeout];
            if (
                prevByTimeoutOrder.period > 0 && // check order existance by required field 'period'
                prevByTimeoutOrder.prevByStopLoss & 1 == 0 // check that order is not closed: closed order has invalid id (odd) in prevByStopLoss
            ) {
                _nextByTimeout = prevByTimeoutOrder.nextByTimeout;
                uint256 prevTimeout = prevByTimeoutOrder.timeout;

                // iterate towards list start if needed
                while (_prevByTimeout != 0) {
                    if (prevTimeout <= timeout) {
                        break;
                    }

                    _nextByTimeout = _prevByTimeout;
                    _prevByTimeout = orders[_prevByTimeout].prevByTimeout;
                    prevTimeout = orders[_prevByTimeout].timeout;
                }
            } else {
                // invalid prevByTimeout passed, start search from list head
                _prevByTimeout = 0;
            }
        }

        // iterate towards list end if needed
        while (_nextByTimeout != 0 && orders[_nextByTimeout].timeout < timeout) {
            _prevByTimeout = _nextByTimeout;
            _nextByTimeout = orders[_nextByTimeout].nextByTimeout;
        }
    }

    // find position in linked list sorted by (amountIn/stopLossAmount) ascending
    function ensureStopLossSort(
        Liquifi.PoolState memory _state,
        uint256 stopLossAmount,
        uint256 amountIn,
        bool isTokenA,
        uint256 prevByStopLoss
    ) private view returns (uint256 _prevByStopLoss, uint256 _nextByStopLoss) {
        _nextByStopLoss = isTokenA ? _state.firstByTokenAStopLoss : _state.firstByTokenBStopLoss;
        _prevByStopLoss = prevByStopLoss;

        if (_prevByStopLoss != 0) {
            Liquifi.Order memory prevByStopLossOrder = orders[_prevByStopLoss];
            if (
                prevByStopLossOrder.period > 0 && // check order existance by required field 'period'
                prevByStopLossOrder.prevByStopLoss & 1 == 0 && // check that order is not closed: closed order has invalid id (odd) in prevByStopLoss
                Liquifi.isTokenAIn(prevByStopLossOrder.flags) == isTokenA
            ) {
                _nextByStopLoss = prevByStopLossOrder.nextByStopLoss;

                // iterate towards list start if needed
                (uint256 prevStopLossAmount, uint256 prevAmountIn) =
                    (prevByStopLossOrder.stopLossAmount, prevByStopLossOrder.amountIn);
                while (_prevByStopLoss != 0) {
                    if (prevAmountIn * stopLossAmount <= amountIn * prevStopLossAmount) {
                        break;
                    }

                    _nextByStopLoss = _prevByStopLoss;
                    _prevByStopLoss = orders[_prevByStopLoss].prevByStopLoss;

                    (prevStopLossAmount, prevAmountIn) = (
                        orders[_prevByStopLoss].stopLossAmount,
                        orders[_prevByStopLoss].amountIn
                    ); // grouped read
                }
            } else {
                // invalid prevByStopLoss passed, start search from list head
                _prevByStopLoss = 0;
            }
        }

        // iterate towards list end if needed
        while (_nextByStopLoss != 0) {
            (uint256 nextStopLossAmount, uint256 nextAmountIn) =
                (orders[_nextByStopLoss].stopLossAmount, orders[_nextByStopLoss].amountIn); // grouped read

            if (nextAmountIn * stopLossAmount >= amountIn * nextStopLossAmount) {
                break;
            }

            _prevByStopLoss = _nextByStopLoss;
            _nextByStopLoss = orders[_nextByStopLoss].nextByStopLoss;
        }
    }

    // force reserves to match balances
    function sync() external override {
        (Liquifi.PoolBalances memory _balances, Liquifi.PoolState memory _state) =
            enter(Liquifi.ErrorArg.M_IN_CLAIM_ORDER);
        Liquifi.setFlag(_state, Liquifi.Flag.TOTALS_DIRTY);
        _balances.totalBalanceA = Liquifi.trimTotal(tokenA.balanceOf(address(this)), Liquifi.ErrorArg.O_TOKEN_A);
        _balances.totalBalanceB = Liquifi.trimTotal(tokenB.balanceOf(address(this)), Liquifi.ErrorArg.P_TOKEN_B);
        if (_state.firstByTimeout == 0 && _state.ordersToClaimCount == 0) {
            _balances.balanceALocked = 0;
            _balances.poolFlowSpeedA = 0;
            _balances.balanceBLocked = 0;
            _balances.poolFlowSpeedB = 0;
            Liquifi.setFlag(_state, Liquifi.Flag.BALANCE_A_DIRTY);
            Liquifi.setFlag(_state, Liquifi.Flag.BALANCE_B_DIRTY);
        }
        exit(_balances, _state);
    }
}
