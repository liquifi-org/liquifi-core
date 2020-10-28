// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.0;
import { ERC20 } from "../interfaces/ERC20.sol";

library Liquifi {
    enum Flag { 
        // padding 8 bits
        PAD1, PAD2, PAD3, PAD4, PAD5, PAD6, PAD7, PAD8,
        // transient flags
        HASH_DIRTY, BALANCE_A_DIRTY, BALANCE_B_DIRTY, TOTALS_DIRTY, QUEUE_STOPLOSS_DIRTY, QUEUE_TIMEOUT_DIRTY, MUTEX, INVALID_STATE,
        TOTAL_SUPPLY_DIRTY, SWAPS_INCOME_DIRTY, RESERVED1, RESERVED2,
        // persistent flags set by governance
        POOL_LOCKED, ARBITRAGEUR_FULL_FEE, GOVERNANCE_OVERRIDEN
    }

    struct PoolBalances { // optimized for storage
        // saved on BALANCE_A_DIRTY in exit()
        uint112 balanceALocked;
        uint144 poolFlowSpeedA; // flow speed: (amountAIn * 2^32)/second

        // saved on BALANCE_B_DIRTY in exit()
        uint112 balanceBLocked;
        uint144 poolFlowSpeedB; // flow speed: (amountBIn * 2^32)/second
        
        // saved on TOTALS_DIRTY in exit()
        uint128 totalBalanceA;
        uint128 totalBalanceB;

        // saved on SWAPS_INCOME_DIRTY in exit()
        // contains 128 bits of delayedSwapsIncomeA and 128 bits of delayedSwapsIncomeB
        uint delayedSwapsIncome;
        
        // saved on TOTAL_SUPPLY_DIRTY in exit()
        // contains 128 bits of rootKLast and 128 bits of totalSupply
        // rootKLast = sqrt(availableBalanceA * availableBalanceB), as of immediately after the most recent liquidity event
        uint rootKLastTotalSupply;
    }

    struct PoolState { // optimized for storage
        // saved on HASH_DIRTY in exit()
        bytes32 lastBreakHash;

        // saved on QUEUE_STOPLOSS_DIRTY in exit()
        uint64 firstByTokenAStopLoss; uint64 lastByTokenAStopLoss; // linked list of orders sorted by (amountAIn/stopLossAmount) ascending
        uint64 firstByTokenBStopLoss; uint64 lastByTokenBStopLoss; // linked list of orders sorted by (amountBIn/stopLossAmount) ascending

        // saved on QUEUE_TIMEOUT_DIRTY in exit()
        uint64 firstByTimeout; uint64 lastByTimeout; // linked list of orders sorted by timeouts ascending
        // this field contains
        // 8 bits of instantSwapFee
        // 8 bits of desiredOrdersFee
        // 8 bits of protocolFee
        // 32 bits of maxPeriod
        // 16 bits of desiredMaxHistory
        // 4 bits of persistent flags
        // 12 bits of transient flags
        // 8 bits of transient invalidStateReason (ErrorArg)
        // Packing reduces stack depth and helps in governance
        uint96 packed; // not saved in exit(), saved only by governance
        uint16 notFee; // not saved in exit()

        // This word is always saved in exit()
        uint64 lastBalanceUpdateTime;
        uint64 nextBreakTime;
        uint32 maxHistory;
        uint32 ordersToClaimCount;
        uint64 breaksCount; // counter with increments of 2. 1st bit is used as mutex flag
    }

    enum OrderFlag { 
        NONE, IS_TOKEN_A, EXTRACT_ETH
    }

    struct Order { // optimized for storage, fits into 3 words
        // Also closing hash is saved in this word on order close.
        // Closing hash always has last bit = 1, I.e. prevByStopLoss & 1 == 1
        uint64 nextByTimeout; uint64 prevByTimeout;
        uint64 nextByStopLoss; uint64 prevByStopLoss;
        
        // mostly used together
        uint112 stopLossAmount;
        uint112 amountIn;
        uint32 period;

        address owner;
        uint64 timeout;
        uint8 flags;
    }

    struct OrderClaim { //in-memory only
        uint amountOut;
        uint orderFlowSpeed;
        uint orderId;
        uint flags;
        uint closeReason;
        uint previousAvailableBalance;
        uint previousFlowSpeed;
        uint previousOthers;
    }

    enum Error { 
        A_MUL_OVERFLOW, 
        B_ADD_OVERFLOW, 
        C_TOO_BIG_TIME_VALUE, 
        D_TOO_BIG_PERIOD_VALUE,
        E_TOO_BIG_AMOUNT_VALUE,
        F_ZERO_AMOUNT_VALUE,
        G_ZERO_PERIOD_VALUE,
        H_BALANCE_AFTER_BREAK,
        I_BALANCE_OF_SAVED_UPD,
        J_INVALID_POOL_STATE,
        K_TOO_BIG_TOTAL_VALUE,
        L_INSUFFICIENT_LIQUIDITY,
        M_EMPTY_LIST,
        N_BAD_LENGTH,
        O_HASH_MISMATCH,
        P_ORDER_NOT_CLOSED,
        Q_ORDER_NOT_ADDED,
        R_INCOMPLETE_HISTORY,
        S_REENTRANCE_NOT_SUPPORTED,
        T_INVALID_TOKENS_PAIR,
        U_TOKEN_TRANSFER_FAILED,
        V_ORDER_NOT_EXIST,
        W_DIV_BY_ZERO,
        X_ORDER_ALREADY_CLOSED,
        Y_UNAUTHORIZED_SENDER,
        Z_TOO_BIG_FLOW_SPEED_VALUE
    }

    enum ErrorArg {
        A_NONE,
        B_IN_AMOUNT,
        C_OUT_AMOUNT,
        D_STOP_LOSS_AMOUNT,
        E_IN_ADD_ORDER,
        F_IN_SWAP,
        G_IN_COMPUTE_AVAILABLE_BALANCE,
        H_IN_BREAKS_HISTORY,
        I_USER_DATA,
        J_IN_ORDER,
        K_IN_MINT,
        L_IN_BURN,
        M_IN_CLAIM_ORDER,
        N_IN_PROCESS_DELAYED_ORDERS,
        O_TOKEN_A,
        P_TOKEN_B,
        Q_TOKEN_ETH,
        R_IN_CLOSE_ORDER,
        S_BY_GOVERNANCE,
        T_FEE_CHANGED_WITH_ORDERS_OPEN,
        U_BAD_EXCHANGE_RATE,
        V_INSUFFICIENT_TOTAL_BALANCE,
        W_POOL_LOCKED,
        X_TOTAL_SUPPLY
    }

    // this methods allows to pass some information in 'require' calls without storing strings in contract bytecode 
    // messages will be like "FAIL https://err.liquifi.org/XY" where X and Y are error and errorArg from respective enums
    function _require(bool condition, Error error, ErrorArg errorArg) internal pure {
        if (condition) return;
        { // new scope to not waste message memory if condition is satisfied 
            // FAIL https://err.liquifi.org/__
            bytes memory message = "\x46\x41\x49\x4c\x20\x68\x74\x74\x70\x73\x3a\x2f\x2f\x65\x72\x72\x2e\x6c\x69\x71\x75\x69\x66\x69\x2e\x6f\x72\x67\x2f\x5f\x5f";
            
            message[29] = bytes1(65 + uint8(error));
            message[30] = bytes1(65 + uint8(errorArg));
            require(false, string(message));
        }
    }

    uint64 constant maxTime = ~uint64(0);

    function trimTime(uint time) internal pure returns (uint64 trimmedTime) {
        Liquifi._require(time <= maxTime, Liquifi.Error.C_TOO_BIG_TIME_VALUE, Liquifi.ErrorArg.A_NONE);
        return uint64(time);
    }

    function trimPeriod(uint period, Liquifi.ErrorArg periodType) internal pure returns (uint32 trimmedPeriod) {
        Liquifi._require(period <= ~uint32(0), Liquifi.Error.D_TOO_BIG_PERIOD_VALUE, periodType);
        return uint32(period);
    }

    function trimAmount(uint amount, Liquifi.ErrorArg amountType) internal pure returns (uint112 trimmedAmount) {
        Liquifi._require(amount <= ~uint112(0), Liquifi.Error.E_TOO_BIG_AMOUNT_VALUE, amountType);
        return uint112(amount);
    }


    function trimTotal(uint amount, Liquifi.ErrorArg amountType) internal pure returns (uint128 trimmedAmount) {
        Liquifi._require(amount <= ~uint128(0), Liquifi.Error.K_TOO_BIG_TOTAL_VALUE, amountType);
        return uint128(amount);
    }

    function trimFlowSpeed(uint amount, Liquifi.ErrorArg amountType) internal pure returns (uint144 trimmedAmount) {
        Liquifi._require(amount <= ~uint144(0), Liquifi.Error.Z_TOO_BIG_FLOW_SPEED_VALUE, amountType);
        return uint144(amount);
    }

    function checkFlag(PoolState memory _state, Flag flag) internal pure returns(bool) {
        return _state.packed & uint96(1 << uint(flag)) != 0;
    }

    function setFlag(PoolState memory _state, Flag flag) internal pure {
        _state.packed = _state.packed | uint96(1 << uint(flag));
    }

    function clearFlag(PoolState memory _state, Flag flag) internal pure {
        _state.packed = _state.packed & ~uint96(1 << uint(flag));
    }

    function unpackGovernance(PoolState memory _state) internal pure returns(
        uint instantSwapFee, uint desiredOrdersFee, uint protocolFee, uint maxPeriod, uint desiredMaxHistory
    ) {
        desiredMaxHistory = uint16(_state.packed >> 24);
        maxPeriod = uint32(_state.packed >> 40);
        protocolFee = uint8(_state.packed >> 72);
        desiredOrdersFee = uint8(_state.packed >> 80);
        instantSwapFee = uint8(_state.packed >> 88);
    }

    function setInvalidState(PoolState memory _state, Liquifi.ErrorArg reason) internal pure {
        setFlag(_state, Liquifi.Flag.INVALID_STATE);
        uint oldReason = uint8(_state.packed);
        if (uint(reason) > oldReason) {
            _state.packed = _state.packed & ~uint96(~uint8(0)) | uint96(reason);
        }
    }

    function checkInvalidState(PoolState memory _state) internal pure returns (Liquifi.ErrorArg reason) {
        reason = Liquifi.ErrorArg.A_NONE;
        if (checkFlag(_state, Liquifi.Flag.INVALID_STATE)) {
            return Liquifi.ErrorArg(uint8(_state.packed));
        }
    }

    function isTokenAIn(uint orderFlags) internal pure returns (bool) {
        return orderFlags & uint(Liquifi.OrderFlag.IS_TOKEN_A) != 0;
    }
}