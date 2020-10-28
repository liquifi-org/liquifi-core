import chai from "chai";

import { ethers } from "@nomiclabs/buidler";
import { deployContract, solidity } from "ethereum-waffle";
import { Wallet, BigNumber, utils } from "ethers"
import { token } from "./util/TokenUtil";

import LiquifiDelayedExchangePoolArtifact from "../artifacts/LiquifiDelayedExchangePool.json";
import TestTokenArtifact from "../artifacts/TestToken.json";
import LiquifiGovernanceRouterArtifact from "../artifacts/LiquifiGovernanceRouter.json";
import LiquifiActivityMeterArtifact from "../artifacts/LiquifiActivityMeter.json";
import LiquifiPoolRegisterArtifact from "../artifacts/LiquifiPoolRegister.json";
import LiquifiPoolFactoryArtifact from "../artifacts/LiquifiPoolFactory.json";
import LiquifiMinterArtifact from "../artifacts/LiquifiMinter.json";


import { TestToken } from "../typechain/TestToken"
import { LiquifiActivityMeter } from "../typechain/LiquifiActivityMeter"
import { LiquifiMinter } from "../typechain/LiquifiMinter"
import { LiquifiPoolFactoryFactory } from "../typechain/LiquifiPoolFactoryFactory";
import { LiquifiGovernanceRouter } from "../typechain/LiquifiGovernanceRouter"
import { LiquifiDelayedExchangePool } from "../typechain/LiquifiDelayedExchangePool";
import { LiquifiPoolRegister } from "../typechain/LiquifiPoolRegister";
import { LiquifiDelayedExchangePoolFactory } from "../typechain/LiquifiDelayedExchangePoolFactory";
import { orderHistory, collectEvents, lastBlockTimestamp, traceDebugEvents } from "./util/DebugUtils";
import { AddressZero } from "@ethersproject/constants";


chai.use(solidity);
const { expect } = chai;

describe("Liquifi Activity Meter", () => {

    var liquidityProvider: Wallet;
    var factoryOwner: Wallet;
    var otherTrader: Wallet;

    var tokenA: TestToken;
    var tokenB: TestToken;
    var weth: TestToken;

    var activityMeter: LiquifiActivityMeter;
    var minter: LiquifiMinter;
    var register: LiquifiPoolRegister;
    var governanceRouter: LiquifiGovernanceRouter;

    beforeEach(async () => {
        [liquidityProvider, factoryOwner, otherTrader] = await ethers.getSigners() as Wallet[];
        
        tokenA = await deployContract(liquidityProvider, TestTokenArtifact, [token(1000), "Token A", "TKA", [await otherTrader.getAddress()]]) as TestToken
        tokenB = await deployContract(liquidityProvider, TestTokenArtifact, [token(1000), "Token B", "TKB", [await otherTrader.getAddress()]]) as TestToken
        if (BigNumber.from(tokenA.address).lt(BigNumber.from(tokenB.address))) {
            [tokenA, tokenB] = [tokenB, tokenA];
        }
        weth = tokenA;
        governanceRouter = await deployContract(factoryOwner, LiquifiGovernanceRouterArtifact, [60, weth.address]) as LiquifiGovernanceRouter;
        activityMeter = await deployContract(factoryOwner, LiquifiActivityMeterArtifact, [governanceRouter.address]) as LiquifiActivityMeter;
        minter = await deployContract(factoryOwner, LiquifiMinterArtifact, [governanceRouter.address]) as LiquifiMinter;
        await deployContract(factoryOwner, LiquifiPoolFactoryArtifact, [governanceRouter.address], { gasLimit: 9500000 });
        register = await deployContract(factoryOwner, LiquifiPoolRegisterArtifact, [governanceRouter.address]) as LiquifiPoolRegister
    })

    it("should deploy all contracts", async () => {
        expect(tokenA.address).to.be.properAddress;
        expect(tokenB.address).to.be.properAddress;
        expect(activityMeter.address).to.be.properAddress;
    })

    it("should register prices", async() => {
        const factory = await LiquifiPoolFactoryFactory.connect(await register.factory(), factoryOwner);
        const { _timeZero, _miningPeriod }  = await governanceRouter.schedule();
        
        //const events = traceDebugEvents(activityMeter, 1);
        const time0 = await lastBlockTimestamp(ethers);
        await addLiquidity(token(1), token(100)); // total supply = 10
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        const time1 = await lastBlockTimestamp(ethers);
        const lastPriceRecord1 = await activityMeter.poolSummaries(poolAddress);
        expect(lastPriceRecord1).to.be.eq(1);

        const firstPriceRecord = await activityMeter.poolsPriceHistory(lastPriceRecord1, poolAddress);
        expect(firstPriceRecord.lastEthPrice).to.be.eq(token(10).shl(112).div(token(1)));

        await tokenB.connect(liquidityProvider).approve(register.address, token(1000));
        await wait(2);
        expect(await register.connect(liquidityProvider).swap(tokenB.address, 
            token(80), 
            tokenA.address, 
            token(1).div(1000),
            await liquidityProvider.getAddress(), 
            4294467296)).to.be.ok;
        const time2 = await lastBlockTimestamp(ethers);

        await wait(2);
        expect(await register.connect(liquidityProvider).processDelayedOrders(tokenA.address, tokenB.address, 4294467296)).to.be.ok;
        
        const secondPriceRecord = await activityMeter.poolsPriceHistory(lastPriceRecord1, poolAddress);
        const elapsedQuanta1 = time1.sub(_timeZero).mul(2 ** 16).div(_miningPeriod);
        const elapsedQuanta2 = time2.sub(_timeZero).mul(2 ** 16).div(_miningPeriod);
        expect(secondPriceRecord.timeRef).to.be.eq(elapsedQuanta2);
        expect(secondPriceRecord.cumulativeEthPrice).to.be.eq(elapsedQuanta2.sub(elapsedQuanta1).mul(firstPriceRecord.lastEthPrice));
        
        await wait(180);
        await addLiquidity(token(1), token(100));

        const lastPriceRecord2 = await activityMeter.poolSummaries(poolAddress);
        expect(lastPriceRecord2).to.be.eq(4);

        const thirdPriceRecord = await activityMeter.poolsPriceHistory(lastPriceRecord1, poolAddress);
        expect(thirdPriceRecord.timeRef).to.be.eq(4);
        expect(thirdPriceRecord.cumulativeEthPrice).to.be.gt(BigNumber.from(2 ** 16).sub(elapsedQuanta1).mul(firstPriceRecord.lastEthPrice));
        
        
        const fourthPriceRecord = await activityMeter.poolsPriceHistory(lastPriceRecord2, poolAddress);
        expect(fourthPriceRecord.cumulativeEthPrice).to.be.eq(thirdPriceRecord.lastEthPrice.mul(fourthPriceRecord.timeRef));
    });

    it("should accept deposits", async() => {
        const factory = await LiquifiPoolFactoryFactory.connect(await register.factory(), factoryOwner);
        const { _timeZero, _miningPeriod }  = await governanceRouter.schedule();
        
        await addLiquidity(token(1), token(100)); // total supply = 10
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        const userAddress = await liquidityProvider.getAddress();
        const pool = await LiquifiDelayedExchangePoolFactory.connect(poolAddress, factoryOwner);  
        //const events = traceDebugEvents(pool, 1);
        expect(await pool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await pool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(1))).to.be.ok;
        const time0 = await lastBlockTimestamp(ethers);
        const elapsedQuanta0 = time0.sub(_timeZero).mul(2 ** 16).div(_miningPeriod);
        await wait(3);
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(2))).to.be.ok;
        const time1 = await lastBlockTimestamp(ethers);
        const elapsedQuanta1 = time1.sub(_timeZero).mul(2 ** 16).div(_miningPeriod);
        await wait(4);
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(3))).to.be.ok;
        const time2 = await lastBlockTimestamp(ethers);
        const elapsedQuanta2 = time2.sub(_timeZero).mul(2 ** 16).div(_miningPeriod);

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(1);
        expect(await activityMeter.userPools(userAddress, 0)).to.be.eq(poolAddress);

        const userPoolsSummary1 = await activityMeter.userPoolsSummaries(userAddress, poolAddress);
        expect(userPoolsSummary1.lastAmountLocked).to.be.eq(token(6));
        expect(userPoolsSummary1.cumulativeAmountLocked).to.be.eq(
            token(1).mul(elapsedQuanta1.sub(elapsedQuanta0)).add(
                token(3).mul(elapsedQuanta2.sub(elapsedQuanta1))
            )
        );

        await wait(180);
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(1))).to.be.ok;
        const time3 = await lastBlockTimestamp(ethers);
        const elapsedQuanta3 = time3.sub(_timeZero).mod(_miningPeriod).mul(2 ** 16).div(_miningPeriod);
        
        const userPoolsSummary2 = await activityMeter.userPoolsSummaries(userAddress, poolAddress);
        expect(userPoolsSummary2.lastAmountLocked).to.be.eq(token(7));
        expect(userPoolsSummary2.cumulativeAmountLocked).to.be.eq(token(6).mul(elapsedQuanta3));

        await wait(60);
        expect(await activityMeter.actualizeUserPool(4, userAddress, poolAddress)).to.be.ok;

        //await events;
    });

    it("should allow withdraw", async() => {
        const factory = await LiquifiPoolFactoryFactory.connect(await register.factory(), factoryOwner);
        
        await addLiquidity(token(1), token(100)); // total supply = 10
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        const userAddress = await liquidityProvider.getAddress();
        const pool = await LiquifiDelayedExchangePoolFactory.connect(poolAddress, factoryOwner);  
        pool.connect(liquidityProvider).approve(activityMeter.address, token(7));
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(7))).to.be.ok;
        const balanceUser1 = await pool.balanceOf(userAddress);
        const balanceAM1 = await pool.balanceOf(activityMeter.address);
        expect(balanceAM1).to.be.eq(token(7));
        await wait(2);
        expect(await activityMeter.connect(liquidityProvider).withdraw(poolAddress, token(2))).to.be.ok;
        const balanceUser2 = await pool.balanceOf(userAddress);
        const balanceAM2 = await pool.balanceOf(activityMeter.address);
        expect(balanceAM2).to.be.eq(token(5));
        expect(balanceUser2.sub(balanceUser1)).to.be.eq(token(2));
        const userPoolsSummary1 = await activityMeter.userPoolsSummaries(userAddress, poolAddress);
        expect(userPoolsSummary1.lastAmountLocked).to.be.eq(token(5));
    });

    it("should compute ethLocked and govTokens", async() => {
        const factory = await LiquifiPoolFactoryFactory.connect(await register.factory(), factoryOwner);
        const { _timeZero, _miningPeriod }  = await governanceRouter.schedule();
        const initialPeriodTokens = await minter.initialPeriodTokens();
        const startTokens = token(2500000);
        const dNum = BigNumber.from(250);
        const dDen = BigNumber.from(256);
        //const events = traceDebugEvents(activityMeter, 1);
        const QUANTA = BigNumber.from(2 ** 16);
        
        // period 1: price P0, amount: 0
        const D1 = BigNumber.from(1).shl(128);
        const tx1 = await addLiquidity(token(1), token(100)); // total supply = 10
        await activityMeter.connect(liquidityProvider).actualizeUserPools();
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        const userAddress = await liquidityProvider.getAddress();
        const otherTraderAddress = await otherTrader.getAddress();
        const pool = await LiquifiDelayedExchangePoolFactory.connect(poolAddress, factoryOwner);
        const lastPrice1 = token(10).shl(112).div(token(1));  
        const priceRecord1 = await activityMeter.poolsPriceHistory(1, poolAddress);
        expect(priceRecord1.lastEthPrice).to.be.eq(lastPrice1);
        const userSummary1 = await activityMeter.userSummaries(userAddress);
        expect(userSummary1.ethLocked).to.be.eq(0);

        await pool.connect(liquidityProvider).transfer(await otherTrader.getAddress(), token(2));
        await pool.connect(otherTrader).approve(activityMeter.address, token(2));
        expect(await activityMeter.connect(otherTrader).deposit(poolAddress, token(2))).to.be.ok;

        await wait(60);

        // period 2: price P1, amount: A0
        const D2 = D1.mul(dNum).div(dDen);
        await activityMeter.connect(otherTrader).actualizeUserPools();
        pool.connect(liquidityProvider).approve(activityMeter.address, token(7));
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(7))).to.be.ok;
        const T2 = await lastBlockTimestamp(ethers);
        const EQ2 = T2.sub(_timeZero).mod(_miningPeriod).mul(QUANTA).div(_miningPeriod);
        const summary2 = await activityMeter.userPoolsSummaries(userAddress, poolAddress);
        expect(summary2.lastPriceRecord).to.be.eq(1);
        expect(summary2.lastAmountLocked).to.be.eq(token(7));
        const A0 = token(7).mul(QUANTA.sub(EQ2)).div(QUANTA);
        const A_OTHER = token(2);
        const P1 = priceRecord1.lastEthPrice;
        const userSummary2 = await activityMeter.userSummaries(userAddress);
        expect(userSummary2.ethLocked).to.be.eq(0);

        await wait(60);

        // period 3: price P1, amount: A1, otherTrader missed update
        const D3 = D2.mul(dNum).div(dDen);
        const A1 = token(7);
        await activityMeter.connect(liquidityProvider).actualizeUserPools();
        const userSummary3 = await activityMeter.userSummaries(userAddress);
        const userEthLocked3 = A0.shl(112).div(P1);
        const TOTAL3 = userEthLocked3;
        expect(userSummary3.ethLocked).to.be.eq(userEthLocked3);

        await wait(60);

        // period 4: price P2, amount: A1
        const D4 = D3.mul(dNum).div(dDen);
        await activityMeter.connect(liquidityProvider).actualizeUserPools();
        await activityMeter.connect(otherTrader).actualizeUserPools();
        await tokenB.connect(liquidityProvider).approve(register.address, token(1000));
        expect(await register.connect(liquidityProvider).swap(tokenB.address, 
            token(80), 
            tokenA.address, 
            token(1).div(1000),
            await liquidityProvider.getAddress(), 
            4294467296)).to.be.ok;
        const priceRecord4 = await activityMeter.poolsPriceHistory(4, poolAddress);
        const T4 = await lastBlockTimestamp(ethers);
        const EQ4 = T4.sub(_timeZero).mod(_miningPeriod).mul(QUANTA).div(_miningPeriod);
        const P2 = priceRecord1.lastEthPrice.mul(EQ4).add(
            priceRecord4.lastEthPrice.mul(QUANTA.sub(EQ4))
        ).div(QUANTA);
        const userSummary4 = await activityMeter.userSummaries(userAddress);
        const userEthLocked4 = A1.shl(112).div(P1);
        const TOTAL4 = userEthLocked4.add(A_OTHER.shl(112).div(P1).mul(2 /* otherTrader missed previous update */));
        expect(userSummary4.ethLocked).to.be.eq(userEthLocked4);

        await wait(60);

        // period 5: price P3, amount: A1, liquidityProvider missed update
        const D5 = D4.mul(dNum).div(dDen);
        const P3 = priceRecord4.lastEthPrice;
        await activityMeter.connect(otherTrader).actualizeUserPools();
        const userEthLocked5 = A1.shl(112).div(P2);
        const TOTAL5 = A_OTHER.shl(112).div(P2);
        
        await wait(60);

        // period 6: price P3, amount: A2
        const D6 = D5.mul(dNum).div(dDen);
        const tx6_OTHERS = await activityMeter.connect(otherTrader).actualizeUserPools();
        const tx6 = await activityMeter.connect(liquidityProvider).withdraw(poolAddress, token(2));
        expect(await tx6).to.be.ok;
        const T6 = await lastBlockTimestamp(ethers);
        const EQ6 = T6.sub(_timeZero).mod(_miningPeriod).mul(QUANTA).div(_miningPeriod);
        const A2 = token(7).mul(EQ6).add(
            token(5).mul(QUANTA.sub(EQ6))
        ).div(QUANTA);
        const userSummary6 = await activityMeter.userSummaries(userAddress);
        const userEthLocked6 = A1.shl(112).div(P3);
        const TOTAL6 = userEthLocked6.add(userEthLocked5).add(A_OTHER.shl(112).div(P3));
        expect(userSummary6.ethLocked).to.be.eq(userEthLocked6.add(userEthLocked5));
        let mints = await mintEvents(tx1.blockNumber);
        let userEthLocked = mints.reduce((sum, mint) => sum.add(mint.args.to == userAddress ? mint.args.userEthLocked : 0), BigNumber.from(0));
        expect(userEthLocked).to.be.eq(userEthLocked4.add(userEthLocked3));    

        mints = await mintEvents(tx6.blockNumber);
        let mint = mints.filter(mint => mint.args.to == userAddress)[0];
        expect(mint.args.totalEthLocked).to.be.eq(TOTAL4);
        let periodTokens = D3.mul(startTokens).shr(128);
        expect(mint.args.value).to.be.eq(periodTokens.mul(userEthLocked4).div(TOTAL4));

        mints = await mintEvents(tx6_OTHERS.blockNumber);
        mint = mints.filter(mint => mint.args.to == otherTraderAddress)[0];
        expect(mint.args.totalEthLocked).to.be.eq(TOTAL5);
        periodTokens = D4.mul(startTokens).shr(128);
        expect(mint.args.value).to.be.eq(periodTokens);

        await wait(60);

        // period 7: price P3, amount A3
        const D7 = D6.mul(dNum).div(dDen);
        const A3 = token(5);
        const govTokensPredicted = await minter.userTokensToClaim(userAddress);
        await activityMeter.connect(otherTrader).actualizeUserPools();
        const tx7 = await activityMeter.connect(liquidityProvider).actualizeUserPools();
        const userSummary7 = await activityMeter.userSummaries(userAddress);
        const userEthLocked7 = A2.shl(112).div(P3);
        expect(userSummary7.ethLocked).to.be.eq(userEthLocked7);

        mints = await mintEvents(tx7.blockNumber);
        mint = mints.filter(mint => mint.args.to == userAddress)[0];
        expect(mint.args.totalEthLocked).to.be.eq(TOTAL6);
        expect(mint.args.userEthLocked).to.be.eq(userEthLocked6.add(userEthLocked5));
        expect(mint.args.period).to.be.eq(5);
        periodTokens = D5.mul(startTokens).shr(128);
        expect(mint.args.value).to.be.eq(periodTokens.mul(userEthLocked6.add(userEthLocked5)).div(TOTAL6));
        expect(govTokensPredicted).to.be.eq(mint.args.value);

        await wait(60);

        // // period 8: not earned yet
        await activityMeter.connect(otherTrader).actualizeUserPools();
        expect(await activityMeter.actualizeUserPool(7, userAddress, poolAddress)).to.be.ok;
        const summary8 = await activityMeter.userPoolsSummaries(userAddress, poolAddress);
        expect(summary8.earnedForPeriod).to.be.eq(7);
        const userSummary8 = await activityMeter.userSummaries(userAddress);
        const userEthLocked8 = A3.shl(112).div(P3);
        expect(userSummary8.ethLocked).to.be.eq(userEthLocked8);


        mints = await mintEvents(tx1.blockNumber);
        userEthLocked = mints.reduce((sum, mint) => sum.add(mint.args.to == userAddress ? mint.args.userEthLocked : 0), BigNumber.from(0));
        expect(userEthLocked).to.be.eq(userEthLocked7.add(userEthLocked6).add(userEthLocked5).add(userEthLocked4).add(userEthLocked3));    

        //await events;
    });

    async function mintEvents(fromBlock: number | undefined): Promise<utils.LogDescription[]> {
        const eventFragment = minter.interface.getEvent("Mint");
        const topic = minter.interface.getEventTopic(eventFragment);
        const filter = { topics: [topic], address: minter.address, fromBlock: fromBlock  };
        const logs = await minter.provider.getLogs(filter);
        return logs.map(log => minter.interface.parseLog(log));
    }

    const wait = async (seconds: number) => {
        await ethers.provider.send("evm_increaseTime", [seconds - 1]);   
        await ethers.provider.send("evm_mine", []); // mine the next block
    }

    async function addLiquidity(amountA: BigNumber, amountB: BigNumber, _liquidityProvider: Wallet = liquidityProvider) {
        await tokenA.connect(_liquidityProvider).approve(register.address, amountA)
        await tokenB.connect(_liquidityProvider).approve(register.address, amountB);
        return await register.connect(_liquidityProvider).deposit(tokenA.address, amountA, tokenB.address, amountB, 
            await _liquidityProvider.getAddress(), 42949672960);
    }
})