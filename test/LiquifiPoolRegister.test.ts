import chai from "chai";

import { ethers } from "@nomiclabs/buidler";
import { deployContract, solidity } from "ethereum-waffle";
import { Wallet, BigNumber } from "ethers"
import { token } from "./util/TokenUtil"

import LiquifiPoolFactoryArtifact from "../artifacts/LiquifiPoolFactory.json";
import TestTokenArtifact from "../artifacts/TestToken.json";
import LiquifiPoolRegisterArtifact from "../artifacts/LiquifiPoolRegister.json";
import TestWethArtifact from "../artifacts/TestWeth.json";
import LiquifiGovernanceRouterArtifact from "../artifacts/LiquifiGovernanceRouter.json";
import LiquifiActivityMeterArtifact from "../artifacts/LiquifiActivityMeter.json";
import LiquifiMinterArtifact from "../artifacts/LiquifiMinter.json";

import { TestToken } from "../typechain/TestToken"
import { TestWeth } from "../typechain/TestWeth"
import { LiquifiPoolRegister } from "../typechain/LiquifiPoolRegister"
import { LiquifiPoolFactory } from "../typechain/LiquifiPoolFactory"
import { LiquifiDelayedExchangePoolFactory } from "../typechain/LiquifiDelayedExchangePoolFactory"
import { orderHistory, wait, lastBlockTimestamp, traceDebugEvents } from "./util/DebugUtils";
import { LiquifiGovernanceRouter } from "../typechain/LiquifiGovernanceRouter";
import { LiquifiMinter } from "../typechain/LiquifiMinter";
import { ok } from "assert";
import { assert } from "console";
import { LogDescription } from "ethers/lib/utils";

chai.use(solidity);
const { expect } = chai;

describe("Liquifi Pool Register", () => {

    var registerOwner: Wallet;
    var liquidityProvider: Wallet;
    var factoryOwner: Wallet;
    var otherTrader: Wallet;

    var tokenA: TestToken;
    var tokenB: TestToken;
	var lqf: TestToken;
    var weth: TestWeth;

    var register: LiquifiPoolRegister;
    var factory: LiquifiPoolFactory;

    beforeEach(async () => {
        [registerOwner, liquidityProvider, factoryOwner, otherTrader] = await ethers.getSigners() as Wallet[];

        tokenA = await deployContract(liquidityProvider, TestTokenArtifact, [token(10000000), "Token A", "TKA", [await otherTrader.getAddress()]]) as TestToken
        tokenB = await deployContract(liquidityProvider, TestTokenArtifact, [token(10000000), "Token B", "TKB", [await otherTrader.getAddress()]]) as TestToken
		lqf = tokenA

        weth = await deployContract(liquidityProvider, TestWethArtifact, []) as TestWeth;
        
		const governanceRouter = await deployContract(factoryOwner, LiquifiGovernanceRouterArtifact, [3600, weth.address]) as LiquifiGovernanceRouter;
		governanceRouter.connect(factoryOwner).setMinter(lqf.address)
		
        factory = await deployContract(factoryOwner, LiquifiPoolFactoryArtifact, [governanceRouter.address], { gasLimit: 9500000 }) as LiquifiPoolFactory;
        await deployContract(factoryOwner, LiquifiActivityMeterArtifact, [governanceRouter.address]);
        register = await deployContract(registerOwner, LiquifiPoolRegisterArtifact, [governanceRouter.address, token(100000)]) as LiquifiPoolRegister
    })

    it("should deploy all contracts", async () => {
        expect(tokenA.address).to.be.properAddress
        expect(tokenB.address).to.be.properAddress
        expect(weth.address).to.be.properAddress
        expect(factory.address).to.be.properAddress
        expect(register.address).to.be.properAddress
    })

    it("should deposit tokens to a new pool", async () => {
        await addLiquidity(token(100), token(100));
        expect(await factory.getPoolCount()).to.be.eq(1)
    })

    it("should deposit ETH to a new pool", async () => {
        await tokenA.connect(liquidityProvider).approve(register.address, token(100));        
        await register.connect(liquidityProvider).depositWithETH(tokenA.address, token(100), 
            await liquidityProvider.getAddress(), 42949672960, { value: token(100) });
        expect(await factory.getPoolCount()).to.be.eq(1);
    })
    
    it("should claim order", async() => {
        await addLiquidity(token(100), token(100));
        const time0 = await lastBlockTimestamp(ethers);
        await tokenA.connect(liquidityProvider).approve(register.address, token(100));
        const tx = await register.connect(liquidityProvider).delayedSwap(
            tokenA.address, 
            token(100), 
            tokenB.address, 
            token(1),
            await liquidityProvider.getAddress(), 
            time0.add(5),
            0,
            0);
        
        await wait(ethers, 10);
        const pool = await LiquifiDelayedExchangePoolFactory.connect(await factory.findPool(tokenA.address, tokenB.address), factoryOwner);  
        let poolQueue = await pool.poolQueue();
        const firstOrderId = poolQueue.firstByTimeout;
        const [orderHash, orderHistoryList] = await orderHistory(pool, tx, firstOrderId);
        expect(await register.claimOrder(tokenA.address, tokenB.address, orderHash, orderHistoryList,  time0.add(20000))).to.be.ok;
    });


    it("should withdraw tokens", async () => {
        await addLiquidity(token(100), token(100));
        await addLiquidity(token(20), token(20), otherTrader);

        const pool = await LiquifiDelayedExchangePoolFactory.connect(await factory.findPool(tokenA.address, tokenB.address), factoryOwner)
        const liquidity = await pool.balanceOf(await otherTrader.getAddress());
        await pool.connect(otherTrader).approve(register.address, liquidity);
        expect(liquidity).to.be.eq(token(20));

        await register.connect(otherTrader).withdraw(tokenA.address, tokenB.address, liquidity, await otherTrader.getAddress(), 42949672960);
        expect(await pool.balanceOf(await otherTrader.getAddress())).to.be.eq(token(0))
    })

    it("should not withdraw more too much liquidity", async () => {
        await addLiquidity(token(100), token(100));
        await addLiquidity(token(20), token(20), otherTrader);

        const pool = await LiquifiDelayedExchangePoolFactory.connect(await factory.findPool(tokenA.address, tokenB.address), factoryOwner)
        const liquidity = await pool.balanceOf(await otherTrader.getAddress());
        await pool.connect(otherTrader).approve(register.address, liquidity.mul(2));
        expect(liquidity).to.be.eq(token(20));

        await expect(register.connect(otherTrader).withdraw(tokenA.address, tokenB.address, liquidity.mul(2), await otherTrader.getAddress(), 42949672960)).to.be.revertedWith("LIQIFI: TRANSFER_FROM_FAILED");
    })

    it("should swap with ETH", async () => {
        const provider = await liquidityProvider.getAddress();
        await tokenB.connect(liquidityProvider).approve(register.address, token(1000));        
        await register.connect(liquidityProvider).depositWithETH(tokenB.address, token(1000), 
            await liquidityProvider.getAddress(), 42949672960, { value: token(1).div(2) });
        
        const time0 = await lastBlockTimestamp(ethers);

        // const pool = await LiquifiDelayedExchangePoolFactory.connect(await factory.findPool(weth.address, tokenB.address), factoryOwner)
        // console.log('weth ' + BigNumber.from(weth.address));
        // console.log('tokenA ' + BigNumber.from(await pool.tokenA()));
        // console.log('tokenB ' + BigNumber.from(await pool.tokenB()));

        await tokenB.connect(liquidityProvider).approve(register.address, token(10));
        await register.connect(liquidityProvider).delayedSwapToETH(
            tokenB.address, 
            token(10), 
            token(1).div(100000),
            provider, 
            time0.add(300),
            0,
            0);

        await wait(ethers, 400);
        await register.connect(liquidityProvider).processDelayedOrders(weth.address, tokenB.address, time0.add(3000));

        const balanceBefore = await tokenB.balanceOf(provider);
        expect(await register.connect(liquidityProvider).swapFromETH(
            tokenB.address,
            token(18),
            provider, 
            time0.add(2000),
            { value: token(1).div(100) }
            )).to.be.ok;
        const balanceAfter = await tokenB.balanceOf(provider);
        expect(balanceAfter.sub(balanceBefore)).to.be.gt(token(18));
    });

    it("should allow instant swap with no fee", async() => {
        let availableA = token(100);
        let availableB = token(200);

        await addLiquidity(availableA, availableB);

        const pool = await LiquifiDelayedExchangePoolFactory.connect(await factory.findPool(tokenA.address, tokenB.address), factoryOwner)
        //const events = traceDebugEvents(pool, 30);

        const time0 = await lastBlockTimestamp(ethers);
        await tokenA.connect(liquidityProvider).approve(register.address, token(100));
        const delayedSwapTx = await register.connect(liquidityProvider).delayedSwap(
            tokenA.address, 
            token(100), 
            tokenB.address, 
            token(1),
            await liquidityProvider.getAddress(), 
            time0.add(20),
            0,
            0);
        
        await wait(ethers, 10);
        await tokenA.connect(liquidityProvider).approve(register.address, token(100));
        await tokenB.connect(liquidityProvider).approve(register.address, token(100));

        expect(await register.connect(liquidityProvider).swap(tokenA.address,  //wrong direction for arbitrage
            token(10), 
            tokenB.address, 
            token(1),
            await liquidityProvider.getAddress(), 
            time0.add(2000))).to.be.ok;

        expect(await register.connect(liquidityProvider).swap(tokenB.address, //proper direction for arbitrage
            token(10), 
            tokenA.address, 
            token(1),
            await liquidityProvider.getAddress(), 
            time0.add(2000))).to.be.ok;
        
        await wait(ethers, 15);

        expect(await register.connect(liquidityProvider).swap(tokenA.address, //too late for arbitrage
            token(10), 
            tokenB.address, 
            token(1),
            await liquidityProvider.getAddress(), 
            time0.add(2000))).to.be.ok;

        const swapEvents = await getSwapEvent(delayedSwapTx.blockNumber);
       
        expect(swapEvents[0].args.fee).to.eq(3);
        expect(swapEvents[1].args.fee).to.eq(0);
        expect(swapEvents[2].args.fee).to.eq(3);
        //await events;
    });

    it("should not allow instant swap with no fee with too big amount", async() => {
        let availableA = token(100);
        let availableB = token(200);

        await addLiquidity(availableA, availableB);

        const pool = await LiquifiDelayedExchangePoolFactory.connect(await factory.findPool(tokenA.address, tokenB.address), factoryOwner)
        //const events = traceDebugEvents(pool, 30);

        const time0 = await lastBlockTimestamp(ethers);
        await tokenA.connect(liquidityProvider).approve(register.address, token(100));
        const delayedSwapTx = await register.connect(liquidityProvider).delayedSwap(
            tokenA.address, 
            token(100), 
            tokenB.address, 
            token(1),
            await liquidityProvider.getAddress(), 
            time0.add(20),
            0,
            0);
        
        await wait(ethers, 10);
        await tokenB.connect(liquidityProvider).approve(register.address, token(100));

        expect(await register.connect(liquidityProvider).swap(tokenB.address, //proper direction for arbitrage
            token(90), // too big amount: order is only processed for  token(50) at this moment
            tokenA.address, 
            token(1),
            await liquidityProvider.getAddress(), 
            time0.add(2000))).to.be.ok;

        const swapEvents = await getSwapEvent(delayedSwapTx.blockNumber);
       
        expect(swapEvents[0].args.fee).to.eq(3);
        //await events;
    });

    it("no fee rules should consider opposite orders", async() => {
        let availableA = token(10000);
        let availableB = token(20000);

        await addLiquidity(availableA, availableB);

        const pool = await LiquifiDelayedExchangePoolFactory.connect(await factory.findPool(tokenA.address, tokenB.address), factoryOwner)
        //const events = traceDebugEvents(pool, 10);

        const time0 = await lastBlockTimestamp(ethers);
        await tokenA.connect(liquidityProvider).approve(register.address, token(10000));
        await tokenB.connect(liquidityProvider).approve(register.address, token(10000));
        const delayedSwapTx = await register.connect(liquidityProvider).delayedSwap(
            tokenA.address, 
            token(100), 
            tokenB.address, 
            token(1),
            await liquidityProvider.getAddress(), 
            time0.add(20),
            0,
            0);
        await wait(ethers, 1);
        await register.connect(liquidityProvider).delayedSwap( //stops flow, only about token(10) are available for arbitrage
            tokenB.address, 
            token(212), 
            tokenA.address, 
            token(1),
            await liquidityProvider.getAddress(), 
            time0.add(20),
            0,
            0);
        await wait(ethers, 10);
        
        expect(await register.connect(liquidityProvider).swap(tokenB.address, //first order arbitrage
            token(80), // good amount if there were no second order
            tokenA.address, 
            token(1).div(10),
            await liquidityProvider.getAddress(), 
            time0.add(2000))).to.be.ok;

        expect(await register.connect(liquidityProvider).swap(tokenA.address, //second order arbitrage
            token(40), // good amount if there were no first order. But first is neutralized by first swap. So, there will be no fee
            tokenB.address, 
            token(1),
            await liquidityProvider.getAddress(), 
            time0.add(2000))).to.be.ok;

        const swapEvents = await getSwapEvent(delayedSwapTx.blockNumber);
       
        expect(swapEvents[0].args.fee).to.eq(3);
        expect(swapEvents[1].args.fee).to.eq(0);
        //await events;
    });

    async function getSwapEvent(fromBlock: number|undefined): Promise<LogDescription[]> {
        const eventFragment = register.interface.getEvent("Swap");
        const topic = register.interface.getEventTopic(eventFragment);
        const filter = { topics: [topic], address: register.address, fromBlock };
        const swapLogs = await register.provider.getLogs(filter);
        return swapLogs.map(log => register.interface.parseLog(log));

    }

    async function getDelayedSwapEvent(fromBlock: number|undefined): Promise<LogDescription[]> {
        const eventFragment = register.interface.getEvent("DelayedSwap");
        const topic = register.interface.getEventTopic(eventFragment);
        const filter = { topics: [topic], address: register.address, fromBlock };
        const swapLogs = await register.provider.getLogs(filter);
        return swapLogs.map(log => register.interface.parseLog(log));

    }
	
	
    // it("should deposit tokens on existing pool", async () => {
    //     await addLiquidity(100, 100);

    //     await tokenA.connect(liquidityProvider).approve(register.address, token(50))
    //     await tokenB.connect(liquidityProvider).approve(register.address, token(50))
    //     await register.connect(liquidityProvider).deposit(tokenA.address, token(50), tokenB.address, token(50))

    //     const pool = await LiquifiDelayedExchangePoolFactory.connect(await factory.findPool(tokenA.address, tokenB.address), factoryOwner)

    //     expect(await tokenA.balanceOf(pool.address)).to.be.eq(token(150))
    //     expect(await tokenB.balanceOf(pool.address)).to.be.eq(token(150));
        
    //     expect(await pool.balanceA()).to.be.eq(token(150))
    //     expect(await pool.balanceB()).to.be.eq(token(150))
    //     expect(await pool.balanceOf(await liquidityProvider.getAddress())).to.be.eq(token(150))
    // })

    // it("should swap tokens A -> B", async () => {
    //     await addLiquidity(100, 100);
    //     await tokenA.connect(liquidityProvider).approve(register.address, token(10))
        
    //     const amountInWithFee = token(10).mul(997);
    //     const numerator = amountInWithFee.mul(token(100));
    //     const denominator = token(100).mul(1000).add(amountInWithFee);
    //     const amountOut = numerator.div(denominator);
        

    //     expect(await register.connect(liquidityProvider).swap(tokenA.address, tokenB.address, token(10))).is.ok
    //     expect(await tokenA.balanceOf(await liquidityProvider.getAddress())).to.be.eq(token(890))
    //     expect(await tokenB.balanceOf(await liquidityProvider.getAddress())).to.be.eq(token(900).add(amountOut))
    // })

    // it("should swap tokens B -> A", async () => {
    //     await addLiquidity(100, 100);
    //     await tokenB.connect(liquidityProvider).approve(register.address, token(10))

    //     const amountInWithFee = token(10).mul(997);
    //     const numerator = amountInWithFee.mul(token(100));
    //     const denominator = token(100).mul(1000).add(amountInWithFee);
    //     const amountOut = numerator.div(denominator);

    //     expect(await register.connect(liquidityProvider).swap(tokenB.address, tokenA.address, token(10))).is.ok
    //     expect(await tokenA.balanceOf(await liquidityProvider.getAddress())).to.be.eq(token(900).add(amountOut))
    //     expect(await tokenB.balanceOf(await liquidityProvider.getAddress())).to.be.eq(token(890))
    // })

    // it("should add delayed swap order", async () => {
    //     await addLiquidity(100, 100);
    //     await tokenA.connect(liquidityProvider).approve(register.address, token(10))
    //     expect(await register.connect(liquidityProvider).delayedSwap(tokenA.address, tokenB.address, 10, token(10), token(10), token(8))).is.ok
    // })

    async function addLiquidity(amountA: BigNumber, amountB: BigNumber, _liquidityProvider: Wallet = liquidityProvider) {
        await tokenA.connect(_liquidityProvider).approve(register.address, amountA)
        await tokenB.connect(_liquidityProvider).approve(register.address, amountB);
        await register.connect(_liquidityProvider).deposit(tokenA.address, amountA, tokenB.address, amountB, 
            await _liquidityProvider.getAddress(), 42949672960);
    }

	it("should setup a new distribution pool", async () => {
		await addLiquidity(token(100000), token(10000));

        await tokenA.connect(liquidityProvider).approve(register.address, token(100000))
		expect(
			await register.connect(liquidityProvider).setupDistributionPool(
				tokenA.address, tokenB.address, 0, BigNumber.from(1000000), 200)).to.be.ok;
    })

	it("should update an existing distribution pool", async () => {
		const provider = await liquidityProvider.getAddress()
		await addLiquidity(token(100000), token(10000));

        await tokenA.connect(liquidityProvider).approve(register.address, token(100000))
		expect(
			await register.connect(liquidityProvider).setupDistributionPool(
				tokenA.address, tokenB.address, 0, BigNumber.from(1000000), 200)).to.be.ok;

		expect(await tokenA.balanceOf(provider)).to.eq(token(9800000))

        await tokenA.connect(liquidityProvider).approve(register.address, token(1000000))
		expect(
			await register.connect(liquidityProvider).updateDistributionPool(
				tokenA.address, tokenB.address, token(1000000), BigNumber.from(100000), 255)).to.be.ok;

		expect(await tokenA.balanceOf(provider)).to.eq(token(8800000))

	})

	it("should remove an existing distribution pool", async () => {
		const provider = await liquidityProvider.getAddress()
		await addLiquidity(token(100000), token(10000));

        await tokenA.connect(liquidityProvider).approve(register.address, token(1100000))
		expect(
			await register.connect(liquidityProvider).setupDistributionPool(
				tokenA.address, tokenB.address, token(1000000), BigNumber.from(1000000), 200)).to.be.ok;

		expect(await tokenA.balanceOf(provider)).to.eq(token(8800000))

		expect(
			await register.connect(liquidityProvider).removeDistributionPool(
				tokenA.address, tokenB.address)).to.be.ok;

		expect(await tokenA.balanceOf(provider)).to.eq(token(9900000))

	})

	it("cannot setup a new distribution pool that exists", async () => {
		await addLiquidity(token(100000), token(10000));

        await tokenA.connect(liquidityProvider).approve(register.address, token(100000))
		expect(
			await register.connect(liquidityProvider).setupDistributionPool(
				tokenA.address, tokenB.address, 0, BigNumber.from(1000000), 200)).to.be.ok;

		await tokenA.connect(liquidityProvider).approve(register.address, token(100000))
		await expect(register.connect(liquidityProvider).setupDistributionPool(
				tokenA.address, tokenB.address, 0, BigNumber.from(1000000), 200)).to.be.revertedWith("LIQIFI: DPOOL_ALREADY_EXISTS");
    })

	it("cannot update a distribution pool if not the owner", async () => {
		await addLiquidity(token(100000), token(10000));

        await tokenA.connect(liquidityProvider).approve(register.address, token(100000))
		expect(
			await register.connect(liquidityProvider).setupDistributionPool(
				tokenA.address, tokenB.address, 0, BigNumber.from(1000000), 200)).to.be.ok;

        await tokenA.connect(otherTrader).approve(register.address, token(1000000))
		await expect(register.connect(otherTrader).updateDistributionPool(
				tokenA.address, tokenB.address, token(1000000), BigNumber.from(100000), 255)).to.be.revertedWith("LIQIFI: SENDER_IS_NOT_DPOOL_OWNER");
    })

	it("cannot remove an existing distribution pool if not the owner", async () => {
		const provider = await liquidityProvider.getAddress()
		await addLiquidity(token(100000), token(10000));

        await tokenA.connect(liquidityProvider).approve(register.address, token(1100000))
		expect(
			await register.connect(liquidityProvider).setupDistributionPool(
				tokenA.address, tokenB.address, token(1000000), BigNumber.from(1000000), 200)).to.be.ok;

		expect(await tokenA.balanceOf(provider)).to.eq(token(8800000))

		await expect(register.connect(otherTrader).removeDistributionPool(
				tokenA.address, tokenB.address)).to.be.revertedWith("LIQIFI: SENDER_IS_NOT_DPOOL_OWNER");

	})

	it("should do delayed swap against a distribution pool", async () => {
		const provider = await liquidityProvider.getAddress()
		const trader = await otherTrader.getAddress()
		await addLiquidity(token(100000), token(10000))

		await tokenA.connect(liquidityProvider).approve(register.address, token(1100000))
		expect(
			await register.connect(liquidityProvider).setupDistributionPool(
				tokenA.address, tokenB.address, token(1000000), BigNumber.from(50000), 200)).to.be.ok
				
		expect(await tokenA.balanceOf(provider)).to.eq(token(8800000))
		expect(await tokenB.balanceOf(provider)).to.eq(token(9990000))

        const time0 = await lastBlockTimestamp(ethers);
        await tokenB.connect(otherTrader).approve(register.address, token(10000));
        const tx = await register.connect(otherTrader).delayedSwap(
            tokenB.address, 
            token(10000), 
            tokenA.address, 
            token(70),
            trader, 
            time0.add(300),
            0,
            0);

        const delayedSwapEvents = await getDelayedSwapEvent(tx.blockNumber);
       
        expect(delayedSwapEvents[0].args.tokenIn).to.eq(tokenB.address);
		const directOrderId = delayedSwapEvents[0].args.orderId
        expect(delayedSwapEvents[1].args.tokenIn).to.eq(tokenA.address);
		const counterOrderId = delayedSwapEvents[1].args.orderId
		const counterAmount = delayedSwapEvents[1].args.amountIn

			
        await wait(ethers, 400);
        const pool = await LiquifiDelayedExchangePoolFactory.connect(await factory.findPool(tokenA.address, tokenB.address), factoryOwner);  

        const [orderHash1, orderHistoryList1] = await orderHistory(pool, tx, directOrderId);
        expect(await register.connect(otherTrader).claimOrder(tokenA.address, tokenB.address, orderHash1, orderHistoryList1,  time0.add(20000))).to.be.ok;

        const [orderHash2, orderHistoryList2] = await orderHistory(pool, tx, counterOrderId);
        expect(await register.connect(liquidityProvider).claimOrder(tokenA.address, tokenB.address, orderHash2, orderHistoryList2,  time0.add(20000))).to.be.ok;

		expect(await tokenA.balanceOf(provider)).to.be.eq(token(8800000))

		expect(await tokenA.balanceOf(trader)).to.be.gt(token(10085000))
		expect(await tokenA.balanceOf(trader)).to.be.lt(token(10090000))
		
		expect(await tokenB.balanceOf(provider)).to.be.gt(token(9990000))
		expect(await tokenB.balanceOf(provider)).to.be.lt(token(10000000))

		expect(await tokenB.balanceOf(trader)).to.be.eq(token(9990000))
		
		expect(
			await register.connect(liquidityProvider).removeDistributionPool(
				tokenA.address, tokenB.address)).to.be.ok;

		expect(await tokenA.balanceOf(provider)).to.be.eq(token(9900000).sub(counterAmount))

	})

	it("should not do a counter swap when a distribution pool is not set", async () => {
		const provider = await liquidityProvider.getAddress()
		const trader = await otherTrader.getAddress()
		await addLiquidity(token(100000), token(10000))

        const time0 = await lastBlockTimestamp(ethers);
        await tokenB.connect(otherTrader).approve(register.address, token(10000));
        const tx = await register.connect(otherTrader).delayedSwap(
            tokenB.address, 
            token(10000), 
            tokenA.address, 
            token(70),
            trader, 
            time0.add(300),
            0,
            0);

        const delayedSwapEvents = await getDelayedSwapEvent(tx.blockNumber);
		expect(delayedSwapEvents.length).to.be.eq(1);
	})

	it("should not do a counter swap when a distribution pool has 0 tokens", async () => {
		const provider = await liquidityProvider.getAddress()
		const trader = await otherTrader.getAddress()
		await addLiquidity(token(100000), token(10000))

		await tokenA.connect(liquidityProvider).approve(register.address, token(100000))
		expect(
			await register.connect(liquidityProvider).setupDistributionPool(
				tokenA.address, tokenB.address, 0, BigNumber.from(50000), 200)).to.be.ok
				
		expect(await tokenA.balanceOf(provider)).to.eq(token(9800000))
		expect(await tokenB.balanceOf(provider)).to.eq(token(9990000))

        const time0 = await lastBlockTimestamp(ethers);
        await tokenB.connect(otherTrader).approve(register.address, token(10000));
        const tx = await register.connect(otherTrader).delayedSwap(
            tokenB.address, 
            token(10000), 
            tokenA.address, 
            token(70),
            trader, 
            time0.add(300),
            0,
            0);

        const delayedSwapEvents = await getDelayedSwapEvent(tx.blockNumber);
		expect(delayedSwapEvents.length).to.be.eq(1);
	})

	it("should not do a counter swap when a below the minimum price", async () => {
		const provider = await liquidityProvider.getAddress()
		const trader = await otherTrader.getAddress()
		await addLiquidity(token(100000), token(10000))

		await tokenA.connect(liquidityProvider).approve(register.address, token(1100000))
		expect(
			await register.connect(liquidityProvider).setupDistributionPool(
				tokenA.address, tokenB.address, token(1000000), BigNumber.from(100001), 200)).to.be.ok
				
		expect(await tokenA.balanceOf(provider)).to.eq(token(8800000))
		expect(await tokenB.balanceOf(provider)).to.eq(token(9990000))

        const time0 = await lastBlockTimestamp(ethers);
        await tokenB.connect(otherTrader).approve(register.address, token(10000));
        const tx = await register.connect(otherTrader).delayedSwap(
            tokenB.address, 
            token(10000), 
            tokenA.address, 
            token(70),
            trader, 
            time0.add(300),
            0,
            0);

        const delayedSwapEvents = await getDelayedSwapEvent(tx.blockNumber);
		expect(delayedSwapEvents.length).to.be.eq(1);
	})

})