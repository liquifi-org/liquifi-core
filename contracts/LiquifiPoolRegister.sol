// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.0;

import { PoolFactory } from "./interfaces/PoolFactory.sol";
import { DelayedExchangePool } from "./interfaces/DelayedExchangePool.sol";
import { PoolRegister, ConvertETH } from "./interfaces/PoolRegister.sol";
import { ERC20 } from "./interfaces/ERC20.sol";
//import { Debug } from "./libraries/Debug.sol";
import { Math } from "./libraries/Math.sol";
import { WETH } from './interfaces/WETH.sol';
import { GovernanceRouter } from "./interfaces/GovernanceRouter.sol";

contract LiquifiPoolRegister is PoolRegister  {
    PoolFactory public immutable override factory;
    WETH public immutable override weth;

    using Math for uint256;

    modifier beforeTimeout(uint timeout) {
        require(timeout >= block.timestamp, 'LIQUIFI: EXPIRED CALL');
        _;
    }

    constructor (address _governanceRouter) public {
        factory = GovernanceRouter(_governanceRouter).poolFactory();
        weth = GovernanceRouter(_governanceRouter).weth();
    }

    receive() external payable {
        assert(msg.sender == address(weth));
    }

    function smartTransferFrom(address token, address to, uint value, ConvertETH convertETH) internal {
        address from = (token == address(weth) && convertETH == ConvertETH.IN_ETH) ? address(this) : msg.sender;

        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(
            ERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'LIQUIFI: TRANSFER_FROM_FAILED');
    }

    function smartTransfer(address token, address to, uint value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(
            ERC20.transfer.selector, to, value));
        success = success && (data.length == 0 || abi.decode(data, (bool)));

        require(success, "LIQUIFI: TOKEN_TRANSFER_FAILED");
    }

    function smartTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'LIQUIFI: ETH_TRANSFER_FAILED');
    }

    // Registry always creates pools with tokens in proper order
    function properOrder(address tokenA, address tokenB) view private returns (bool) {
        return (tokenA == address(weth) ? address(0) : tokenA) < (tokenB == address(weth) ? address(0) : tokenB);
    }

    function _deposit(address token1, uint amount1, address token2, uint amount2, address to, ConvertETH convertETH, uint timeout) 
        private beforeTimeout(timeout) returns (uint liquidityOut, uint amountA, uint amountB) {
        address pool;
        {
            (address tokenA, address tokenB) = properOrder(token1, token2) ? (token1, token2) : (token2, token1);
            (amountA, amountB) = properOrder(token1, token2) ? (amount1, amount2) : (amount2, amount1);
            pool = factory.getPool(tokenA, tokenB);
        }
        uint availableBalanceA;
        uint availableBalanceB;
        {
            (uint availableBalance, , ) = DelayedExchangePool(pool).processDelayedOrders();
            availableBalanceA = uint128(availableBalance >> 128);
            availableBalanceB = uint128(availableBalance);
        }
        
        if (availableBalanceA != 0 && availableBalanceB != 0) {
            uint amountBOptimal = amountA.mul(availableBalanceB) / availableBalanceA;
            if (amountBOptimal <= amountB) {
                //require(amountBOptimal >= amountBMin, 'LIQUIFI: INSUFFICIENT_B_AMOUNT');
                amountB = amountBOptimal;
            } else {
                uint amountAOptimal = amountB.mul(availableBalanceA) / availableBalanceB;
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

    function deposit(address token1, uint amount1, address token2, uint amount2, address to, uint timeout) 
        external override returns (uint liquidityOut, uint amount1Used, uint amount2Used) {
        uint amountA;
        uint amountB;
        (liquidityOut, amountA, amountB) = _deposit(token1, amount1, token2, amount2, to, ConvertETH.NONE, timeout);
        (amount1Used, amount2Used) = properOrder(token1, token2) ? (amountA, amountB) : (amountB, amountA);
    }

    function depositWithETH(address token, uint amount, address to, uint timeout) 
        payable external override returns (uint liquidityOut, uint amountETHUsed, uint amountTokenUsed) {
        uint amountETH = msg.value;
        weth.deposit{value: amountETH}();
        require(weth.approve(address(this), amountETH), "LIQUIFI: WETH_APPROVAL_FAILED");
        (liquidityOut, amountETHUsed, amountTokenUsed) = _deposit(address(weth), amountETH, token, amount, to, ConvertETH.IN_ETH, timeout);
        
        if (amountETH > amountETHUsed) {
            uint refundETH = amountETH - amountETH;
            weth.withdraw(refundETH);
            smartTransferETH(msg.sender, refundETH);
        }
    }

    function _withdraw(address token1, address token2, uint liquidityIn, address to, ConvertETH convertETH, uint timeout) 
        private beforeTimeout(timeout) returns (uint amount1, uint amount2) {
        address pool = factory.findPool(token1, token2);
        require(pool != address(0), "LIQIFI: WITHDRAW_FROM_INVALID_POOL");
        require(
            DelayedExchangePool(pool).transferFrom(msg.sender, pool, liquidityIn),
            "LIQIFI: TRANSFER_FROM_FAILED"
        );
        (uint amountA, uint amountB) = DelayedExchangePool(pool).burn(to, convertETH == ConvertETH.OUT_ETH);
        (amount1, amount2) = properOrder(token1, token2) ? (amountA, amountB) : (amountB, amountA);
        emit Burn(token1, amount1, token2, amount2, liquidityIn, to, convertETH);
    }

    function withdraw(address token1, address token2, uint liquidityIn, address to, uint timeout) 
        external override returns (uint amount1, uint amount2) {
        return _withdraw(token1, token2, liquidityIn, to, ConvertETH.NONE, timeout);
    }

    function withdrawWithETH(address token, uint liquidityIn, address to, uint timeout) 
        external override returns (uint amountToken, uint amountETH) {
        (amountETH, amountToken) = _withdraw(address(weth), token, liquidityIn, to, ConvertETH.OUT_ETH, timeout);
    }

    function _swap(address tokenIn, uint amountIn, address tokenOut, uint minAmountOut, address to, ConvertETH convertETH, uint timeout) 
        private beforeTimeout(timeout) returns (uint amountOut) {
        address pool = factory.findPool(tokenIn, tokenOut);
        require(pool != address(0), "LIQIFI: SWAP_ON_INVALID_POOL");

        smartTransferFrom(tokenIn, pool, amountIn, convertETH);
        
        bool isTokenAIn = properOrder(tokenIn, tokenOut);
        (uint amountAOut, uint amountBOut, uint fee) = getAmountsOut(pool, isTokenAIn, amountIn, minAmountOut);
        DelayedExchangePool(pool).swap(to, convertETH == ConvertETH.OUT_ETH, amountAOut, amountBOut, new bytes(0));
        amountOut = isTokenAIn ? amountBOut : amountAOut;
        emit Swap(tokenIn, amountIn, tokenOut, amountOut, to, convertETH, fee);
    }

    function swap(address tokenIn, uint amountIn, address tokenOut, uint minAmountOut, address to, uint timeout) 
        external override returns (uint amountOut) {
        return _swap(tokenIn, amountIn, tokenOut, minAmountOut, to, ConvertETH.NONE, timeout);
    }

    function swapFromETH(address tokenOut, uint minAmountOut, address to, uint timeout) 
        external payable override returns (uint amountOut) {
        uint amountETH = msg.value;
        weth.deposit{value: amountETH}();
        require(weth.approve(address(this), amountETH), "LIQUIFI: WETH_APPROVAL_FAILED");
        
        return _swap(address(weth), amountETH, tokenOut, minAmountOut, to, ConvertETH.IN_ETH, timeout);
    }

    function swapToETH(address tokenIn, uint amountIn, uint minAmountOut, address to, uint timeout) 
        external override returns (uint amountETHOut) {
        amountETHOut = _swap(tokenIn, amountIn, address(weth), minAmountOut, to, ConvertETH.OUT_ETH, timeout);
    }

    function _delayedSwap(
        address tokenIn, uint amountIn, address tokenOut, uint minAmountOut, address to, ConvertETH convertETH, uint time, 
        uint prevByStopLoss, uint prevByTimeout
    ) private beforeTimeout(time) returns (uint orderId) {
        time -= block.timestamp; // reuse variable to reduce stack size

        address pool = factory.findPool(tokenIn, tokenOut);
        require(pool != address(0), "LIQIFI: DELAYED_SWAP_ON_INVALID_POOL");
        smartTransferFrom(tokenIn, pool, amountIn, convertETH);
        

        uint orderFlags = 0;
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
        address tokenIn, uint amountIn, address tokenOut, uint minAmountOut, address to, uint timeout, 
        uint prevByStopLoss, uint prevByTimeout
    ) external override returns (uint orderId) {
        require(tokenOut != address(0), "LIQUIFI: INVALID TOKEN OUT");
        return _delayedSwap(tokenIn, amountIn, tokenOut, minAmountOut, to, ConvertETH.NONE, timeout, prevByStopLoss, prevByTimeout);
    }

    function delayedSwapFromETH(
        address tokenOut, uint minAmountOut, address to, uint timeout, 
        uint prevByStopLoss, uint prevByTimeout
    ) external payable override returns (uint orderId) {
        uint amountETH = msg.value;
        weth.deposit{value: amountETH}();
        require(weth.approve(address(this), amountETH), "LIQUIFI: WETH_APPROVAL_FAILED");

        return _delayedSwap(address(weth), amountETH, tokenOut, minAmountOut, to, ConvertETH.IN_ETH, timeout, prevByStopLoss, prevByTimeout);
    }

    function delayedSwapToETH(address tokenIn, uint amountIn, uint minAmountOut, address to, uint timeout,
        uint prevByStopLoss, uint prevByTimeout
    ) external override returns (uint orderId) {
        orderId = _delayedSwap(tokenIn, amountIn, address(weth), minAmountOut, to, ConvertETH.OUT_ETH, timeout, prevByStopLoss, prevByTimeout);
    }

    function processDelayedOrders(address token1, address token2, uint timeout) 
        external override beforeTimeout(timeout) returns (uint availableBalance1, uint availableBalance2) {
        address pool = factory.findPool(token1, token2);
        require(pool != address(0), "LIQIFI: PROCESS_DELAYED_ORDERS_ON_INVALID_POOL");
        uint availableBalance;
        (availableBalance, , ) = DelayedExchangePool(pool).processDelayedOrders();
        uint availableBalanceA = uint128(availableBalance >> 128);
        uint availableBalanceB = uint128(availableBalance);
        (availableBalance1, availableBalance2) = properOrder(token1, token2) ? (availableBalanceA, availableBalanceB) : (availableBalanceB, availableBalanceA);
    }

    function _claimOrder(
        address token1, address token2,
        bytes32 previousBreakHash,
        // see LiquifyPoolRegister.claimOrder for breaks list details
        uint[] calldata breaks,
        uint timeout
    ) private beforeTimeout(timeout) returns (address to, uint amountAOut, uint amountBOut) {
        address pool = factory.findPool(token1, token2);
        require(pool != address(0), "LIQIFI: CLAIM_ORDER_ON_INVALID_POOL");
        (to, amountAOut, amountBOut) = DelayedExchangePool(pool).claimOrder(previousBreakHash, breaks);
        (address tokenA, address tokenB) = properOrder(token1, token2) ? (token1, token2) : (token2, token1);
        uint orderId = uint64(breaks[2] >> 80);
        emit OrderClaimed(orderId, tokenA, amountAOut, tokenB, amountBOut, to);
    }
    
    function claimOrder(
        address tokenIn, address tokenOut,
        bytes32 previousBreakHash,
        // data from FlowBreakEvent events should be passed in this array
        // first event is the one related to order creation (having finalizing orderId and reason = ORDER_ADDED)
        // last event is the one related to order closing  (having finalizing orderId and reason = ORDER_TIMEOUT|ORDER_STOP_LOSS)
        // 3 256bit variable per event are packed in one list to reduce stack depth: 
        // availableBalance (0), flowSpeed (1), others (2)
        // availableBalance consists of 128 bits of availableBalanceA and 128 bits of availableBalanceB
        // flowSpeed consists of 144 bits of poolFlowSpeedA and 112 higher bits of poolFlowSpeedB
        // others consists of 32 lower bits of poolFlowSpeedB, 16 bit of notFee, 64 bit of time, 64 bit of orderId, 76 higher bits of packed and 4 bit of reason (BreakReason)
        uint[] calldata breaksHistory,
        uint timeout
    ) external override returns (address to, uint amountOut, uint amountRefund) {
        uint amountAOut;
        uint amountBOut;
        (to, amountAOut, amountBOut) = _claimOrder(tokenIn, tokenOut, previousBreakHash, breaksHistory, timeout);
        (amountOut, amountRefund) = properOrder(tokenIn, tokenOut) ? (amountBOut, amountAOut) : (amountAOut, amountBOut);
    }

    function claimOrderWithETH(
        address token,
        bytes32 previousBreakHash,
        // see LiquifyPoolRegister.claimOrder for breaks list details
        uint[] calldata breaksHistory,
        uint timeout
    ) external override returns (address to, uint amountETHOut, uint amountTokenOut) {
        return _claimOrder(address(weth), token, previousBreakHash, breaksHistory, timeout);
    }

    function getAmountOut(uint amountIn, uint balanceIn, uint balanceOut, uint notFee) private pure returns (uint amountOut) {
        require(balanceOut > 0, 'LIQIFI: INSUFFICIENT_LIQUIDITY_OUT');
        require(balanceIn > 0, 'LIQIFI: INSUFFICIENT_LIQUIDITY_IN');
        uint amountInWithFee = amountIn.mul(notFee);
        uint numerator = amountInWithFee.mul(balanceOut);
        uint denominator = balanceIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    function getAmountsOut(address pool, bool isTokenAIn, uint amountIn, uint minAmountOut) private returns (uint amountAOut, uint amountBOut, uint fee) {
        (uint availableBalance, uint delayedSwapsIncome, uint packed) = DelayedExchangePool(pool).processDelayedOrders();
        uint availableBalanceA = uint128(availableBalance >> 128);
        uint availableBalanceB = uint128(availableBalance);
        (uint instantSwapFee) = unpackGovernance(packed);

        uint amountOut;
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

    function swapPaysFee(uint availableBalance, uint delayedSwapsIncome, uint amountAOut, uint amountBOut) private pure returns (bool) {
        uint availableBalanceA = uint128(availableBalance >> 128);
        uint availableBalanceB = uint128(availableBalance);

        uint delayedSwapsIncomeA = uint128(delayedSwapsIncome >> 128);
        uint delayedSwapsIncomeB = uint128(delayedSwapsIncome);
        
        uint exceedingAIncome = availableBalanceB == 0 ? 0 : uint(delayedSwapsIncomeA).subWithClip(uint(delayedSwapsIncomeB) * availableBalanceA / availableBalanceB);
        uint exceedingBIncome = availableBalanceA == 0 ? 0 : uint(delayedSwapsIncomeB).subWithClip(uint(delayedSwapsIncomeA) * availableBalanceB / availableBalanceA);
        
        return amountAOut > exceedingAIncome || amountBOut > exceedingBIncome;
    }

    function unpackGovernance(uint packed) internal pure returns(
        uint8 instantSwapFee
    ) {
        instantSwapFee = uint8(packed >> 88);
    }
}