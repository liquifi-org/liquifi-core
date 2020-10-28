// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.0;
import { WETH } from './WETH.sol';
import { PoolFactory } from "./PoolFactory.sol";

enum ConvertETH { NONE, IN_ETH, OUT_ETH }

interface PoolRegister {
    event Mint(address token1, uint amount1, address token2, uint amount2, uint liquidityOut, address to, ConvertETH convertETH);
    event Burn(address token1, uint amount1, address token2, uint amount2, uint liquidityIn, address to, ConvertETH convertETH);
    event Swap(address tokenIn, uint amountIn, address tokenOut, uint amountOut, address to, ConvertETH convertETH, uint fee);
    event DelayedSwap(address tokenIn, uint amountIn, address tokenOut, uint minAmountOut, address to, ConvertETH convertETH, uint16 period, uint64 orderId);
    event OrderClaimed(uint orderId, address tokenA, uint amountAOut, address tokenB, uint amountBOut, address to);

    function factory() external view returns (PoolFactory);
    function weth() external view returns (WETH);
    
    function deposit(address token1, uint amount1, address token2, uint amount2, address to, uint timeout) 
        external returns (uint liquidityOut, uint amount1Used, uint amount2Used);
    function depositWithETH(address token, uint amount, address to, uint timeout) 
        payable external returns (uint liquidityOut, uint amountETHUsed, uint amountTokenUsed);
    
    function withdraw(address token1, address token2, uint liquidity, address to, uint timeout) external returns (uint amount1, uint amount2);
    function withdrawWithETH(address token1, uint liquidityIn, address to, uint timeout) external returns (uint amount1, uint amountETH);

    function swap(address tokenIn, uint amountIn, address tokenOut, uint minAmountOut, address to, uint timeout) external returns (uint amountOut);
    function swapFromETH(address tokenOut, uint minAmountOut, address to, uint timeout) payable external returns (uint amountOut);
    function swapToETH(address tokenIn, uint amountIn, uint minAmountOut, address to, uint timeout) external returns (uint amountETHOut);

    function delayedSwap(
        address tokenIn, uint amountIn, address tokenOut, uint minAmountOut, address to, uint timeout,
        uint prevByStopLoss, uint prevByTimeout
    ) external returns (uint orderId);
    function delayedSwapFromETH(
        address tokenOut, uint minAmountOut, address to, uint timeout, 
        uint prevByStopLoss, uint prevByTimeout
    ) external payable returns (uint orderId);
    function delayedSwapToETH(address tokenIn, uint amountIn, uint minAmountOut, address to, uint timeout,
        uint prevByStopLoss, uint prevByTimeout
    ) external returns (uint orderId);

    function processDelayedOrders(address token1, address token2, uint timeout) external returns (uint availableBalanceA, uint availableBalanceB);

    function claimOrder(
        address tokenIn, address tokenOut,
        bytes32 previousBreakHash,
        // see LiquifyPoolRegister.claimOrder for breaks list details
        uint[] calldata breaksHistory,
        uint timeout
    ) external returns (address to, uint amountOut, uint amountRefund);

    function claimOrderWithETH(
        address token,
        bytes32 previousBreakHash,
        // see LiquifyPoolRegister.claimOrder for breaks list details
        uint[] calldata breaksHistory,
        uint timeout
    ) external returns (address to, uint amountOut, uint amountRefund);
}