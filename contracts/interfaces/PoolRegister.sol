// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;
import {WETH} from "./WETH.sol";
import {PoolFactory} from "./PoolFactory.sol";

enum ConvertETH {NONE, IN_ETH, OUT_ETH}

interface PoolRegister {
    event Mint(
        address token1,
        uint256 amount1,
        address token2,
        uint256 amount2,
        uint256 liquidityOut,
        address to,
        ConvertETH convertETH
    );
    event Burn(
        address token1,
        uint256 amount1,
        address token2,
        uint256 amount2,
        uint256 liquidityIn,
        address to,
        ConvertETH convertETH
    );
    event Swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        address to,
        ConvertETH convertETH,
        uint256 fee
    );
    event DelayedSwap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        address to,
        ConvertETH convertETH,
        uint16 period,
        uint64 orderId
    );
    event OrderClaimed(
        uint256 orderId,
        address tokenA,
        uint256 amountAOut,
        address tokenB,
        uint256 amountBOut,
        address to
    );

    function factory() external view returns (PoolFactory);

    function weth() external view returns (WETH);

    function deposit(
        address token1,
        uint256 amount1,
        address token2,
        uint256 amount2,
        address to,
        uint256 timeout
    )
        external
        returns (
            uint256 liquidityOut,
            uint256 amount1Used,
            uint256 amount2Used
        );

    function depositWithETH(
        address token,
        uint256 amount,
        address to,
        uint256 timeout
    )
        external
        payable
        returns (
            uint256 liquidityOut,
            uint256 amountETHUsed,
            uint256 amountTokenUsed
        );

    function withdraw(
        address token1,
        address token2,
        uint256 liquidity,
        address to,
        uint256 timeout
    ) external returns (uint256 amount1, uint256 amount2);

    function withdrawWithETH(
        address token1,
        uint256 liquidityIn,
        address to,
        uint256 timeout
    ) external returns (uint256 amount1, uint256 amountETH);

    function swap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        address to,
        uint256 timeout
    ) external returns (uint256 amountOut);

    function swapFromETH(
        address tokenOut,
        uint256 minAmountOut,
        address to,
        uint256 timeout
    ) external payable returns (uint256 amountOut);

    function swapToETH(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        uint256 timeout
    ) external returns (uint256 amountETHOut);

    function delayedSwap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        address to,
        uint256 timeout,
        uint256 prevByStopLoss,
        uint256 prevByTimeout
    ) external returns (uint256 orderId);

    function delayedSwapFromETH(
        address tokenOut,
        uint256 minAmountOut,
        address to,
        uint256 timeout,
        uint256 prevByStopLoss,
        uint256 prevByTimeout
    ) external payable returns (uint256 orderId);

    function delayedSwapToETH(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        uint256 timeout,
        uint256 prevByStopLoss,
        uint256 prevByTimeout
    ) external returns (uint256 orderId);

    function processDelayedOrders(
        address token1,
        address token2,
        uint256 timeout
    ) external returns (uint256 availableBalanceA, uint256 availableBalanceB);

    function claimOrder(
        address tokenIn,
        address tokenOut,
        bytes32 previousBreakHash,
        // see LiquifyPoolRegister.claimOrder for breaks list details
        uint256[] calldata breaksHistory,
        uint256 timeout
    )
        external
        returns (
            address to,
            uint256 amountOut,
            uint256 amountRefund
        );

    function claimOrderWithETH(
        address token,
        bytes32 previousBreakHash,
        // see LiquifyPoolRegister.claimOrder for breaks list details
        uint256[] calldata breaksHistory,
        uint256 timeout
    )
        external
        returns (
            address to,
            uint256 amountOut,
            uint256 amountRefund
        );
}
