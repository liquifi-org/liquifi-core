// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import "./interfaces/ActivityReporter.sol";
import "./interfaces/GovernanceRouter.sol";
import "./interfaces/DelayedExchangePool.sol";
import "@eth-optimism/contracts/build/contracts/iOVM/bridge/iOVM_BaseCrossDomainMessenger.sol";

contract LiquifiActivityReporter is ActivityReporter {
    uint32 private constant GAS_LIMIT = 9000000; //FIXME: calculate actual gas limit for every method

    address private constant l2Messenger = 0x6418E5Da52A3d7543d393ADD3Fa98B0795d27736;
    address private immutable activityMeter;
    GovernanceRouter private immutable governanceRouter;

    constructor(
        address _governanceRouter,
        address _activityMeter
    ) {
        activityMeter = _activityMeter;
        governanceRouter = GovernanceRouter(_governanceRouter);
        GovernanceRouter(_governanceRouter).setActivityReporter(this);
    }

    function liquidityEthPriceChanged(
        uint256 effectiveTime,
        uint256 availableBalanceEth,
        uint256 totalSupply
    ) external override {
        verifyPool(msg.sender);
        bytes memory messageData =
            abi.encodeWithSelector(
                ActivityMeter.liquidityEthPriceChanged.selector,
                msg.sender,
                effectiveTime,
                availableBalanceEth,
                totalSupply
            );
        messenger().sendMessage(activityMeter, messageData, GAS_LIMIT);
        emit LiquidityETHPriceChanged(msg.sender);
    }

    // this method should be called by the user
    function deposit(address pool, uint128 amount) external override {
        registerUserPool(pool);
        bytes memory messageData = abi.encodeWithSelector(ActivityMeter.deposit.selector, msg.sender, pool, amount);
        messenger().sendMessage(activityMeter, messageData, GAS_LIMIT);
        emit Deposit(msg.sender, pool, amount);
    }

    // this method should be called by the user
    function withdraw(address pool, uint128 amount) external override {
        registerUserPool(pool);
        bytes memory messageData = abi.encodeWithSelector(ActivityMeter.withdraw.selector, msg.sender, pool, amount);
        messenger().sendMessage(activityMeter, messageData, GAS_LIMIT);
        emit Withdraw(msg.sender, pool, amount);
    }

    function registerUserPool(address pool) private {
        (address tokenA, ) = verifyPool(pool);
        require(address(governanceRouter.weth()) == tokenA, "LIQUIFY: ETH BASED POOL NEEDED");
        DelayedExchangePool(pool).processDelayedOrders();
    }

    function verifyPool(address pool) private returns (address tokenA, address tokenB) {
        tokenA = address(DelayedExchangePool(pool).tokenA());
        tokenB = address(DelayedExchangePool(pool).tokenB());
        require(governanceRouter.poolFactory().findPool(tokenA, tokenB) == pool, "LIQUIFY: POOL IS UNKNOWN");
    }

    function messenger() private view returns (iOVM_BaseCrossDomainMessenger) {
        return iOVM_BaseCrossDomainMessenger(l2Messenger);
    }
}
