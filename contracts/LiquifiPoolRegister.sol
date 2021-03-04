// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import {PoolFactory} from "./interfaces/PoolFactory.sol";
import {DelayedExchangePool} from "./interfaces/DelayedExchangePool.sol";
import {PoolRegister, ConvertETH} from "./interfaces/PoolRegister.sol";
import {ERC20} from "./interfaces/ERC20.sol";
import {Math} from "./libraries/Math.sol";
import {WETH} from "./interfaces/WETH.sol";
import {GovernanceRouter} from "./interfaces/GovernanceRouter.sol";

contract LiquifiPoolRegister is PoolRegister {
    PoolFactory public immutable override factory;
    WETH public immutable override weth;

    using Math for uint256;

    modifier beforeTimeout(uint256 timeout) {
        require(timeout >= block.timestamp, "LIQUIFI: EXPIRED CALL");
        _;
    }

    constructor(address _governanceRouter) {
        factory = GovernanceRouter(_governanceRouter).poolFactory();
        weth = GovernanceRouter(_governanceRouter).weth();
    }

    receive() external payable {
        assert(msg.sender == address(weth));
    }

    function smartTransferFrom(
        address token,
        address to,
        uint256 value,
        ConvertETH convertETH
    ) internal {
        address from = (token == address(weth) && convertETH == ConvertETH.IN_ETH) ? address(this) : msg.sender;

        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(ERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "LIQUIFI: TRANSFER_FROM_FAILED");
    }

    function smartTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(ERC20.transfer.selector, to, value));
        success = success && (data.length == 0 || abi.decode(data, (bool)));

        require(success, "LIQUIFI: TOKEN_TRANSFER_FAILED");
    }

    function smartTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "LIQUIFI: ETH_TRANSFER_FAILED");
    }

    // Registry always creates pools with tokens in proper order
    function properOrder(address tokenA, address tokenB) private view returns (bool) {
        return (tokenA == address(weth) ? address(0) : tokenA) < (tokenB == address(weth) ? address(0) : tokenB);
    }

    function _deposit(
        address token1,
        uint256 amount1,
        address token2,
        uint256 amount2,
        address to,
        ConvertETH convertETH,
        uint256 timeout
    )
        private
        beforeTimeout(timeout)
        returns (
            uint256 liquidityOut,
            uint256 amountA,
            uint256 amountB
        )
    {
        address pool;
        {
            (address tokenA, address tokenB) = properOrder(token1, token2) ? (token1, token2) : (token2, token1);
            (amountA, amountB) = properOrder(token1, token2) ? (amount1, amount2) : (amount2, amount1);
            pool = factory.getPool(tokenA, tokenB);
        }
        uint256 availableBalanceA;
        uint256 availableBalanceB;
        {
            (uint256 availableBalance, , ) = DelayedExchangePool(pool).processDelayedOrders();
            availableBalanceA = uint128(availableBalance >> 128);
            availableBalanceB = uint128(availableBalance);
        }

        if (availableBalanceA != 0 && availableBalanceB != 0) {
            uint256 amountBOptimal = amountA.mul(availableBalanceB) / availableBalanceA;
            if (amountBOptimal <= amountB) {
                //require(amountBOptimal >= amountBMin, 'LIQUIFI: INSUFFICIENT_B_AMOUNT');
                amountB = amountBOptimal;
            } else {
                uint256 amountAOptimal = amountB.mul(availableBalanceA) / availableBalanceB;
                assert(amountAOptimal <= amountA);
                //require(amountAOptimal >= amountAMin, 'LIQUIFI: INSUFFICIENT_A_AMOUNT');
                amountA = amountAOptimal;
            }
        }

        (amount1, amount2) = properOrder(token1, token2) ? (amountA, amountB) : (amountB, amountA);

        smartTransferFrom(token1, pool, amount1, convertETH);
        smartTransferFrom(token2, pool, amount2, convertETH);
        liquidityOut = DelayedExchangePool(pool).mint(to);
        emit Mint(token1, amount1, token2, amount2, liquidityOut, to, convertETH);
    }

    function deposit(
        address token1,
        uint256 amount1,
        address token2,
        uint256 amount2,
        address to,
        uint256 timeout
    )
        external
        override
        returns (
            uint256 liquidityOut,
            uint256 amount1Used,
            uint256 amount2Used
        )
    {
        uint256 amountA;
        uint256 amountB;
        (liquidityOut, amountA, amountB) = _deposit(token1, amount1, token2, amount2, to, ConvertETH.NONE, timeout);
        (amount1Used, amount2Used) = properOrder(token1, token2) ? (amountA, amountB) : (amountB, amountA);
    }

    function depositWithETH(
        address token,
        uint256 amount,
        address to,
        uint256 timeout
    )
        external
        payable
        override
        returns (
            uint256 liquidityOut,
            uint256 amountETHUsed,
            uint256 amountTokenUsed
        )
    {
        uint256 amountETH = msg.value;
        weth.deposit{value: amountETH}();
        require(weth.approve(address(this), amountETH), "LIQUIFI: WETH_APPROVAL_FAILED");
        (liquidityOut, amountETHUsed, amountTokenUsed) = _deposit(
            address(weth),
            amountETH,
            token,
            amount,
            to,
            ConvertETH.IN_ETH,
            timeout
        );

        if (amountETH > amountETHUsed) {
            uint256 refundETH = amountETH - amountETH;
            weth.withdraw(refundETH);
            smartTransferETH(msg.sender, refundETH);
        }
    }

    function _withdraw(
        address token1,
        address token2,
        uint256 liquidityIn,
        address to,
        ConvertETH convertETH,
        uint256 timeout
    ) private beforeTimeout(timeout) returns (uint256 amount1, uint256 amount2) {
        address pool = factory.findPool(token1, token2);
        require(pool != address(0), "LIQIFI: WITHDRAW_FROM_INVALID_POOL");
        require(DelayedExchangePool(pool).transferFrom(msg.sender, pool, liquidityIn), "LIQIFI: TRANSFER_FROM_FAILED");
        (uint256 amountA, uint256 amountB) = DelayedExchangePool(pool).burn(to, convertETH == ConvertETH.OUT_ETH);
        (amount1, amount2) = properOrder(token1, token2) ? (amountA, amountB) : (amountB, amountA);
        emit Burn(token1, amount1, token2, amount2, liquidityIn, to, convertETH);
    }

    function withdraw(
        address token1,
        address token2,
        uint256 liquidityIn,
        address to,
        uint256 timeout
    ) external override returns (uint256 amount1, uint256 amount2) {
        return _withdraw(token1, token2, liquidityIn, to, ConvertETH.NONE, timeout);
    }

    function withdrawWithETH(
        address token,
        uint256 liquidityIn,
        address to,
        uint256 timeout
    ) external override returns (uint256 amountToken, uint256 amountETH) {
        (amountETH, amountToken) = _withdraw(address(weth), token, liquidityIn, to, ConvertETH.OUT_ETH, timeout);
    }

    function _swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        address to,
        ConvertETH convertETH,
        uint256 timeout
    ) private beforeTimeout(timeout) returns (uint256 amountOut) {
        address pool = factory.findPool(tokenIn, tokenOut);
        require(pool != address(0), "LIQIFI: SWAP_ON_INVALID_POOL");

        smartTransferFrom(tokenIn, pool, amountIn, convertETH);

        bool isTokenAIn = properOrder(tokenIn, tokenOut);
        (uint256 amountAOut, uint256 amountBOut, uint256 fee) = getAmountsOut(pool, isTokenAIn, amountIn, minAmountOut);
        DelayedExchangePool(pool).swap(to, convertETH == ConvertETH.OUT_ETH, amountAOut, amountBOut, new bytes(0));
        amountOut = isTokenAIn ? amountBOut : amountAOut;
        emit Swap(tokenIn, amountIn, tokenOut, amountOut, to, convertETH, fee);
    }

    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        address to,
        uint256 timeout
    ) external override returns (uint256 amountOut) {
        return _swap(tokenIn, amountIn, tokenOut, minAmountOut, to, ConvertETH.NONE, timeout);
    }

    function swapFromETH(
        address tokenOut,
        uint256 minAmountOut,
        address to,
        uint256 timeout
    ) external payable override returns (uint256 amountOut) {
        uint256 amountETH = msg.value;
        weth.deposit{value: amountETH}();
        require(weth.approve(address(this), amountETH), "LIQUIFI: WETH_APPROVAL_FAILED");

        return _swap(address(weth), amountETH, tokenOut, minAmountOut, to, ConvertETH.IN_ETH, timeout);
    }

    function swapToETH(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        uint256 timeout
    ) external override returns (uint256 amountETHOut) {
        amountETHOut = _swap(tokenIn, amountIn, address(weth), minAmountOut, to, ConvertETH.OUT_ETH, timeout);
    }

    function _delayedSwap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        address to,
        ConvertETH convertETH,
        uint256 time,
        uint256 prevByStopLoss,
        uint256 prevByTimeout
    ) private beforeTimeout(time) returns (uint256 orderId) {
        time -= block.timestamp; // reuse variable to reduce stack size

        address pool = factory.findPool(tokenIn, tokenOut);
        require(pool != address(0), "LIQIFI: DELAYED_SWAP_ON_INVALID_POOL");
        smartTransferFrom(tokenIn, pool, amountIn, convertETH);

        uint256 orderFlags = 0;
        if (properOrder(tokenIn, tokenOut)) {
            orderFlags |= 1; // IS_TOKEN_A
        }
        if (convertETH == ConvertETH.OUT_ETH) {
            orderFlags |= 2; // EXTRACT_ETH
        }
        orderId = DelayedExchangePool(pool).addOrder(to, orderFlags, prevByStopLoss, prevByTimeout, minAmountOut, time);
        // TODO: add optional checking if prevByStopLoss/prevByTimeout matched provided values
        DelayedSwap(tokenIn, amountIn, tokenOut, minAmountOut, to, convertETH, uint16(time), uint64(orderId));
    }

    function delayedSwap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        address to,
        uint256 timeout,
        uint256 prevByStopLoss,
        uint256 prevByTimeout
    ) external override returns (uint256 orderId) {
        require(tokenOut != address(0), "LIQUIFI: INVALID TOKEN OUT");
        return
            _delayedSwap(
                tokenIn,
                amountIn,
                tokenOut,
                minAmountOut,
                to,
                ConvertETH.NONE,
                timeout,
                prevByStopLoss,
                prevByTimeout
            );
    }

    function delayedSwapFromETH(
        address tokenOut,
        uint256 minAmountOut,
        address to,
        uint256 timeout,
        uint256 prevByStopLoss,
        uint256 prevByTimeout
    ) external payable override returns (uint256 orderId) {
        uint256 amountETH = msg.value;
        weth.deposit{value: amountETH}();
        require(weth.approve(address(this), amountETH), "LIQUIFI: WETH_APPROVAL_FAILED");

        return
            _delayedSwap(
                address(weth),
                amountETH,
                tokenOut,
                minAmountOut,
                to,
                ConvertETH.IN_ETH,
                timeout,
                prevByStopLoss,
                prevByTimeout
            );
    }

    function delayedSwapToETH(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        uint256 timeout,
        uint256 prevByStopLoss,
        uint256 prevByTimeout
    ) external override returns (uint256 orderId) {
        orderId = _delayedSwap(
            tokenIn,
            amountIn,
            address(weth),
            minAmountOut,
            to,
            ConvertETH.OUT_ETH,
            timeout,
            prevByStopLoss,
            prevByTimeout
        );
    }

    function processDelayedOrders(
        address token1,
        address token2,
        uint256 timeout
    ) external override beforeTimeout(timeout) returns (uint256 availableBalance1, uint256 availableBalance2) {
        address pool = factory.findPool(token1, token2);
        require(pool != address(0), "LIQIFI: PROCESS_DELAYED_ORDERS_ON_INVALID_POOL");
        uint256 availableBalance;
        (availableBalance, , ) = DelayedExchangePool(pool).processDelayedOrders();
        uint256 availableBalanceA = uint128(availableBalance >> 128);
        uint256 availableBalanceB = uint128(availableBalance);
        (availableBalance1, availableBalance2) = properOrder(token1, token2)
            ? (availableBalanceA, availableBalanceB)
            : (availableBalanceB, availableBalanceA);
    }

    function _claimOrder(
        address token1,
        address token2,
        bytes32 previousBreakHash,
        // see LiquifyPoolRegister.claimOrder for breaks list details
        uint256[] calldata breaks,
        uint256 timeout
    )
        private
        beforeTimeout(timeout)
        returns (
            address to,
            uint256 amountAOut,
            uint256 amountBOut
        )
    {
        address pool = factory.findPool(token1, token2);
        require(pool != address(0), "LIQIFI: CLAIM_ORDER_ON_INVALID_POOL");
        (to, amountAOut, amountBOut) = DelayedExchangePool(pool).claimOrder(previousBreakHash, breaks);
        (address tokenA, address tokenB) = properOrder(token1, token2) ? (token1, token2) : (token2, token1);
        uint256 orderId = uint64(breaks[2] >> 80);
        emit OrderClaimed(orderId, tokenA, amountAOut, tokenB, amountBOut, to);
    }

    function claimOrder(
        address tokenIn,
        address tokenOut,
        bytes32 previousBreakHash,
        // data from FlowBreakEvent events should be passed in this array
        // first event is the one related to order creation (having finalizing orderId and reason = ORDER_ADDED)
        // last event is the one related to order closing  (having finalizing orderId and reason = ORDER_TIMEOUT|ORDER_STOP_LOSS)
        // 3 256bit variable per event are packed in one list to reduce stack depth:
        // availableBalance (0), flowSpeed (1), others (2)
        // availableBalance consists of 128 bits of availableBalanceA and 128 bits of availableBalanceB
        // flowSpeed consists of 144 bits of poolFlowSpeedA and 112 higher bits of poolFlowSpeedB
        // others consists of 32 lower bits of poolFlowSpeedB, 16 bit of notFee, 64 bit of time, 64 bit of orderId, 76 higher bits of packed and 4 bit of reason (BreakReason)
        uint256[] calldata breaksHistory,
        uint256 timeout
    )
        external
        override
        returns (
            address to,
            uint256 amountOut,
            uint256 amountRefund
        )
    {
        uint256 amountAOut;
        uint256 amountBOut;
        (to, amountAOut, amountBOut) = _claimOrder(tokenIn, tokenOut, previousBreakHash, breaksHistory, timeout);
        (amountOut, amountRefund) = properOrder(tokenIn, tokenOut)
            ? (amountBOut, amountAOut)
            : (amountAOut, amountBOut);
    }

    function claimOrderWithETH(
        address token,
        bytes32 previousBreakHash,
        // see LiquifyPoolRegister.claimOrder for breaks list details
        uint256[] calldata breaksHistory,
        uint256 timeout
    )
        external
        override
        returns (
            address to,
            uint256 amountETHOut,
            uint256 amountTokenOut
        )
    {
        return _claimOrder(address(weth), token, previousBreakHash, breaksHistory, timeout);
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 notFee
    ) private pure returns (uint256 amountOut) {
        require(balanceOut > 0, "LIQIFI: INSUFFICIENT_LIQUIDITY_OUT");
        require(balanceIn > 0, "LIQIFI: INSUFFICIENT_LIQUIDITY_IN");
        uint256 amountInWithFee = amountIn.mul(notFee);
        uint256 numerator = amountInWithFee.mul(balanceOut);
        uint256 denominator = balanceIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    function getAmountsOut(
        address pool,
        bool isTokenAIn,
        uint256 amountIn,
        uint256 minAmountOut
    )
        private
        returns (
            uint256 amountAOut,
            uint256 amountBOut,
            uint256 fee
        )
    {
        (uint256 availableBalance, uint256 delayedSwapsIncome, uint256 packed) =
            DelayedExchangePool(pool).processDelayedOrders();
        uint256 availableBalanceA = uint128(availableBalance >> 128);
        uint256 availableBalanceB = uint128(availableBalance);
        uint256 instantSwapFee = unpackGovernance(packed);

        uint256 amountOut;
        if (isTokenAIn) {
            amountOut = getAmountOut(amountIn, availableBalanceA, availableBalanceB, 1000);
            if (swapPaysFee(availableBalance, delayedSwapsIncome, 0, amountOut)) {
                amountOut = getAmountOut(amountIn, availableBalanceA, availableBalanceB, 1000 - instantSwapFee);
                fee = instantSwapFee;
            }
            amountBOut = amountOut;
        } else {
            amountOut = getAmountOut(amountIn, availableBalanceB, availableBalanceA, 1000);
            if (swapPaysFee(availableBalance, delayedSwapsIncome, amountOut, 0)) {
                amountOut = getAmountOut(amountIn, availableBalanceB, availableBalanceA, 1000 - instantSwapFee);
                fee = instantSwapFee;
            }
            amountAOut = amountOut;
        }
        require(amountOut >= minAmountOut, "LIQIFI: INSUFFICIENT_OUTPUT_AMOUNT");
    }

    function swapPaysFee(
        uint256 availableBalance,
        uint256 delayedSwapsIncome,
        uint256 amountAOut,
        uint256 amountBOut
    ) private pure returns (bool) {
        uint256 availableBalanceA = uint128(availableBalance >> 128);
        uint256 availableBalanceB = uint128(availableBalance);

        uint256 delayedSwapsIncomeA = uint128(delayedSwapsIncome >> 128);
        uint256 delayedSwapsIncomeB = uint128(delayedSwapsIncome);

        uint256 exceedingAIncome =
            availableBalanceB == 0
                ? 0
                : uint256(delayedSwapsIncomeA).subWithClip(
                    (uint256(delayedSwapsIncomeB) * availableBalanceA) / availableBalanceB
                );
        uint256 exceedingBIncome =
            availableBalanceA == 0
                ? 0
                : uint256(delayedSwapsIncomeB).subWithClip(
                    (uint256(delayedSwapsIncomeA) * availableBalanceB) / availableBalanceA
                );

        return amountAOut > exceedingAIncome || amountBOut > exceedingBIncome;
    }

    function unpackGovernance(uint256 packed) internal pure returns (uint8 instantSwapFee) {
        instantSwapFee = uint8(packed >> 88);
    }
}
