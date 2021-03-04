import chai from "chai";

import { ethers } from "hardhat";
import { deployContract, solidity } from "ethereum-waffle";
import { BigNumber, Signer } from "ethers"
import { token } from "./util/TokenUtil";

import LiquifiDelayedExchangePoolArtifact from "../artifacts/contracts/LiquifiDelayedExchangePool.sol/LiquifiDelayedExchangePool.json";
import TestTokenArtifact from "../artifacts/contracts/test/TestToken.sol/TestToken.json";
import LiquifiGovernanceRouterArtifact from "../artifacts/contracts/LiquifiGovernanceRouter.sol/LiquifiGovernanceRouter.json";
import LiquifiActivityMeterArtifact from "../artifacts/contracts/LiquifiActivityMeter.sol/LiquifiActivityMeter.json";

import { TestToken } from "../typechain/TestToken"
import { LiquifiGovernanceRouter } from "../typechain/LiquifiGovernanceRouter"
import { LiquifiDelayedExchangePool } from "../typechain/LiquifiDelayedExchangePool";
import { orderHistory, lastBlockTimestamp, wait } from "./util/DebugUtils";

chai.use(solidity);
const { expect } = chai;

describe("Liquifi Delayed Exchange Pool", () => {

    var liquidityProvider: Signer;
    var factoryOwner: Signer;
    var otherTrader: Signer;

    var tokenA: TestToken;
    var tokenB: TestToken;

    var pool: LiquifiDelayedExchangePool;

    beforeEach(async () => {
        let fakeWeth;
        [liquidityProvider, factoryOwner, otherTrader, fakeWeth] = await ethers.getSigners();
        
        tokenA = await deployContract(liquidityProvider, TestTokenArtifact, [token(1000), "Token A", "TKA", [await otherTrader.getAddress()]]) as TestToken
        tokenB = await deployContract(liquidityProvider, TestTokenArtifact, [token(1000), "Token B", "TKB", [await otherTrader.getAddress()]]) as TestToken
        if (BigNumber.from(tokenA.address).gt(BigNumber.from(tokenB.address))) {
            [tokenA, tokenB] = [tokenB ,tokenA];
        }
        
        const governanceRouter = await deployContract(factoryOwner, LiquifiGovernanceRouterArtifact, [3600, await fakeWeth.getAddress()]) as LiquifiGovernanceRouter;
        await deployContract(factoryOwner, LiquifiActivityMeterArtifact, [governanceRouter.address]);
        pool = await deployContract(factoryOwner, LiquifiDelayedExchangePoolArtifact, [tokenA.address, tokenB.address, false, governanceRouter.address, 761], { gasLimit: 9500000 }) as LiquifiDelayedExchangePool
    })

    it("should deploy all contracts", async () => {
        expect(tokenA.address).to.be.properAddress;
        expect(tokenB.address).to.be.properAddress;
        expect(pool.address).to.be.properAddress;
    })

    it("should have index in symbol", async () => {
        expect(await pool.symbol()).to.be.eq("LPT000761");
    })

    it("should add delayed order", async() => {
        await tokenA.connect(liquidityProvider).transfer(pool.address, token(100))
        await expect(pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(90), 10)).to.emit(pool, "FlowBreakEvent");
        // check queue state
        const firstOrderId = 2;
        const poolQueue = await pool.poolQueue();
        expect(poolQueue.firstByTimeout).to.be.eq(firstOrderId);
        expect(poolQueue.lastByTimeout).to.be.eq(firstOrderId);
        expect(poolQueue.firstByTokenAStopLoss).to.be.eq(firstOrderId);
        expect(poolQueue.lastByTokenAStopLoss).to.be.eq(firstOrderId);
        // flow state
        const poolBalances = await pool.poolBalances();
        expect(poolBalances.balanceALocked).to.be.eq(token(100));
        expect(poolBalances.poolFlowSpeedA).to.be.eq(token(100).div(10).shl(32));
        expect(poolBalances.balanceBLocked).to.be.eq(token(0));
        expect(poolBalances.poolFlowSpeedB).to.be.eq(token(0));
        // // total balance
        expect(poolBalances.totalBalanceA).to.be.eq(token(100));
        expect(poolBalances.totalBalanceB).to.be.eq(token(0));
    })

    it("should close order by timeout", async() => {
        //const events = traceDebugEvents(pool, 1);
        
        await addLiquidity(token(150), token(200));
        await tokenA.connect(liquidityProvider).transfer(pool.address, token(100));
        
        expect(await pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(60), 10)).to.be.ok;
        const time0 = await lastBlockTimestamp(ethers);
        await wait(ethers, 5);
        
        expect(await pool.processDelayedOrders()).to.be.ok;
        let poolState = await pool.poolState();
        let poolQueue = await pool.poolQueue();
        let poolBalances = await pool.poolBalances();

        const time1 = await lastBlockTimestamp(ethers);
        let amountIn = token(100).mul(time1.sub(time0)).div(10);
        let amountInWithFee = amountIn.mul(997);
        let numerator = amountInWithFee.mul(token(200));
        let denominator = token(150).mul(1000).add(amountInWithFee);
        let amountOut = numerator.div(denominator);

        const firstOrderId = 4; // 1st break was on addLiquidity, 2nd break on addOrder
        expect(poolQueue.firstByTimeout).to.be.eq(firstOrderId);
        //expect(flowState.balanceALocked).to.be.eq(token(50));
        expect(poolBalances.poolFlowSpeedA).to.be.eq(token(100).div(10).shl(32), 'wrong poolFlowSpeedA');
        expect(poolBalances.balanceBLocked).to.be.eq(amountOut, 'wrong balanceBLocked');
        expect(poolBalances.poolFlowSpeedB).to.be.eq(token(0), 'wrong poolFlowSpeedB');
        expect(poolBalances.totalBalanceA).to.be.eq(token(250), 'wrong totalBalanceA');
        expect(poolBalances.totalBalanceB).to.be.eq(token(200), 'wrong totalBalanceB');

        await wait(ethers, 3)

        expect(await pool.processDelayedOrders()).to.be.ok;
        poolState = await pool.poolState();
        poolQueue = await pool.poolQueue();
        expect(poolQueue.firstByTimeout).to.be.eq(firstOrderId);
        poolBalances = await pool.poolBalances();
        //expect(flowState.balanceALocked).to.be.eq(token(10));

        await wait(ethers, 3);
        
        const txResult = pool.processDelayedOrders();
        await expect(txResult).to.emit(pool, "FlowBreakEvent");
        expect(await txResult).to.be.ok;
        poolBalances = await pool.poolBalances();
        poolState = await pool.poolState();
        poolQueue = await pool.poolQueue();
        expect(poolQueue.firstByTimeout).to.be.eq(0);

        expect(poolBalances.balanceALocked).to.be.eq(token(0));
        expect(poolBalances.poolFlowSpeedA).to.be.eq(token(0));
        
        expect(poolBalances.poolFlowSpeedB).to.be.eq(token(0));

        amountIn = token(100);
        amountInWithFee = amountIn.mul(997);
        numerator = amountInWithFee.mul(token(200));
        denominator = token(150).mul(1000).add(amountInWithFee);
        amountOut = numerator.div(denominator);
        expect(poolBalances.balanceBLocked).to.be.eq(amountOut, 'order separation !'); // check for the order separation problem

        //await events;
    })

    it("should process order by stoploss", async() => {    
        //const events = traceDebugEvents(pool, 30);    
        await addLiquidity(token(150), token(200));
        await tokenA.connect(liquidityProvider).transfer(pool.address, token(100));
        
        // full amountOut is about token(79)
        expect(await pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(90), 10)).to.be.ok;
        await wait(ethers, 5)
        expect(await pool.processDelayedOrders()).to.be.ok;
        let poolQueue = await pool.poolQueue();

        const firstOrderId = 4; // 1st break was on addLiquidity, 2nd break on addOrder
        expect(poolQueue.firstByTimeout).to.be.eq(firstOrderId);

        await wait(ethers, 4)

        const promise = pool.processDelayedOrders();
        await expect(promise).to.emit(pool, "FlowBreakEvent");
        expect(await promise).to.be.ok;

        poolQueue = await pool.poolQueue();
        expect(poolQueue.firstByTimeout).to.be.eq(0);
    })

    it("should process multiple orders", async() => {
        //const events = traceDebugEvents(pool, 40);    
        await addLiquidity(token(100), token(100));

        // First order
        await tokenA.connect(liquidityProvider).transfer(pool.address, token(10));
        expect(await pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(5), 20)).to.be.ok;

        // Second Order
        await tokenA.connect(liquidityProvider).transfer(pool.address, token(20));
        expect(await pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(2), 10)).to.be.ok;
        let poolQueue = await pool.poolQueue();
        const secondOrderId = 6; // 1st break was on addLiquidity, 2nd break on addOrder, 3rd break on another addOrder
        expect(poolQueue.firstByTimeout).to.be.eq(secondOrderId);

        await wait(ethers, 10)
        let promise = pool.processDelayedOrders();
        await expect(promise).to.emit(pool, "FlowBreakEvent");
        expect(await promise).to.be.ok; 
        poolQueue = await pool.poolQueue();

        await wait(ethers, 10)
        promise = pool.processDelayedOrders();
        await expect(promise).to.emit(pool, "FlowBreakEvent");
        expect(await promise).to.be.ok;

        let poolBalances = await pool.poolBalances();
        poolQueue = await pool.poolQueue();
        expect(poolQueue.firstByTimeout).to.be.eq(0);
        expect(poolBalances.balanceALocked).to.be.eq(token(0));

        //await events;
    })

    it("should claim order", async() => {
        //const debugEvents = traceDebugEvents(pool, 6);
        await addLiquidity(token(150), token(200));
        await tokenA.connect(liquidityProvider).transfer(pool.address, token(100));
        
        let txPromise = pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(20), 10);
        expect(await txPromise).to.be.ok;
        let orderTx = await txPromise;
        let orderId = (await pool.poolState()).breaksCount.div(2).mul(2);

        await wait(ethers, 5);
        const balanceA = await tokenA.balanceOf(await liquidityProvider.getAddress());
        expect(balanceA).to.be.eq(token(1000).sub(token(150)).sub(token(100)));

        let processPromise = pool.processDelayedOrders();
        await expect(processPromise).to.not.emit(pool, "FlowBreakEvent");
        expect(await processPromise).to.be.ok;

        await wait(ethers, 15);

        processPromise = pool.processDelayedOrders();
        await expect(processPromise).to.emit(pool, "FlowBreakEvent");
        expect(await processPromise).to.be.ok;

        let [orderFirshHash1, orderHistory1] = await orderHistory(pool, orderTx, orderId);
        expect(await pool.claimOrder(orderFirshHash1, orderHistory1)).to.be.ok;

        let amountIn = token(100);
        let amountInWithFee = amountIn.mul(997);
        let numerator = amountInWithFee.mul(token(200));
        let denominator = token(150).mul(1000).add(amountInWithFee);
        let amountOut = numerator.div(denominator);

        const newBalanceA = await tokenA.balanceOf(await liquidityProvider.getAddress());
        const newBalanceB = await tokenB.balanceOf(await liquidityProvider.getAddress());

        expect(newBalanceA).to.be.eq(token(1000).sub(token(150)).sub(token(100)));
        expect(newBalanceB).to.be.eq(token(1000).sub(token(200)).add(amountOut));
        //await debugEvents;
    });

    it("should claim order with a flow break inside", async() => {
        //const debugEvents = traceDebugEvents(pool, 30);
        await addLiquidity(token(150), token(200));
        await tokenA.connect(liquidityProvider).transfer(pool.address, token(50));
        
        let txPromise = pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(10), 15);
        expect(await txPromise).to.be.ok;
        let orderTx = await txPromise;
        let orderId = (await pool.poolState()).breaksCount.div(2).mul(2);
        
        await wait(ethers, 5);

        await tokenA.connect(otherTrader).transfer(pool.address, token(50));
        
        expect(await pool.addOrder(await otherTrader.getAddress(), 1, 0, 0, token(10), 5)).to.be.ok;

        await wait(ethers, 15);

        //let processPromise = pool.processDelayedOrders();
        //await expect(processPromise).to.emit(pool, "FlowBreakEvent");
        //expect(await processPromise).to.be.ok;

        // events are:
        // mint
        // open 1
        // open 2
        // -- next two are not fired at this point if processDelayedOrders is not called
        // closed 2
        // closed 1

        let [orderFirshHash1, orderHistory1] = await orderHistory(pool, orderTx, orderId);
        expect(await pool.claimOrder(orderFirshHash1, orderHistory1)).to.be.ok;

        const newBalanceA = await tokenA.balanceOf(await liquidityProvider.getAddress());
        const newBalanceB = await tokenB.balanceOf(await liquidityProvider.getAddress());

        expect(newBalanceA).to.be.eq(token(1000).sub(token(150)).sub(token(50)));//.add(1 /* some rounding  */));
        expect(newBalanceB).to.be.gt(token(1000).sub(token(200)));
    });

    it("should withdraw during swap", async () => {
        //const debugEvents = traceDebugEvents(pool, 6);
        await addLiquidity(token(20), token(20));
        //await addLiquidity(token(100), token(100), otherTrader);

        await tokenA.connect(otherTrader).transfer(pool.address, token(50));
        const balanceABefore = await tokenA.balanceOf(await otherTrader.getAddress());
        const balanceBBefore = await tokenB.balanceOf(await otherTrader.getAddress());
        
        const orderTx = await pool.addOrder(await otherTrader.getAddress(), 1, 0, 0, token(10), 15)
        let poolQueue = await pool.poolQueue();
        const orderId = poolQueue.firstByTimeout;
        await wait(ethers, 5);
        
        const liquidity = await pool.balanceOf(await liquidityProvider.getAddress());
        await pool.connect(liquidityProvider).transfer(pool.address, BigNumber.from("19999999999999999000"))
        await pool.burn(await liquidityProvider.getAddress(), false);

        await wait(ethers, 20);
        expect(await pool.processDelayedOrders()).to.be.ok;
        const [firstOrderFirshHash, firstOrderHistory] = await orderHistory(pool, orderTx, orderId);
        expect(await pool.claimOrder(firstOrderFirshHash, firstOrderHistory)).to.be.ok;

        // await tokenA.connect(liquidityProvider).transfer(pool.address, token(50));
        // expect(await pool.swap(await liquidityProvider.getAddress(), false, token(0), BigNumber.from(1), [])).to.be.ok;

        let poolBalances = await pool.poolBalances();
        expect(poolBalances.balanceBLocked).to.eq(0);

        //await debugEvents;
    })

    // it("should process multiple orders along with regular swap", async() => {
    //     await addLiquidity(token(100), token(100))

    //     // First order
    //     await tokenA.connect(liquidityProvider).transfer(pool.address, token(10))
    //     expect(await pool.addOrder(await liquidityProvider.getAddress(), tokenA.address, 10, token(10), token(9))).to.be.ok

    //     // Second Order
    //     await tokenA.connect(liquidityProvider).transfer(pool.address, token(20))
    //     expect(await pool.addOrder(await liquidityProvider.getAddress(), tokenA.address, 20, token(20), token(19))).to.be.ok

    //     // Regular Swap
    //     wait(30)
    //     await tokenA.connect(liquidityProvider).transfer(pool.address, token(10));
    //     await expect(pool.swap(token(0), token(10), await liquidityProvider.getAddress())).to.be.ok;

    //     // Liquidity provider balances
    //     expect(await tokenA.balanceOf(await liquidityProvider.getAddress())).to.be.eq(token(860))
    //     expect(await tokenB.balanceOf(await liquidityProvider.getAddress())).to.be.eq(token(900).add(deductFee(40)))
    //     // Pool token balances
    //     expect(await tokenA.balanceOf(pool.address)).to.be.eq(token(140));
    //     expect(await tokenB.balanceOf(pool.address)).to.be.eq(token(100).sub(token(40)).add(extractFee(40)));
    //     // Unlocked balances
    //     expect(await pool.balanceA()).to.be.eq(token(140));
    //     expect(await pool.balanceB()).to.be.eq(token(100).sub(token(40)).add(extractFee(40)));
    // })

    // it("should not swap tokens with invalid rate", async () => {
    //     await addLiquidity(token(100), token(100))
    //     await tokenA.connect(liquidityProvider).transfer(pool.address, token(10));

    //     const amountInWithFee = token(10).mul(997);
    //     const numerator = amountInWithFee.mul(token(100));
    //     const denominator = token(100).mul(1000).add(amountInWithFee);
    //     const amountOut = numerator.div(denominator);
    //     const littleMoreOut = amountOut.add(BigNumber.from(1));

    //     await expect(pool.swap(token(0), littleMoreOut, await liquidityProvider.getAddress())).to.be.revertedWith("LIQUIFI: INVALID_EXCHANGE_RATE");
    // })

    const addLiquidity = async (amountA: BigNumber, amountB: BigNumber, _liquidityProvider: Signer = liquidityProvider) => {
        await tokenA.transfer(pool.address, amountA)
        await tokenB.transfer(pool.address, amountB)
        await pool.mint(await _liquidityProvider.getAddress())
    }
})