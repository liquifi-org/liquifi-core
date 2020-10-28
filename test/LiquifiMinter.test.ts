import chai from "chai";

import { ethers } from "@nomiclabs/buidler";
import { deployContract, solidity } from "ethereum-waffle";
import { Wallet, BigNumber } from "ethers"
import { token } from "./util/TokenUtil";

import LiquifiDelayedExchangePoolArtifact from "../artifacts/LiquifiDelayedExchangePool.json";
import TestTokenArtifact from "../artifacts/TestToken.json";
import TestMinterArtifact from "../artifacts/TestMinter.json";
import LiquifiGovernanceRouterArtifact from "../artifacts/LiquifiGovernanceRouter.json";
import LiquifiActivityMeterArtifact from "../artifacts/LiquifiActivityMeter.json";
import LiquifiMinterArtifact from "../artifacts/LiquifiMinter.json";
import LiquifiPoolRegisterArtifact from "../artifacts/LiquifiPoolRegister.json";
import LiquifiPoolFactoryArtifact from "../artifacts/LiquifiPoolFactory.json";
import LiquifiPoolFactory from "../artifacts/LiquifiPoolFactory.json";

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

describe("Liquifi Minter", () => {

    var liquidityProvider: Wallet;
    var factoryOwner: Wallet;
    var otherTrader: Wallet;

    var tokenA: TestToken;
    var tokenB: TestToken;

    var activityMeter: LiquifiActivityMeter;
    var minter: LiquifiMinter;
    var register: LiquifiPoolRegister;
    var governanceRouter: LiquifiGovernanceRouter;

    beforeEach(async () => {
        [liquidityProvider, factoryOwner, otherTrader] = await ethers.getSigners() as Wallet[];
        
        tokenA = await deployContract(liquidityProvider, TestTokenArtifact, [token(1000), "Token A", "TKA", [await otherTrader.getAddress()]]) as TestToken
        tokenB = await deployContract(liquidityProvider, TestTokenArtifact, [token(1000), "Token B", "TKB", [await otherTrader.getAddress()]]) as TestToken
        governanceRouter = await deployContract(factoryOwner, LiquifiGovernanceRouterArtifact, [60, tokenA.address]) as LiquifiGovernanceRouter;
        activityMeter = await deployContract(factoryOwner, LiquifiActivityMeterArtifact, [governanceRouter.address]) as LiquifiActivityMeter;
        minter = await deployContract(factoryOwner, LiquifiMinterArtifact, [governanceRouter.address]) as LiquifiMinter;
        await deployContract(factoryOwner, LiquifiPoolFactoryArtifact, [governanceRouter.address], { gasLimit: 9500000 });
        register = await deployContract(factoryOwner, LiquifiPoolRegisterArtifact, [governanceRouter.address]) as LiquifiPoolRegister
    })

    it("should deploy all contracts", async () => {
        expect(tokenA.address).to.be.properAddress;
        expect(tokenB.address).to.be.properAddress;
        expect(activityMeter.address).to.be.properAddress;
        expect(minter.address).to.be.properAddress;
    })

    it("should compute precise decay", async () => {
        const initialPeriodTokens = await minter.initialPeriodTokens();
        const periodDecayK = await minter.periodDecayK();
        expect(await minter.periodTokens(1)).to.be.eq(initialPeriodTokens);
        expect(await minter.periodTokens(2)).to.be.eq(initialPeriodTokens.mul(periodDecayK).shr(8));
        expect(await minter.periodTokens(3)).to.be.eq(initialPeriodTokens.mul(periodDecayK).mul(periodDecayK).shr(16));
        let tokens = initialPeriodTokens;
        for(let i = 1; i < 1000; i++) {
            const computed = await minter.periodTokens(i);
            const diff = computed.gt(tokens) ? computed.sub(tokens) : tokens.sub(computed);
            expect(diff).to.be.lt(32);
            tokens = tokens.mul(periodDecayK).shr(8);
        }
    });

    const wait = async (seconds: number) => {
        await ethers.provider.send("evm_increaseTime", [seconds - 1]);   
        await ethers.provider.send("evm_mine", []); // mine the next block
    }

    async function addLiquidity(amountA: BigNumber, amountB: BigNumber, _liquidityProvider: Wallet = liquidityProvider) {
        await tokenA.connect(_liquidityProvider).approve(register.address, amountA)
        await tokenB.connect(_liquidityProvider).approve(register.address, amountB);
        await register.connect(_liquidityProvider).deposit(tokenA.address, amountA, tokenB.address, amountB, 
            await _liquidityProvider.getAddress(), 42949672960);
    }
})