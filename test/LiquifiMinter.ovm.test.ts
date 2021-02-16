import chai from "chai";

import { l2ethers as ethers } from "hardhat";
import { deployContract, solidity } from "ethereum-waffle";
import { Signer } from "ethers"
import { token } from "./util/TokenUtil";

import TestTokenArtifact from "../artifacts/contracts/test/TestToken.sol/TestToken.ovm.json";
import LiquifiGovernanceRouterArtifact from "../artifacts/contracts/LiquifiGovernanceRouter.sol/LiquifiGovernanceRouter.ovm.json";
import LiquifiActivityMeterArtifact from "../artifacts/contracts/LiquifiActivityMeter.sol/LiquifiActivityMeter.ovm.json";
import LiquifiMinterArtifact from "../artifacts/contracts/LiquifiMinter.sol/LiquifiMinter.ovm.json";
import LiquifiPoolRegisterArtifact from "../artifacts/contracts/LiquifiPoolRegister.sol/LiquifiPoolRegister.ovm.json";

import { TestToken } from "../typechain/TestToken"
import { LiquifiActivityMeter } from "../typechain/LiquifiActivityMeter"
import { LiquifiMinter } from "../typechain/LiquifiMinter"
import { LiquifiGovernanceRouter } from "../typechain/LiquifiGovernanceRouter"
import { LiquifiPoolRegister } from "../typechain/LiquifiPoolRegister";

chai.use(solidity);
const { expect } = chai;

describe("OPTIMISM Liquifi Minter", () => {

    var liquidityProvider: Signer;
    var factoryOwner: Signer;
    var otherTrader: Signer;

    var tokenA: TestToken;
    var tokenB: TestToken;

    var activityMeter: LiquifiActivityMeter;
    var minter: LiquifiMinter;
    var register: LiquifiPoolRegister;
    var governanceRouter: LiquifiGovernanceRouter;

    beforeEach(async () => {
        [liquidityProvider, factoryOwner, otherTrader] = await ethers.getSigners();
        
        tokenA = await deployContract(liquidityProvider, TestTokenArtifact, [token(1000), "Token A", "TKA", [await otherTrader.getAddress()]]) as TestToken
        tokenB = await deployContract(liquidityProvider, TestTokenArtifact, [token(1000), "Token B", "TKB", [await otherTrader.getAddress()]]) as TestToken
        governanceRouter = await deployContract(factoryOwner, LiquifiGovernanceRouterArtifact, [60, tokenA.address]) as LiquifiGovernanceRouter;
        activityMeter = await deployContract(factoryOwner, LiquifiActivityMeterArtifact, [governanceRouter.address]) as LiquifiActivityMeter;
        minter = await deployContract(factoryOwner, LiquifiMinterArtifact, [governanceRouter.address]) as LiquifiMinter;
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
        for(let i = 1; i < 50; i++) {
            const computed = await minter.periodTokens(i);
            const diff = computed.gt(tokens) ? computed.sub(tokens) : tokens.sub(computed);
            expect(diff).to.be.lt(32);
            tokens = tokens.mul(periodDecayK).shr(8);
        }
    });
})