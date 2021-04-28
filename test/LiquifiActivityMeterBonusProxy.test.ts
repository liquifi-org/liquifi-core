import chai from "chai";

import { ethers } from "@nomiclabs/buidler";
import { deployContract, solidity } from "ethereum-waffle";
import { Wallet, BigNumber, utils } from "ethers"
import { token } from "./util/TokenUtil";

import LiquifiDelayedExchangePoolArtifact from "../artifacts/LiquifiDelayedExchangePool.json";
import TestTokenArtifact from "../artifacts/TestToken.json";
import LiquifiGovernanceRouterArtifact from "../artifacts/LiquifiGovernanceRouter.json";
import LiquifiActivityMeterArtifact from "../artifacts/LiquifiActivityMeter.json";
import LiquifiActivityMeterBonusProxyArtifact from "../artifacts/LiquifiActivityMeterBonusProxy.json";
import LiquifiPoolRegisterArtifact from "../artifacts/LiquifiPoolRegister.json";
import LiquifiPoolFactoryArtifact from "../artifacts/LiquifiPoolFactory.json";
import LiquifiMinterArtifact from "../artifacts/LiquifiMinter.json";


import { TestToken } from "../typechain/TestToken"
import { LiquifiActivityMeter } from "../typechain/LiquifiActivityMeter"
import { LiquifiActivityMeterBonusProxy } from "../typechain/LiquifiActivityMeterBonusProxy"
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
        if (BigNumber.from(tokenA.address).gt(BigNumber.from(tokenB.address))) {
            [tokenA, tokenB] = [tokenB, tokenA];
        }
        weth = tokenA;

        governanceRouter = await deployContract(factoryOwner, LiquifiGovernanceRouterArtifact, [60, weth.address]) as LiquifiGovernanceRouter;
        activityMeter = await deployContract(factoryOwner, LiquifiActivityMeterArtifact, [governanceRouter.address]) as LiquifiActivityMeter;
        minter = await deployContract(factoryOwner, LiquifiMinterArtifact, [governanceRouter.address]) as LiquifiMinter;
        const factory = await deployContract(factoryOwner, LiquifiPoolFactoryArtifact, [governanceRouter.address], { gasLimit: 9500000 });
        register = await deployContract(factoryOwner, LiquifiPoolRegisterArtifact, [governanceRouter.address, token(100000)]) as LiquifiPoolRegister
	})

    it("should deploy all contracts", async () => {
        expect(tokenA.address).to.be.properAddress;
        expect(tokenB.address).to.be.properAddress;
        expect(activityMeter.address).to.be.properAddress;
    })

    it("should register lqf eth locked", async function done() {
		this.timeout(100000);

        const factory = await LiquifiPoolFactoryFactory.connect(await register.factory(), factoryOwner);
        const { _timeZero, _miningPeriod }  = await governanceRouter.schedule();
        
        await addLiquidity(token(1), token(100)); // total supply = 10
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        const userAddress = await liquidityProvider.getAddress();
        const pool = await LiquifiDelayedExchangePoolFactory.connect(poolAddress, factoryOwner);  
        expect(await pool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await pool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(1))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(1);
        expect(await activityMeter.userPools(userAddress, 0)).to.be.eq(poolAddress);

        await wait(70);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        await wait(60);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		expect(await minter.balanceOf(userAddress)).to.be.eq(token(2500000));

        await addLQFLiquidity(token(1), token(100));
        const lqfPoolAddress = await factory.findPool(tokenA.address, minter.address);

        const lqfPool = await LiquifiDelayedExchangePoolFactory.connect(lqfPoolAddress, factoryOwner);  
        expect(await lqfPool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await lqfPool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(lqfPoolAddress, token(1))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(2);
        expect(await activityMeter.userPools(userAddress, 1)).to.be.eq(lqfPoolAddress);

        const bonusProxy = await deployContract(factoryOwner, LiquifiActivityMeterBonusProxyArtifact, [activityMeter.address, lqfPoolAddress, minter.address]) as 		
				LiquifiActivityMeterBonusProxy;

        await wait(60);
		const lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(3);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
	});

    it("should transfer right bonus when only LQF pool deposited", async function done() {
		this.timeout(100000);

        const factory = await LiquifiPoolFactoryFactory.connect(await register.factory(), factoryOwner);
        const { _timeZero, _miningPeriod }  = await governanceRouter.schedule();
        
        await addLiquidity(token(1), token(100)); // total supply = 10
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        const userAddress = await liquidityProvider.getAddress();
        const pool = await LiquifiDelayedExchangePoolFactory.connect(poolAddress, factoryOwner);  
        expect(await pool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await pool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(1))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(1);
        expect(await activityMeter.userPools(userAddress, 0)).to.be.eq(poolAddress);

        await wait(70);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        await wait(60);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		expect(await minter.balanceOf(userAddress)).to.be.eq(token(2500000));
		
        await addLQFLiquidity(token(1), token(100));
        const lqfPoolAddress = await factory.findPool(tokenA.address, minter.address);

        const lqfPool = await LiquifiDelayedExchangePoolFactory.connect(lqfPoolAddress, factoryOwner);  
        expect(await lqfPool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await lqfPool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(lqfPoolAddress, token(1))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(2);
        expect(await activityMeter.userPools(userAddress, 1)).to.be.eq(lqfPoolAddress);

        const bonusProxy = await deployContract(factoryOwner, LiquifiActivityMeterBonusProxyArtifact, [activityMeter.address, lqfPoolAddress, minter.address]) as 		
				LiquifiActivityMeterBonusProxy;

		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));

		expect(await bonusProxy.bonusPayable(userAddress, 3)).to.be.eq(0);
		expect(await bonusProxy.totalBonus(1)).to.be.eq(0);

        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 4)).to.be.eq(0);
		expect(await bonusProxy.totalBonus(2)).to.be.eq(0);
		var lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(3);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
		
        expect(await activityMeter.connect(liquidityProvider).withdraw(poolAddress, token(1))).to.be.ok;
		
        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 5)).to.be.gt(0);
		expect(await bonusProxy.totalBonus(3)).to.be.eq(await bonusProxy.bonusPayable(userAddress, 5));
		lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(4);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);

        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 6)).to.be.gt(0);
		expect(await bonusProxy.totalBonus(4)).to.be.eq(await bonusProxy.bonusPayable(userAddress, 6));
		lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);
		var lqfBalanceOld = await minter.balanceOf(userAddress);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(5);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);

        await wait(60);
		lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);

		expect(await bonusProxy.bonusPayable(userAddress, 7)).to.be.eq(lqfToBeMinted.div(2));
		expect(await bonusProxy.totalBonus(5)).to.be.eq(lqfToBeMinted.div(2));

		var lqfBalanceOld = await minter.balanceOf(userAddress);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(6);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
		
		expect((await minter.balanceOf(userAddress)).sub(lqfBalanceOld)).to.be.eq(lqfToBeMinted.add(lqfToBeMinted.div(2)));
	});

    it("should transfer right bonus when two pools deposited", async function done() {
		this.timeout(100000);

        const factory = await LiquifiPoolFactoryFactory.connect(await register.factory(), factoryOwner);
        const { _timeZero, _miningPeriod }  = await governanceRouter.schedule();
        
        await addLiquidity(token(1), token(100)); // total supply = 10
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        const userAddress = await liquidityProvider.getAddress();
        const pool = await LiquifiDelayedExchangePoolFactory.connect(poolAddress, factoryOwner);  
        expect(await pool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await pool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(1))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(1);
        expect(await activityMeter.userPools(userAddress, 0)).to.be.eq(poolAddress);

        await wait(70);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        await wait(60);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		expect(await minter.balanceOf(userAddress)).to.be.eq(token(2500000));
		
        await addLQFLiquidity(token(1), token(100));
        const lqfPoolAddress = await factory.findPool(tokenA.address, minter.address);

        const lqfPool = await LiquifiDelayedExchangePoolFactory.connect(lqfPoolAddress, factoryOwner);  
        expect(await lqfPool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await lqfPool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(lqfPoolAddress, token(3))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(2);
        expect(await activityMeter.userPools(userAddress, 1)).to.be.eq(lqfPoolAddress);

        const bonusProxy = await deployContract(factoryOwner, LiquifiActivityMeterBonusProxyArtifact, [activityMeter.address, lqfPoolAddress, minter.address]) as 		
				LiquifiActivityMeterBonusProxy;

		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));

		expect(await bonusProxy.bonusPayable(userAddress, 3)).to.be.eq(0);
		expect(await bonusProxy.totalBonus(1)).to.be.eq(0);

        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 4)).to.be.eq(0);
		expect(await bonusProxy.totalBonus(2)).to.be.eq(0);
		var lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(3);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
		
        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 5)).to.be.gt(0);
		expect(await bonusProxy.totalBonus(3)).to.be.eq(await bonusProxy.bonusPayable(userAddress, 5));
		lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);
		var lqfBalanceOld = await minter.balanceOf(userAddress);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(4);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);

        await wait(60);
		lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);

		expect(await bonusProxy.bonusPayable(userAddress, 6)).to.be.eq(lqfToBeMinted.mul(3).div(8));
		expect(await bonusProxy.totalBonus(4)).to.be.eq(lqfToBeMinted.mul(3).div(8));

		var lqfBalanceOld = await minter.balanceOf(userAddress);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(5);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
		
		expect((await minter.balanceOf(userAddress)).sub(lqfBalanceOld)).to.be.eq(lqfToBeMinted.add(lqfToBeMinted.mul(3).div(8)));
	});
    
	it("should transfer right bonus when two liquidity providers", async function done() {
		this.timeout(100000);

        const factory = await LiquifiPoolFactoryFactory.connect(await register.factory(), factoryOwner);
        const { _timeZero, _miningPeriod }  = await governanceRouter.schedule();
        
        await addLiquidity(token(1), token(100)); // total supply = 10
        await addLiquidity(token(3), token(300), otherTrader);
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        const userAddress = await liquidityProvider.getAddress();
        const userAddress2 = await otherTrader.getAddress();
        const pool = await LiquifiDelayedExchangePoolFactory.connect(poolAddress, factoryOwner);  

        await pool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(1))).to.be.ok;

        await pool.connect(otherTrader).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(otherTrader).deposit(poolAddress, token(3))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(1);
        expect(await activityMeter.userPools(userAddress, 0)).to.be.eq(poolAddress);
        expect(await activityMeter.userPoolsLength(userAddress2)).to.be.eq(1);
        expect(await activityMeter.userPools(userAddress2, 0)).to.be.eq(poolAddress);

        await wait(70);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        expect(await activityMeter.connect(otherTrader).actualizeUserPools()).to.be.ok;
        await wait(60);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        expect(await activityMeter.connect(otherTrader).actualizeUserPools()).to.be.ok;
		
        await addLQFLiquidity(token(1), token(100));
        await addLQFLiquidity(token(3), token(300), otherTrader);
        const lqfPoolAddress = await factory.findPool(tokenA.address, minter.address);

        const lqfPool = await LiquifiDelayedExchangePoolFactory.connect(lqfPoolAddress, factoryOwner);  

        await lqfPool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(lqfPoolAddress, token(3))).to.be.ok;
        await lqfPool.connect(otherTrader).approve(activityMeter.address, token(9));
        expect(await activityMeter.connect(otherTrader).deposit(lqfPoolAddress, token(9))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(2);
        expect(await activityMeter.userPools(userAddress, 1)).to.be.eq(lqfPoolAddress);
        expect(await activityMeter.userPoolsLength(userAddress2)).to.be.eq(2);
        expect(await activityMeter.userPools(userAddress2, 1)).to.be.eq(lqfPoolAddress);

        const bonusProxy = await deployContract(factoryOwner, LiquifiActivityMeterBonusProxyArtifact, [activityMeter.address, lqfPoolAddress, minter.address]) as 		
				LiquifiActivityMeterBonusProxy;

		await minter.connect(otherTrader).transfer(bonusProxy.address, token(2000000));

		expect(await bonusProxy.bonusPayable(userAddress, 3)).to.be.eq(0);
		expect(await bonusProxy.bonusPayable(userAddress2, 3)).to.be.eq(0);
		expect(await bonusProxy.totalBonus(1)).to.be.eq(0);

        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 4)).to.be.eq(0);
		expect(await bonusProxy.bonusPayable(userAddress2, 4)).to.be.eq(0);
		expect(await bonusProxy.totalBonus(2)).to.be.eq(0);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        expect(await bonusProxy.connect(otherTrader).actualizeUserPools()).to.be.ok;
		await minter.connect(otherTrader).transfer(bonusProxy.address, token(2000000));
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(3);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
		expect((await bonusProxy.userBonusSummary(userAddress2)).ethLockedPeriod).to.be.eq(3);
		expect((await bonusProxy.userBonusSummary(userAddress2)).ethLocked).to.be.gt(0);

        expect(await activityMeter.connect(otherTrader).withdraw(poolAddress, token(3))).to.be.ok;
		
        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 5)).to.be.gt(0);
		expect(await bonusProxy.bonusPayable(userAddress2, 5)).to.be.gt(0);
		expect(await bonusProxy.totalBonus(3)).to.be.gt((await bonusProxy.bonusPayable(userAddress, 5)).add(await bonusProxy.bonusPayable(userAddress2, 5)).sub(10));
		expect(await bonusProxy.totalBonus(3)).to.be.lt((await bonusProxy.bonusPayable(userAddress, 5)).add(await bonusProxy.bonusPayable(userAddress2, 5)).add(10));

        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        expect(await bonusProxy.connect(otherTrader).actualizeUserPools()).to.be.ok;
		await minter.connect(otherTrader).transfer(bonusProxy.address, token(2000000));
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(4);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
		expect((await bonusProxy.userBonusSummary(userAddress2)).ethLockedPeriod).to.be.eq(4);
		expect((await bonusProxy.userBonusSummary(userAddress2)).ethLocked).to.be.gt(0);

        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 6)).to.be.gt(0);
		expect(await bonusProxy.bonusPayable(userAddress2, 6)).to.be.gt(0);
		expect(await bonusProxy.totalBonus(4)).to.be.gt((await bonusProxy.bonusPayable(userAddress, 6)).add(await bonusProxy.bonusPayable(userAddress2, 6)).sub(10));
		expect(await bonusProxy.totalBonus(4)).to.be.lt((await bonusProxy.bonusPayable(userAddress, 6)).add(await bonusProxy.bonusPayable(userAddress2, 6)).add(10));

        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        expect(await bonusProxy.connect(otherTrader).actualizeUserPools()).to.be.ok;
		await minter.connect(otherTrader).transfer(bonusProxy.address, token(2000000));
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(5);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
		expect((await bonusProxy.userBonusSummary(userAddress2)).ethLockedPeriod).to.be.eq(5);
		expect((await bonusProxy.userBonusSummary(userAddress2)).ethLocked).to.be.gt(0);

        await wait(60);
		var lqfToBeMinted1 = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted1).to.be.gt(0);
		var lqfToBeMinted2 = await minter.userTokensToClaim(userAddress2);
		expect(lqfToBeMinted2).to.be.gt(0);

		expect(await bonusProxy.bonusPayable(userAddress, 7)).to.be.gt(lqfToBeMinted1.mul(3).div(8).sub(10));
		expect(await bonusProxy.bonusPayable(userAddress, 7)).to.be.lt(lqfToBeMinted1.mul(3).div(8).add(10));
		expect(await bonusProxy.bonusPayable(userAddress2, 7)).to.be.gt(lqfToBeMinted2.div(2).sub(10));
		expect(await bonusProxy.bonusPayable(userAddress2, 7)).to.be.lt(lqfToBeMinted2.div(2).add(10));
		expect(await bonusProxy.totalBonus(5)).to.be.gt(lqfToBeMinted1.mul(3).div(8).add(lqfToBeMinted2.div(2)).sub(10));
		expect(await bonusProxy.totalBonus(5)).to.be.lt(lqfToBeMinted1.mul(3).div(8).add(lqfToBeMinted2.div(2)).add(10));

		var lqfBalanceOld1 = await minter.balanceOf(userAddress);
		var lqfBalanceOld2 = await minter.balanceOf(userAddress2);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        expect(await bonusProxy.connect(otherTrader).actualizeUserPools()).to.be.ok;
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(6);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
		expect((await bonusProxy.userBonusSummary(userAddress2)).ethLockedPeriod).to.be.eq(6);
		expect((await bonusProxy.userBonusSummary(userAddress2)).ethLocked).to.be.gt(0);
		
		expect((await minter.balanceOf(userAddress)).sub(lqfBalanceOld1)).to.be.gt(lqfToBeMinted1.add(lqfToBeMinted1.mul(3).div(8)).sub(10));
		expect((await minter.balanceOf(userAddress)).sub(lqfBalanceOld1)).to.be.lt(lqfToBeMinted1.add(lqfToBeMinted1.mul(3).div(8)).add(10));
		expect((await minter.balanceOf(userAddress2)).sub(lqfBalanceOld2)).to.be.gt(lqfToBeMinted2.add(lqfToBeMinted2.div(2)).sub(10));
		expect((await minter.balanceOf(userAddress2)).sub(lqfBalanceOld2)).to.be.lt(lqfToBeMinted2.add(lqfToBeMinted2.div(2)).add(10));
	});

    it("should not transfer bonus when LQF pool removed", async function done() {
		this.timeout(100000);

        const factory = await LiquifiPoolFactoryFactory.connect(await register.factory(), factoryOwner);
        const { _timeZero, _miningPeriod }  = await governanceRouter.schedule();
        
        await addLiquidity(token(1), token(100)); // total supply = 10
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        const userAddress = await liquidityProvider.getAddress();
        const pool = await LiquifiDelayedExchangePoolFactory.connect(poolAddress, factoryOwner);  
        expect(await pool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await pool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(1))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(1);
        expect(await activityMeter.userPools(userAddress, 0)).to.be.eq(poolAddress);

        await wait(70);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        await wait(60);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		expect(await minter.balanceOf(userAddress)).to.be.eq(token(2500000));
		
        await addLQFLiquidity(token(1), token(100));
        const lqfPoolAddress = await factory.findPool(tokenA.address, minter.address);

        const lqfPool = await LiquifiDelayedExchangePoolFactory.connect(lqfPoolAddress, factoryOwner);  
        expect(await lqfPool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await lqfPool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(lqfPoolAddress, token(1))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(2);
        expect(await activityMeter.userPools(userAddress, 1)).to.be.eq(lqfPoolAddress);

        const bonusProxy = await deployContract(factoryOwner, LiquifiActivityMeterBonusProxyArtifact, [activityMeter.address, lqfPoolAddress, minter.address]) as 		
				LiquifiActivityMeterBonusProxy;

		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
		
		expect(await bonusProxy.bonusPayable(userAddress, 3)).to.be.eq(0);
		expect(await bonusProxy.totalBonus(1)).to.be.eq(0);

        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 4)).to.be.eq(0);
		expect(await bonusProxy.totalBonus(2)).to.be.eq(0);
		var lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(3);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
		
        expect(await activityMeter.connect(liquidityProvider).withdraw(lqfPoolAddress, token(1))).to.be.ok;
		
        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 5)).to.be.gt(0);
		expect(await bonusProxy.totalBonus(3)).to.be.eq(await bonusProxy.bonusPayable(userAddress, 5));
		lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(4);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);

        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 6)).to.be.gt(0);
		expect(await bonusProxy.totalBonus(4)).to.be.eq(await bonusProxy.bonusPayable(userAddress, 6));
		lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(5);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.eq(0);

        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 7)).to.be.eq(0);
		expect(await bonusProxy.totalBonus(5)).to.be.eq(0);
		lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);
		var lqfBalanceOld = await minter.balanceOf(userAddress);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(6);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.eq(0);
		
		expect((await minter.balanceOf(userAddress)).sub(lqfBalanceOld)).to.be.eq(lqfToBeMinted);
	});

    it("should not transfer bonus after max period", async function done() {
		this.timeout(100000);

        const factory = await LiquifiPoolFactoryFactory.connect(await register.factory(), factoryOwner);
        const { _timeZero, _miningPeriod }  = await governanceRouter.schedule();
        
        await addLiquidity(token(1), token(100)); // total supply = 10
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        const userAddress = await liquidityProvider.getAddress();
        const pool = await LiquifiDelayedExchangePoolFactory.connect(poolAddress, factoryOwner);  
        expect(await pool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await pool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(1))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(1);
        expect(await activityMeter.userPools(userAddress, 0)).to.be.eq(poolAddress);

        await wait(70);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        await wait(60);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		expect(await minter.balanceOf(userAddress)).to.be.eq(token(2500000));
		
        await addLQFLiquidity(token(1), token(100));
        const lqfPoolAddress = await factory.findPool(tokenA.address, minter.address);

        const lqfPool = await LiquifiDelayedExchangePoolFactory.connect(lqfPoolAddress, factoryOwner);  
        expect(await lqfPool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await lqfPool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(lqfPoolAddress, token(3))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(2);
        expect(await activityMeter.userPools(userAddress, 1)).to.be.eq(lqfPoolAddress);

        const bonusProxy = await deployContract(factoryOwner, LiquifiActivityMeterBonusProxyArtifact, [activityMeter.address, lqfPoolAddress, minter.address]) as 		
				LiquifiActivityMeterBonusProxy;

		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));

		expect(await bonusProxy.bonusPayable(userAddress, 3)).to.be.eq(0);
		expect(await bonusProxy.totalBonus(1)).to.be.eq(0);

        await wait(60);
		expect(await bonusProxy.bonusPayable(userAddress, 4)).to.be.eq(0);
		expect(await bonusProxy.totalBonus(2)).to.be.eq(0);
		var lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(3);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
		
        for(var i = 5; i <= 11; i++) {
			await wait(60);
			expect(await bonusProxy.bonusPayable(userAddress, i)).to.be.gt(0);
			expect(await bonusProxy.totalBonus(i - 2)).to.be.eq(await bonusProxy.bonusPayable(userAddress, i));
			lqfToBeMinted = await minter.userTokensToClaim(userAddress);
			expect(lqfToBeMinted).to.be.gt(0);
			var lqfBalanceOld = await minter.balanceOf(userAddress);
			expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
			await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
			
			expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(i - 1);
			expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
		}

        await wait(60);
		lqfToBeMinted = await minter.userTokensToClaim(userAddress);
		expect(lqfToBeMinted).to.be.gt(0);

		expect(await bonusProxy.bonusPayable(userAddress, 12)).to.be.eq(0);

		var lqfBalanceOld = await minter.balanceOf(userAddress);
        expect(await bonusProxy.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLockedPeriod).to.be.eq(11);
		expect((await bonusProxy.userBonusSummary(userAddress)).ethLocked).to.be.gt(0);
		
		expect((await minter.balanceOf(userAddress)).sub(lqfBalanceOld)).to.be.eq(lqfToBeMinted);
	});

    it("should withdraw by owner", async function done() {
		this.timeout(100000);

        const factory = await LiquifiPoolFactoryFactory.connect(await register.factory(), factoryOwner);
        const { _timeZero, _miningPeriod }  = await governanceRouter.schedule();
        
        await addLiquidity(token(1), token(100)); // total supply = 10
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        const userAddress = await liquidityProvider.getAddress();
        const pool = await LiquifiDelayedExchangePoolFactory.connect(poolAddress, factoryOwner);  
        expect(await pool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await pool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(1))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(1);
        expect(await activityMeter.userPools(userAddress, 0)).to.be.eq(poolAddress);

        await wait(70);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        await wait(60);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		expect(await minter.balanceOf(userAddress)).to.be.eq(token(2500000));
		
        await addLQFLiquidity(token(1), token(100));
        const lqfPoolAddress = await factory.findPool(tokenA.address, minter.address);

        const lqfPool = await LiquifiDelayedExchangePoolFactory.connect(lqfPoolAddress, factoryOwner);  
        expect(await lqfPool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await lqfPool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(lqfPoolAddress, token(3))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(2);
        expect(await activityMeter.userPools(userAddress, 1)).to.be.eq(lqfPoolAddress);

        const bonusProxy = await deployContract(factoryOwner, LiquifiActivityMeterBonusProxyArtifact, [activityMeter.address, lqfPoolAddress, minter.address]) as 		
				LiquifiActivityMeterBonusProxy;

		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
		
		expect(await bonusProxy.connect(factoryOwner).withdraw(await factoryOwner.getAddress(), token(2000000))).to.be.ok;
		expect(await minter.balanceOf(await factoryOwner.getAddress())).to.be.eq(token(2000000));
	});

    it("should not withdraw if not owner", async function done() {
		this.timeout(100000);

        const factory = await LiquifiPoolFactoryFactory.connect(await register.factory(), factoryOwner);
        const { _timeZero, _miningPeriod }  = await governanceRouter.schedule();
        
        await addLiquidity(token(1), token(100)); // total supply = 10
        const poolAddress = await factory.findPool(tokenA.address, tokenB.address);
        const userAddress = await liquidityProvider.getAddress();
        const pool = await LiquifiDelayedExchangePoolFactory.connect(poolAddress, factoryOwner);  
        expect(await pool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await pool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(poolAddress, token(1))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(1);
        expect(await activityMeter.userPools(userAddress, 0)).to.be.eq(poolAddress);

        await wait(70);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
        await wait(60);
        expect(await activityMeter.connect(liquidityProvider).actualizeUserPools()).to.be.ok;
		expect(await minter.balanceOf(userAddress)).to.be.eq(token(2500000));
		
        await addLQFLiquidity(token(1), token(100));
        const lqfPoolAddress = await factory.findPool(tokenA.address, minter.address);

        const lqfPool = await LiquifiDelayedExchangePoolFactory.connect(lqfPoolAddress, factoryOwner);  
        expect(await lqfPool.balanceOf(userAddress)).to.be.eq(token(10).sub(1000));

        await lqfPool.connect(liquidityProvider).approve(activityMeter.address, token(8));
        expect(await activityMeter.connect(liquidityProvider).deposit(lqfPoolAddress, token(3))).to.be.ok;

        expect(await activityMeter.userPoolsLength(userAddress)).to.be.eq(2);
        expect(await activityMeter.userPools(userAddress, 1)).to.be.eq(lqfPoolAddress);

        const bonusProxy = await deployContract(factoryOwner, LiquifiActivityMeterBonusProxyArtifact, [activityMeter.address, lqfPoolAddress, minter.address]) as 		
				LiquifiActivityMeterBonusProxy;

		await minter.connect(liquidityProvider).transfer(bonusProxy.address, token(2000000));
		
		await expect(bonusProxy.connect(liquidityProvider).withdraw(userAddress, token(2000000))).to.be.revertedWith("Only owner can do this");
	});

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

    async function addLQFLiquidity(amountA: BigNumber, amountB: BigNumber, _liquidityProvider: Wallet = liquidityProvider) {
        await tokenA.connect(_liquidityProvider).approve(register.address, amountA)
        await minter.connect(_liquidityProvider).approve(register.address, amountB);
        return await register.connect(_liquidityProvider).deposit(tokenA.address, amountA, minter.address, amountB, 
            await _liquidityProvider.getAddress(), 42949672960);
    }
})