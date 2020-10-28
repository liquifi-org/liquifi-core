import chai from "chai";

import { ethers } from "@nomiclabs/buidler";
import { deployContract, solidity } from "ethereum-waffle";
import { Wallet, BigNumber, ContractTransaction } from "ethers"
import { token } from "./util/TokenUtil";

import LiquifiDelayedExchangePoolArtifact from "../artifacts/LiquifiDelayedExchangePool.json";
import TestTokenArtifact from "../artifacts/TestToken.json";
import LiquifiGovernanceRouterArtifact from "../artifacts/LiquifiGovernanceRouter.json";
import LiquifiActivityMeterArtifact from "../artifacts/LiquifiActivityMeter.json";
import LiquifiPoolFactoryArtifact from "../artifacts/LiquifiPoolFactory.json";

import { TestGovernor } from "../typechain/TestGovernor";
import TestGovernorArtifact from "../artifacts/TestGovernor.json";

import { LiquifiDelayedExchangePoolFactory } from "../typechain/LiquifiDelayedExchangePoolFactory"
import { TestToken } from "../typechain/TestToken"
import { LiquifiGovernanceRouter } from "../typechain/LiquifiGovernanceRouter"
import { LiquifiDelayedExchangePool } from "../typechain/LiquifiDelayedExchangePool";
import { LiquifiPoolFactory } from "../typechain/LiquifiPoolFactory"
import { orderHistory, collectEvents, lastBlockTimestamp, traceDebugEvents, wait } from "./util/DebugUtils";

chai.use(solidity);
const { expect } = chai;

describe("Pool governance and disaster recovery", function() {
    this.timeout(120000);

    var liquidityProvider: Wallet;
    var factoryOwner: Wallet;
    var otherTrader: Wallet;

    var tokenA: TestToken;
    var tokenB: TestToken;

    var pool: LiquifiDelayedExchangePool;
    var governor: TestGovernor;
    var factory: LiquifiPoolFactory;

    beforeEach(async () => {
        let fakeWeth;
        [liquidityProvider, factoryOwner, otherTrader, fakeWeth] = await ethers.getSigners() as Wallet[];
        
        tokenA = await deployContract(liquidityProvider, TestTokenArtifact, [BigNumber.from(1).shl(128), "Token A", "TKA", [await otherTrader.getAddress()]]) as TestToken
        tokenB = await deployContract(liquidityProvider, TestTokenArtifact, [BigNumber.from(1).shl(128), "Token B", "TKB", [await otherTrader.getAddress()]]) as TestToken
        if (BigNumber.from(tokenA.address).gt(BigNumber.from(tokenB.address))) {
            [tokenA, tokenB] = [tokenB ,tokenA];
        }

        const governanceRouter = await deployContract(factoryOwner, LiquifiGovernanceRouterArtifact, [3600, await fakeWeth.getAddress()]) as LiquifiGovernanceRouter;
        await deployContract(factoryOwner, LiquifiActivityMeterArtifact, [governanceRouter.address]);
        governor = await deployContract(factoryOwner, TestGovernorArtifact, [governanceRouter.address]) as TestGovernor;
        factory = await deployContract(factoryOwner, LiquifiPoolFactoryArtifact, [governanceRouter.address], { gasLimit: 9500000 }) as LiquifiPoolFactory;
        
        await factory.getPool(tokenA.address, tokenB.address);
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        pool = await LiquifiDelayedExchangePoolFactory.connect(poolAddress, factoryOwner);  
    });

    it("should deploy all contracts", async () => {
        expect(tokenA.address).to.be.properAddress
        expect(tokenB.address).to.be.properAddress
        expect(governor.address).to.be.properAddress
        expect(pool.address).to.be.properAddress
    });

    it("should lock the pool", async () => {
        const provider = await liquidityProvider.getAddress();
        await addLiquidity(token(150), token(200));

        await tokenA.connect(liquidityProvider).transfer(pool.address, token(100));
        let txPromise = pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(1), 10);
        await expect(txPromise).to.emit(pool, "FlowBreakEvent");
        const orderTx = await txPromise;
        const orderId = (await pool.poolState()).breaksCount.div(2).mul(2);
        await tokenB.transfer(pool.address, token(1));
        expect(await pool.swap(provider, false, 1, 0, [])).to.be.ok;

        expect(await governor.lockPoolTest(pool.address)).to.be.ok;

        await wait(ethers, 50);
        let [orderFirshHash1, orderHistory1] = await orderHistory(pool, orderTx, orderId);
        // order is not closed because time has frozen
        await expect(pool.claimOrder(orderFirshHash1, orderHistory1)).to.be.revertedWith("FAIL https://err.liquifi.org/PM");
        // cannot add new order in locked pool
        await expect(pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(90), 10)).to.be.revertedWith("FAIL https://err.liquifi.org/JW");
        // cannot swap in locked pool
        await tokenB.transfer(pool.address, token(1));
        await expect(pool.swap(provider, false, 1, 0, [])).to.be.revertedWith("FAIL https://err.liquifi.org/JW");

        txPromise = pool.processDelayedOrders();
        await expect(txPromise).to.not.emit(pool, "FlowBreakEvent");
        expect(await txPromise).to.be.ok;

        // it is possible to close the order and then claim it
        txPromise = pool.connect(liquidityProvider).closeOrder(orderId);
        await expect(txPromise).to.emit(pool, "OperatingInInvalidState");
        expect(await txPromise).to.be.ok;
        [orderFirshHash1, orderHistory1] = await orderHistory(pool, orderTx, orderId);
        expect(await pool.claimOrder(orderFirshHash1, orderHistory1)).to.be.ok;

        // it should be possible to withdraw funds
        await pool.connect(liquidityProvider).transfer(pool.address, token(100));
        txPromise = pool.burn(provider, false);
        await expect(txPromise).to.emit(pool, "OperatingInInvalidState");
        expect(await txPromise).to.be.ok;
    });

    it("should lock the pool on fee change", async () => {
        const provider = await liquidityProvider.getAddress();
        await addLiquidity(token(150), token(200));

        await tokenA.connect(liquidityProvider).transfer(pool.address, token(100));
        let txPromise = pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(1), 10);
        const orderTx = await txPromise;
        const orderId = (await pool.poolState()).breaksCount.div(2).mul(2);
        expect(await governor.setFee(pool.address, 5)).to.be.ok;
        await expect(pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(1), 10)).to.be.revertedWith("FAIL https://err.liquifi.org/JT");
        await tokenB.transfer(pool.address, token(1));
        await expect(pool.swap(provider, false, 1, 0, [])).to.emit(pool, "OperatingInInvalidState");
        
        let poolState = await pool.poolState();
        expect(poolState.notFee).to.be.eq(997);

        await wait(ethers, 1);
        let [orderFirshHash1, orderHistory1] = await orderHistory(pool, orderTx, orderId);
        // order is not closed yetn
        await expect(pool.claimOrder(orderFirshHash1, orderHistory1)).to.be.revertedWith("FAIL https://err.liquifi.org/PM");

        await wait(ethers, 10);
        // now it is closed
        expect(await pool.claimOrder(orderFirshHash1, orderHistory1)).to.be.ok;

        await tokenB.transfer(pool.address, token(1));
        await expect(pool.swap(provider, false, 1, 0, [])).to.not.emit(pool, "OperatingInInvalidState");

        poolState = await pool.poolState();
        expect(poolState.notFee).to.be.eq(995);
    });

    it("should not lock the pool on instant swap fee change", async () => {
        //const events = traceDebugEvents(pool, 1);
        const provider = await liquidityProvider.getAddress();
        await addLiquidity(token(15000), token(20000));

        await tokenA.connect(liquidityProvider).transfer(pool.address, token(1).div(100));
        let txPromise = pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(1), 1000);
        const orderTx = await txPromise;
        const orderId = (await pool.poolState()).breaksCount.div(2).mul(2);
        expect(await governor.setInstantSwapFee(pool.address, 1)).to.be.ok;
        await tokenA.connect(liquidityProvider).transfer(pool.address, token(1).div(100));
        expect(await pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, token(1), 1000)).to.be.ok;

        const balances = await pool.poolBalances();
        const availableBalanceA = balances.totalBalanceA.sub(balances.balanceALocked);
        const availableBalanceB = balances.totalBalanceB.sub(balances.balanceBLocked);


        const amountIn = token(10000);
        const amountInWithFee = amountIn.mul(998);
        const numerator = amountInWithFee.mul(availableBalanceA);
        const denominator = availableBalanceB.mul(1000).add(amountInWithFee);
        const amountOut = numerator.div(denominator);
        await tokenB.transfer(pool.address, amountIn);
        const swapPromise = pool.swap(provider, false, amountOut, 0, []);
        await expect(swapPromise).to.not.emit(pool, "OperatingInInvalidState");
        expect(await swapPromise).to.be.ok;
        //await events;
    });

    it("should lock the pool on emergency", async () => {
        const provider = await liquidityProvider.getAddress();
        await addLiquidity(token(150), token(200));
        //const events = traceDebugEvents(pool, 1);

        let txPromise = governor.emergencyLock(pool.address, {gasLimit: 61000});
        await expect(txPromise).to.not.emit(governor, "EmergencyLock");
        expect(await txPromise).to.be.ok;

        await tokenA.connect(liquidityProvider).transfer(pool.address, BigNumber.from(1).shl(112).sub(1));
        txPromise = pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, BigNumber.from(1), 10);
        await expect(txPromise).to.be.ok;
        const orderTx1 = await txPromise;
        const orderId1 = (await pool.poolState()).breaksCount.div(2).mul(2);

        await tokenB.connect(liquidityProvider).transfer(pool.address, BigNumber.from(1).shl(112).sub(token(200)).add(10000));
        txPromise = pool.addOrder(await liquidityProvider.getAddress(), 0, 0, 0, BigNumber.from(1), 10);
        expect(await txPromise).to.be.ok;

        await wait(ethers, 5);
        // overflow in balances update
        await expect(pool.processDelayedOrders()).to.be.revertedWith("FAIL https://err.liquifi.org/EO"); 
        await expect(pool.connect(liquidityProvider).closeOrder(orderId1)).to.be.revertedWith("FAIL https://err.liquifi.org/EO"); 

        await wait(ethers, 50);
        let [orderFirshHash1, orderHistory1] = await orderHistory(pool, orderTx1, orderId1);
        // still overflow in balances update
        await expect(pool.claimOrder(orderFirshHash1, orderHistory1)).to.be.revertedWith("FAIL https://err.liquifi.org/EO");

        txPromise = governor.emergencyLock(pool.address, {gasLimit: 200000});
        await expect(txPromise).to.emit(governor, "EmergencyLock");
        expect(await txPromise).to.be.ok;

        // now pool is locked and time is rolled back to last successful update time
        expect(await pool.connect(liquidityProvider).closeOrder(orderId1)).to.be.ok;
        [orderFirshHash1, orderHistory1] = await orderHistory(pool, orderTx1, orderId1);
        expect(await pool.claimOrder(orderFirshHash1, orderHistory1)).to.be.ok;
        // expect(await pool.claimOrder(orderFirshHash1, orderHistory1)).to.be.ok;

        await pool.connect(liquidityProvider).transfer(pool.address, token(100));
        expect(await pool.burn(provider, false)).to.be.ok;
    });

    it("should collect protocol fee", async () => {
        //const events = traceDebugEvents(pool, 1);
        /* 
          From https://uniswap.org/whitepaper.pdf
          Suppose the initial depositor puts 100 DAI and 1 ETH into a pair, 
          receiving 10 shares.Some time later (without any other depositor 
            having participated in that pair), they attemptto withdraw it, 
            at a time when the pair has 96 DAI and 1.5 ETH. Plugging those 
            values into the above formula gives us the following: ... ~0.0286

            It is not completely true, the formula gives us ~0.286. Someone have not multiplied it to s1.
            Lets test for 0.286.
        */
        const provider = await liquidityProvider.getAddress();
        
        expect(await pool.balanceOf(governor.address)).to.be.eq(0);
        expect(await governor.setProtocolFee(pool.address, 166)).to.be.ok; // 16.6 % of swap fee = 0.03%
        
        await addLiquidity(token(100), token(1));
        expect(await pool.balanceOf(governor.address)).to.be.eq(0);

        const amountIn = token(1).div(2);
        const amountOut = token(4);
        await tokenB.transfer(pool.address, amountIn);

        const balances = await pool.poolBalances();
        if (balances.totalBalanceA.eq(token(100))) {
            expect(await pool.swap(provider, false, amountOut, 0, [])).to.be.ok;
        } else {
            expect(await pool.swap(provider, false, 0, amountOut, [])).to.be.ok;
        }
        

        await addLiquidity(token(1), token(2));
        const mintedFee = await pool.balanceOf(governor.address);
        const expectedMintedFee = token(286).div(1000);
        // should be close enough: difference less than 2%
        expect(mintedFee.gt(expectedMintedFee) ? expectedMintedFee.mul(100).div(mintedFee) : mintedFee.mul(100).div(expectedMintedFee)).to.be.gt(98);
   
        //await events;
    });

    it("should do sync", async () => {
        //const events = traceDebugEvents(pool, 1);
        await addLiquidity(token(100), token(1));
        await tokenB.transfer(pool.address, token(5));
        await pool.sync();
        let balances = await pool.poolBalances();
        if (balances.totalBalanceA.eq(token(100))) {
            expect(balances.totalBalanceB).to.be.eq(token(6));
        } else {
            expect(balances.totalBalanceA).to.be.eq(token(6));
        }

        await tokenA.connect(liquidityProvider).transfer(pool.address, BigNumber.from(1).shl(112).sub(1));
        let txPromise = pool.addOrder(await liquidityProvider.getAddress(), 1, 0, 0, BigNumber.from(1), 10);
        expect(await txPromise).to.be.ok;
        balances = await pool.poolBalances();
        const orderTx1 = await txPromise;
        const orderId1 = (await pool.poolState()).breaksCount.div(2).mul(2);

        await wait(ethers, 15);

        await pool.processDelayedOrders();

        let [orderFirshHash1, orderHistory1] = await orderHistory(pool, orderTx1, orderId1);
        expect(await pool.claimOrder(orderFirshHash1, orderHistory1)).to.be.ok;

        balances = await pool.poolBalances();
        expect(balances.balanceALocked.add(balances.balanceBLocked)).to.be.gt(0); // because of rounding in claim calculation
        
        await pool.sync();
        balances = await pool.poolBalances();
        expect(balances.balanceALocked.add(balances.balanceBLocked)).to.be.eq(0);
        //await events;
    });

    it("should limit history lenght", async () => {
        //const events = traceDebugEvents(pool, 160);
        const provider = await liquidityProvider.getAddress();
        const desiredMaxHistory = 10;
        expect(await governor.setDesiredMaxHistory(pool.address, desiredMaxHistory)).to.be.ok;
        await addLiquidity(token(100), token(1));
        const poolState = await pool.poolState();
        expect(poolState.maxHistory).to.be.eq(desiredMaxHistory);

        const orders = [];
        for(let i = 0; i < desiredMaxHistory * 2; i++) {
            await tokenA.connect(liquidityProvider).transfer(pool.address, token(1));
            let txPromise = pool.addOrder(provider, 1, 0, 0, BigNumber.from(1), 500);
            expect(await txPromise).to.be.ok;
            orders.push({
                orderTx: await txPromise,
                orderId: (await pool.poolState()).breaksCount.div(2).mul(2),
            });
            await wait(ethers, 2);
        }

        await wait(ethers, 1000);
        await pool.processDelayedOrders();

        for(let i = 0; i < desiredMaxHistory * 2; i++) {
            const order = orders[i];
            let [orderFirshHash1, orderHistory1] = await orderHistory(pool, order.orderTx, order.orderId);
            expect(orderHistory1.length / 3).to.be.lte(desiredMaxHistory * 2 + 2);
            expect(await pool.claimOrder(orderFirshHash1, orderHistory1)).to.be.ok;
        }
        //await events;
    })

    it("should adjust history length", async () => {
        const provider = await liquidityProvider.getAddress();
        const desiredMaxHistory = 16;
        const newMaxHistory = 12;
        expect(await governor.setDesiredMaxHistory(pool.address, desiredMaxHistory)).to.be.ok;
        await addLiquidity(token(100), token(1));
        let poolState = await pool.poolState();
        expect(poolState.maxHistory).to.be.eq(desiredMaxHistory);

        const orders = [];
        for(let i = 0; i < desiredMaxHistory; i++) {
            await tokenA.connect(liquidityProvider).transfer(pool.address, token(1));
            let txPromise = pool.addOrder(provider, 1, 0, 0, BigNumber.from(1), 500);
            expect(await txPromise).to.be.ok;
            orders.push({
                orderTx: await txPromise,
                orderId: (await pool.poolState()).breaksCount.div(2).mul(2),
            });
            await wait(ethers, 2);

            await tokenA.connect(liquidityProvider).transfer(pool.address, token(1));
            expect(await pool.swap(provider, false, 0, BigNumber.from(1), [])).to.be.ok;

            if (i * 2 == desiredMaxHistory) {
                expect(await governor.setDesiredMaxHistory(pool.address, newMaxHistory)).to.be.ok;
                await tokenA.connect(liquidityProvider).transfer(pool.address, token(1));
                expect(await pool.swap(provider, false, 0, BigNumber.from(1), [])).to.be.ok;
                await tokenA.connect(liquidityProvider).transfer(pool.address, token(1));
                expect(await pool.swap(provider, false, 0, BigNumber.from(1), [])).to.be.ok;

                poolState = await pool.poolState();
                expect(poolState.maxHistory).to.be.eq(desiredMaxHistory - 1);
            }
        }

        poolState = await pool.poolState();
        expect(poolState.maxHistory).to.be.eq(newMaxHistory);

        for(let i = 2; poolState.breaksCount.sub(newMaxHistory * 2).gt(i); i += 2) {
            const order = await pool.findOrder(i);
            if (order.period.gt(0)) {
                expect(order.prevByStopLoss.and(1)).to.be.eq(1); // order is closed
            }
        }

        await wait(ethers, 1000);
        await pool.processDelayedOrders();

        for(let i = 0; i < desiredMaxHistory; i++) {
            const order = orders[i];
            let [orderFirshHash1, orderHistory1] = await orderHistory(pool, order.orderTx, order.orderId);
            expect(orderHistory1.length / 3).to.be.lte(desiredMaxHistory * 2 + 2);
            expect(await pool.claimOrder(orderFirshHash1, orderHistory1)).to.be.ok;
        }
    });

    const addLiquidity = async (amountA: BigNumber, amountB: BigNumber, _liquidityProvider: Wallet = liquidityProvider) => {
        await tokenA.transfer(pool.address, amountA)
        await tokenB.transfer(pool.address, amountB)
        await pool.mint(await _liquidityProvider.getAddress())
    }
});