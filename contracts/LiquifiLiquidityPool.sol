// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import {Math} from "./libraries/Math.sol";
import {Liquifi} from "./libraries/Liquifi.sol";
import {ERC20} from "./interfaces/ERC20.sol";
import {WETH} from "./interfaces/WETH.sol";
import {LiquidityPool} from "./interfaces/LiquidityPool.sol";
import {LiquifiToken} from "./LiquifiToken.sol";
import {LiquifiCallee} from "./interfaces/LiquifiCallee.sol";
import {GovernanceRouter} from "./interfaces/GovernanceRouter.sol";

abstract contract LiquifiLiquidityPool is LiquidityPool, LiquifiToken {
    using Math for uint256;

    uint8 public constant override decimals = 18;
    uint256 public constant override minimumLiquidity = 10**3;
    string public constant override name = "Liquifi Pool Token";

    ERC20 public immutable override tokenA;
    ERC20 public immutable override tokenB;
    bool public immutable override aIsWETH;
    GovernanceRouter public immutable override governanceRouter;

    Liquifi.PoolBalances internal savedBalances;

    receive() external payable {
        assert(msg.sender == address(tokenA) && aIsWETH);
    }

    constructor(
        address tokenAAddress,
        address tokenBAddress,
        bool _aIsWETH,
        address _governanceRouter
    ) {
        Liquifi._require(
            tokenAAddress != tokenBAddress && tokenAAddress != address(0) && tokenBAddress != address(0),
            Liquifi.Error.T_INVALID_TOKENS_PAIR,
            Liquifi.ErrorArg.A_NONE
        );

        tokenA = ERC20(tokenAAddress);
        tokenB = ERC20(tokenBAddress);
        aIsWETH = _aIsWETH;
        governanceRouter = GovernanceRouter(_governanceRouter);
    }

    function poolBalances()
        external
        view
        override
        returns (
            uint256 balanceALocked,
            uint256 poolFlowSpeedA, // flow speed: (amountAIn * 2^32)/second
            uint256 balanceBLocked,
            uint256 poolFlowSpeedB, // flow speed: (amountBIn * 2^32)/second
            uint256 totalBalanceA,
            uint256 totalBalanceB,
            uint256 delayedSwapsIncome,
            uint256 rootKLastTotalSupply
        )
    {
        balanceALocked = savedBalances.balanceALocked;
        poolFlowSpeedA = savedBalances.poolFlowSpeedA;

        balanceBLocked = savedBalances.balanceBLocked;
        poolFlowSpeedB = savedBalances.poolFlowSpeedB;

        totalBalanceA = savedBalances.totalBalanceA;
        totalBalanceB = savedBalances.totalBalanceB;

        delayedSwapsIncome = savedBalances.delayedSwapsIncome;
        rootKLastTotalSupply = savedBalances.rootKLastTotalSupply;
    }

    function actualizeBalances(Liquifi.ErrorArg location)
        internal
        virtual
        returns (
            Liquifi.PoolBalances memory _balances,
            Liquifi.PoolState memory _state,
            uint256 availableBalanceA,
            uint256 availableBalanceB
        );

    function changedBalances(
        BreakReason reason,
        Liquifi.PoolBalances memory _balances,
        Liquifi.PoolState memory _state,
        uint256 orderId
    ) internal virtual;

    function smartTransfer(
        address token,
        address to,
        uint256 value,
        Liquifi.ErrorArg tokenType
    ) internal {
        bool success;
        if (tokenType == Liquifi.ErrorArg.Q_TOKEN_ETH) {
            WETH(token).withdraw(value);
            (success, ) = to.call{value: value}(new bytes(0)); // TransferETH
        } else {
            bytes memory data;
            (success, data) = token.call(
                abi.encodeWithSelector(
                    0xa9059cbb, // bytes4(keccak256(bytes('transfer(address,uint256)')));
                    to,
                    value
                )
            );
            success = success && (data.length == 0 || abi.decode(data, (bool)));
        }

        Liquifi._require(success, Liquifi.Error.U_TOKEN_TRANSFER_FAILED, tokenType);
    }

    function mintProtocolFee(
        uint256 availableBalanceA,
        uint256 availableBalanceB,
        Liquifi.PoolBalances memory _balances,
        Liquifi.PoolState memory _state
    ) private returns (uint256 _totalSupply, uint256 protocolFee) {
        uint256 rootKLastTotalSupply = _balances.rootKLastTotalSupply;
        _totalSupply = uint128(rootKLastTotalSupply);
        uint256 _rootKLast = uint128(rootKLastTotalSupply >> 128);
        Liquifi.setFlag(_state, Liquifi.Flag.TOTAL_SUPPLY_DIRTY);
        (, , protocolFee, , ) = Liquifi.unpackGovernance(_state);

        if (protocolFee != 0) {
            if (_rootKLast != 0) {
                uint256 rootK = Math.sqrt(uint256(availableBalanceA).mul(availableBalanceB));
                if (rootK > _rootKLast) {
                    uint256 numerator = _totalSupply.mul(rootK.subWithClip(_rootKLast));
                    uint256 denominator = (rootK.mul(1000 - protocolFee) / protocolFee).add(_rootKLast);
                    uint256 liquidity = numerator / denominator;

                    if (liquidity > 0) {
                        address protocolFeeReceiver = governanceRouter.protocolFeeReceiver();
                        _totalSupply = _mint(protocolFeeReceiver, liquidity, _totalSupply, MintReason.PROTOCOL_FEE);
                    }
                }
            }
        }
    }

    function _mint(
        address to,
        uint256 liquidity,
        uint256 _totalSupply,
        MintReason reason
    ) private returns (uint256) {
        emit Mint(to, liquidity, reason);
        accountBalances[to] += liquidity;
        return _totalSupply.add(liquidity);
    }

    function updateTotalSupply(
        Liquifi.PoolBalances memory _balances,
        uint256 totalSupply,
        uint256 protocolFee
    ) private pure {
        uint256 availableBalanceA = Math.subWithClip(_balances.totalBalanceA, _balances.balanceALocked);
        uint256 availableBalanceB = Math.subWithClip(_balances.totalBalanceB, _balances.balanceBLocked);
        uint256 K = availableBalanceA.mul(availableBalanceB);

        _balances.rootKLastTotalSupply = ((protocolFee == 0 ? 0 : uint256(uint128(Math.sqrt(K))) << 128) |
            Liquifi.trimTotal(totalSupply, Liquifi.ErrorArg.X_TOTAL_SUPPLY));
    }

    function mint(address to) external override returns (uint256 liquidity) {
        (
            Liquifi.PoolBalances memory _balances,
            Liquifi.PoolState memory _state,
            uint256 availableBalanceA,
            uint256 availableBalanceB
        ) = actualizeBalances(Liquifi.ErrorArg.K_IN_MINT);
        {
            Liquifi.ErrorArg invalidState = Liquifi.checkInvalidState(_state);
            Liquifi._require(
                invalidState <= Liquifi.ErrorArg.T_FEE_CHANGED_WITH_ORDERS_OPEN,
                Liquifi.Error.J_INVALID_POOL_STATE,
                invalidState
            );
        }

        (uint256 _totalSupply, uint256 protocolFee) =
            mintProtocolFee(availableBalanceA, availableBalanceB, _balances, _state);

        uint256 amountA = tokenA.balanceOf(address(this)).subWithClip(_balances.totalBalanceA);
        uint256 amountB = tokenB.balanceOf(address(this)).subWithClip(_balances.totalBalanceB);

        liquidity = (_totalSupply == 0)
            ? Math.sqrt(amountA.mul(amountB)).subWithClip(minimumLiquidity)
            : Math.min(
                (amountA.mul(_totalSupply)) / availableBalanceA,
                (amountB.mul(_totalSupply)) / availableBalanceB
            );

        Liquifi._require(liquidity != 0, Liquifi.Error.L_INSUFFICIENT_LIQUIDITY, Liquifi.ErrorArg.C_OUT_AMOUNT);
        if (_totalSupply == 0) {
            _totalSupply = _mint(address(0), minimumLiquidity, _totalSupply, MintReason.INITIAL_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        }

        _totalSupply = _mint(to, liquidity, _totalSupply, MintReason.DEPOSIT);

        _balances.totalBalanceA = Liquifi.trimTotal(amountA.add(_balances.totalBalanceA), Liquifi.ErrorArg.B_IN_AMOUNT);
        _balances.totalBalanceB = Liquifi.trimTotal(amountB.add(_balances.totalBalanceB), Liquifi.ErrorArg.B_IN_AMOUNT);
        Liquifi.setFlag(_state, Liquifi.Flag.TOTALS_DIRTY);

        updateTotalSupply(_balances, _totalSupply, protocolFee);
        changedBalances(BreakReason.MINT, _balances, _state, 0);
    }

    function burn(address to, bool extractETH) external override returns (uint256 amountA, uint256 amountB) {
        (
            Liquifi.PoolBalances memory _balances,
            Liquifi.PoolState memory _state,
            uint256 availableBalanceA,
            uint256 availableBalanceB
        ) = actualizeBalances(Liquifi.ErrorArg.L_IN_BURN);
        uint256 liquidity = Liquifi.trimAmount(balanceOf(address(this)), Liquifi.ErrorArg.B_IN_AMOUNT);

        (uint256 _totalSupply, uint256 protocolFee) =
            mintProtocolFee(availableBalanceA, availableBalanceB, _balances, _state);

        Liquifi._require(_totalSupply != 0, Liquifi.Error.L_INSUFFICIENT_LIQUIDITY, Liquifi.ErrorArg.L_IN_BURN);

        amountA = liquidity.mul(availableBalanceA) / _totalSupply;
        amountB = liquidity.mul(availableBalanceB) / _totalSupply;

        Liquifi._require(amountA * amountB != 0, Liquifi.Error.L_INSUFFICIENT_LIQUIDITY, Liquifi.ErrorArg.B_IN_AMOUNT);

        ERC20 _tokenA = tokenA; // gas savings
        ERC20 _tokenB = tokenB; // gas savings

        accountBalances[address(this)] = 0;
        _totalSupply = _totalSupply.subWithClip(liquidity);

        smartTransfer(
            address(_tokenA),
            to,
            amountA,
            (extractETH && aIsWETH) ? Liquifi.ErrorArg.Q_TOKEN_ETH : Liquifi.ErrorArg.O_TOKEN_A
        );
        smartTransfer(address(_tokenB), to, amountB, Liquifi.ErrorArg.P_TOKEN_B);

        _balances.totalBalanceA = Liquifi.trimTotal(_tokenA.balanceOf(address(this)), Liquifi.ErrorArg.O_TOKEN_A);
        _balances.totalBalanceB = Liquifi.trimTotal(_tokenB.balanceOf(address(this)), Liquifi.ErrorArg.P_TOKEN_B);
        Liquifi.setFlag(_state, Liquifi.Flag.TOTALS_DIRTY);

        updateTotalSupply(_balances, _totalSupply, protocolFee);
        changedBalances(BreakReason.BURN, _balances, _state, 0);
    }

    function splitDelayedSwapsIncome(uint256 delayedSwapsIncome)
        internal
        pure
        returns (uint256 delayedSwapsIncomeA, uint256 delayedSwapsIncomeB)
    {
        delayedSwapsIncomeA = uint128(delayedSwapsIncome >> 128);
        delayedSwapsIncomeB = uint128(delayedSwapsIncome);
    }

    function subDelayedSwapsIncome(
        Liquifi.PoolBalances memory _balances,
        Liquifi.PoolState memory _state,
        uint256 subA,
        uint256 subB
    ) internal pure {
        if (_balances.delayedSwapsIncome != 0) {
            (uint256 delayedSwapsIncomeA, uint256 delayedSwapsIncomeB) =
                splitDelayedSwapsIncome(_balances.delayedSwapsIncome);
            _balances.delayedSwapsIncome =
                (Math.subWithClip(delayedSwapsIncomeA, subA) << 128) |
                Math.subWithClip(delayedSwapsIncomeB, subB);
            Liquifi.setFlag(_state, Liquifi.Flag.SWAPS_INCOME_DIRTY);
        }
    }

    function swap(
        address to,
        bool extractETH,
        uint256 amountAOut,
        uint256 amountBOut,
        bytes calldata externalData
    ) external override returns (uint256 amountAIn, uint256 amountBIn) {
        uint256 availableBalanceA;
        uint256 availableBalanceB;
        Liquifi.PoolBalances memory _balances;
        Liquifi.PoolState memory _state;
        (_balances, _state, availableBalanceA, availableBalanceB) = actualizeBalances(Liquifi.ErrorArg.F_IN_SWAP);
        {
            Liquifi.ErrorArg invalidState = Liquifi.checkInvalidState(_state);
            Liquifi._require(
                invalidState <= Liquifi.ErrorArg.T_FEE_CHANGED_WITH_ORDERS_OPEN,
                Liquifi.Error.J_INVALID_POOL_STATE,
                invalidState
            );
        }
        uint256 instantNotFee = 1000;
        {
            // set fee to zero if new order doesn't exceed current limits
            (uint256 delayedSwapsIncomeA, uint256 delayedSwapsIncomeB) =
                splitDelayedSwapsIncome(_balances.delayedSwapsIncome);
            uint256 exceedingAIncome =
                availableBalanceB == 0
                    ? 0
                    : delayedSwapsIncomeA.subWithClip((delayedSwapsIncomeB * availableBalanceA) / availableBalanceB);
            uint256 exceedingBIncome =
                availableBalanceA == 0
                    ? 0
                    : delayedSwapsIncomeB.subWithClip((delayedSwapsIncomeA * availableBalanceB) / availableBalanceA);

            if (amountAOut > exceedingAIncome || amountBOut > exceedingBIncome) {
                (uint256 instantFee, , , , ) = Liquifi.unpackGovernance(_state);
                instantNotFee -= instantFee;
            }
        }

        Liquifi._require(
            amountAOut | amountBOut != 0,
            Liquifi.Error.F_ZERO_AMOUNT_VALUE,
            Liquifi.ErrorArg.C_OUT_AMOUNT
        );
        Liquifi._require(
            amountAOut < availableBalanceA && amountBOut < availableBalanceB,
            Liquifi.Error.E_TOO_BIG_AMOUNT_VALUE,
            Liquifi.ErrorArg.C_OUT_AMOUNT
        );

        {
            // localize variables to reduce stack depth
            // optimistically transfer tokens
            if (amountAOut > 0) {
                smartTransfer(
                    address(tokenA),
                    to,
                    amountAOut,
                    (extractETH && aIsWETH) ? Liquifi.ErrorArg.Q_TOKEN_ETH : Liquifi.ErrorArg.O_TOKEN_A
                );
                _balances.totalBalanceA = uint128(Math.subWithClip(_balances.totalBalanceA, amountAOut));
            }
            if (amountBOut > 0) {
                smartTransfer(address(tokenB), to, amountBOut, Liquifi.ErrorArg.P_TOKEN_B);
                _balances.totalBalanceB = uint128(Math.subWithClip(_balances.totalBalanceB, amountBOut));
            }

            if (externalData.length > 0) {
                uint256 availableBalance = (availableBalanceA << 128) | availableBalanceB;
                // flash swap, also allows to execute swap without pror call of processDelayedOrders
                LiquifiCallee(to).onLiquifiSwap(
                    externalData,
                    msg.sender,
                    availableBalance,
                    _balances.delayedSwapsIncome,
                    instantNotFee
                );
            }

            {
                // compute amountIn and update totalBalance
                uint256 newTotalBalance;
                newTotalBalance = tokenA.balanceOf(address(this));
                amountAIn = Liquifi.trimAmount(
                    newTotalBalance.subWithClip(_balances.totalBalanceA),
                    Liquifi.ErrorArg.B_IN_AMOUNT
                );
                _balances.totalBalanceA = Liquifi.trimTotal(newTotalBalance, Liquifi.ErrorArg.O_TOKEN_A);

                newTotalBalance = tokenB.balanceOf(address(this));
                amountBIn = Liquifi.trimAmount(
                    newTotalBalance.subWithClip(_balances.totalBalanceB),
                    Liquifi.ErrorArg.B_IN_AMOUNT
                );
                _balances.totalBalanceB = Liquifi.trimTotal(newTotalBalance, Liquifi.ErrorArg.P_TOKEN_B);

                Liquifi.setFlag(_state, Liquifi.Flag.TOTALS_DIRTY);
            }
        }

        subDelayedSwapsIncome(_balances, _state, amountAOut, amountBOut);

        Liquifi._require(amountAIn | amountBIn != 0, Liquifi.Error.F_ZERO_AMOUNT_VALUE, Liquifi.ErrorArg.B_IN_AMOUNT);

        {
            // check invariant
            uint256 newBalanceA = availableBalanceA.subWithClip(amountAOut).mul(1000);
            newBalanceA = newBalanceA.add(amountAIn * instantNotFee);
            uint256 newBalanceB = availableBalanceB.subWithClip(amountBOut).mul(1000);
            newBalanceB = newBalanceB.add(amountBIn * instantNotFee);

            Liquifi._require(
                newBalanceA.mul(newBalanceB) >= availableBalanceA.mul(availableBalanceB).mul(1000**2),
                Liquifi.Error.J_INVALID_POOL_STATE,
                Liquifi.ErrorArg.F_IN_SWAP
            );
        }

        changedBalances(BreakReason.SWAP, _balances, _state, 0);
    }
}
