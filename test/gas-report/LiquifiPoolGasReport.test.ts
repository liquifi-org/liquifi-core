import chai from "chai";

import { ethers } from "@nomiclabs/buidler";
import { deployContract, solidity } from "ethereum-waffle";
import { Wallet, ContractTransaction } from "ethers";
import { BigNumber } from "ethers";
import { token } from "../util/TokenUtil"

import LiquifiPoolFactoryArtifact from "../../artifacts/LiquifiPoolFactory.json";
import TestTokenArtifact from "../../artifacts/TestToken.json";
import LiquifiPoolRegisterArtifact from "../../artifacts/LiquifiPoolRegister.json";
import LiquifiGovernanceRouterArtifact from "../../artifacts/LiquifiGovernanceRouter.json";
import LiquifiActivityMeterArtifact from "../../artifacts/LiquifiActivityMeter.json";

import { TestToken } from "../../typechain/TestToken"
import { LiquifiPoolRegister } from "../../typechain/LiquifiPoolRegister";
import { LiquifiPoolFactory } from "../../typechain/LiquifiPoolFactory";
import { LiquifiDelayedExchangePoolFactory } from "../../typechain/LiquifiDelayedExchangePoolFactory"
import { orderHistory, wait, lastBlockTimestamp } from "../util/DebugUtils";
import { LiquifiGovernanceRouter } from "../../typechain/LiquifiGovernanceRouter"

chai.use(solidity);
const { expect } = chai;

describe.only("Liquifi Pool gas report", function () {
    this.timeout(120000);

    let registerOwner: Wallet;
    let factoryOwner: Wallet;
    let currencyOwner: Wallet;

    let liquidityProviders: Wallet[];
    let traders: Wallet[];

    let tokenA: TestToken;
    let tokenB: TestToken;

    let register: LiquifiPoolRegister;
    let factory: LiquifiPoolFactory;
    let dealsCount = 30;

    beforeEach(async () => {
        const wallets = await ethers.getSigners() as Wallet[];
        let fakeWeth;
        [registerOwner, factoryOwner, currencyOwner, fakeWeth] = wallets.splice(0, 5);

        liquidityProviders = wallets.splice(0, wallets.length / 2).slice(0, dealsCount);
        traders = wallets.slice(0, dealsCount);
        const walletAddresses = await Promise.all(liquidityProviders.concat(traders).map(wallet => wallet.getAddress()));

        tokenA = await deployContract(currencyOwner, TestTokenArtifact, [token(100000), "Token A", "TKA", walletAddresses]) as TestToken;
        tokenB = await deployContract(currencyOwner, TestTokenArtifact, [token(100000), "Token B", "TKB", walletAddresses]) as TestToken;
        const governanceRouter = await deployContract(factoryOwner, LiquifiGovernanceRouterArtifact, [3600, await fakeWeth.getAddress()]) as LiquifiGovernanceRouter;
        await deployContract(factoryOwner, LiquifiActivityMeterArtifact, [governanceRouter.address]);
        factory = await deployContract(factoryOwner, LiquifiPoolFactoryArtifact, [governanceRouter.address], { gasLimit: 9500000 }) as LiquifiPoolFactory;
        register = await deployContract(registerOwner, LiquifiPoolRegisterArtifact, [governanceRouter.address]) as LiquifiPoolRegister;
    })

    it("should deploy all contracts", async () => {
        expect(tokenA.address).to.be.properAddress;
        expect(tokenB.address).to.be.properAddress;
        expect(register.address).to.be.properAddress;
    })

    it("should do many deposits and swaps", async () => {
        for(let i = 1; i <= dealsCount; i++) {
            //console.log('adding liquidity ' + i);
            await addLiquidity(liquidityProviders[(i - 1) % liquidityProviders.length], 100 * i, 100 * i);
        }
        const time0 = await lastBlockTimestamp(ethers);
        
        for(let i = 1; i <= dealsCount; i += 2) {
            //console.log('making swaps ' + i);
            await swap(traders[(i - 1) % traders.length], tokenA, token(i * 3), tokenB, time0.add(600));
            await swap(traders[i % traders.length], tokenB, token(i * 5), tokenA, time0.add(600));
        }
    });

    it("should do many deposits, swaps and delayed orders", async() => {
        for(let i = 1; i <= dealsCount; i++) {
            //console.log('adding liquidity ' + i);
            await addLiquidity(liquidityProviders[(i - 1) % liquidityProviders.length], 100 * i, 100 * i);
        }

        const time0 = await lastBlockTimestamp(ethers);
        const pool = await LiquifiDelayedExchangePoolFactory.connect(await factory.findPool(tokenA.address, tokenB.address), factoryOwner);  
        const firstOrderTx = await addOrder(traders[0], tokenA, token(500), tokenB, time0.add(3000)); // all orders will be added before this one        
        const secondOrderTx =  await addOrder(traders[0], tokenA, token(2), tokenB, time0.add(5));
        let poolQueue = await pool.poolQueue();
        const firstOrderId = poolQueue.lastByTimeout;
        const secondOrderId = poolQueue.firstByTimeout;
        wait(ethers, 6);
        await register.processDelayedOrders(tokenA.address, tokenB.address, time0.add(20000));
        const [secondOrderFirshHash, secondOrderHistory] = await orderHistory(pool, secondOrderTx, secondOrderId);
        expect(await register.claimOrder(tokenA.address, tokenB.address, secondOrderFirshHash, secondOrderHistory,  time0.add(20000))).to.be.ok;
        
        for(let i = 1; i <= dealsCount; i += 2) {
            const timeout = Math.floor(dealsCount / 2) + i * 10 + 5;
            //console.log('adding order A ' + i + ' for ' + time0.add(timeout));
            await addOrder(traders[(i - 1) % traders.length], tokenA, token((dealsCount - i + 1) * 2), tokenB, time0.add(timeout));
            //console.log('adding order B ' + i);
            await addOrder(traders[i % traders.length], tokenB, token((dealsCount - i + 1) * 4), tokenA, time0.add(timeout));

            //console.log('making swaps ' + i);
            wait(ethers, 1);
            const swapPromise = swap(traders[(i + 1) % traders.length], tokenA, token(i * 3), tokenB, time0.add(6000));
            await expect(swapPromise).to.emit(pool, "FlowBreakEvent");
            await swapPromise;
            wait(ethers, 1);
            await swap(traders[(i + 2) % traders.length], tokenB,  token(i * 5), tokenA, time0.add(6000));
            wait(ethers, 1);
        }

        wait(ethers, 11000);
        await register.processDelayedOrders(tokenA.address, tokenB.address, time0.add(20000));
        const [firstOrderFirstHash, firstOrderHistory] = await orderHistory(pool, firstOrderTx, firstOrderId);
        //console.log(firstOrderHistory.length);
        //console.log(secondOrderHistory.length);
        
        expect(await register.claimOrder(tokenA.address, tokenB.address, firstOrderFirstHash, firstOrderHistory,  time0.add(20000))).to.be.ok;
    });

    async function addLiquidity(liquidityProvider: Wallet, amountA: number, amountB: number) {
        await tokenA.connect(liquidityProvider).approve(register.address, token(amountA));
        await tokenB.connect(liquidityProvider).approve(register.address, token(amountB));
        await register.connect(liquidityProvider).deposit(tokenA.address, token(amountA), tokenB.address, token(amountB), 
            await liquidityProviders[0].getAddress(), 42949672960);
    }

    async function swap(trader: Wallet, tokenIn: TestToken, amountIn: BigNumber, tokenOut: TestToken, timeout: BigNumber): Promise<ContractTransaction> {
        await tokenIn.connect(trader).approve(register.address, amountIn);

        return await register.connect(trader).swap(tokenIn.address, amountIn, tokenOut.address, token(1), 
            await trader.getAddress(), timeout);

        // const orders = await loadOrders();
        // console.log(orders.length + " orders in queue after swap: " + JSON.stringify(orders.map(o => o.toString())));
    }

    async function addOrder(trader: Wallet, tokenIn: TestToken, amountIn: BigNumber, tokenOut: TestToken, timeout: BigNumber): Promise<ContractTransaction> {
        const traderAddress = await trader.getAddress();
        await tokenIn.connect(trader).approve(register.address, amountIn);
        return await register.connect(trader).delayedSwap(tokenIn.address, amountIn, tokenOut.address, token(1), 
            traderAddress, timeout, 0, 0);

        // const orders = await loadOrders();
        // console.log(orders.length + " orders in queue after delayedSwap: " + JSON.stringify(orders.map(o => o.toString())));
    }

    async function loadOrders(): Promise<number[]> {
        const pool = await LiquifiDelayedExchangePoolFactory.connect(await factory.findPool(tokenA.address, tokenB.address), factoryOwner);
        const queue = await pool.queue();
        let orders = [];
        let next = queue.firstByTimeout;
        while (next.gt(0)) {
            orders.push(next.toNumber());
            const order = await pool.orders(next);
            next = order.nextByTimeout;
        }
        return orders;
    }
})