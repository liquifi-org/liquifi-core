import chai from "chai";

import { ethers } from "hardhat";
import { deployContract, solidity } from "ethereum-waffle";
import { Signer } from "ethers"
import { token } from "./util/TokenUtil"

import LiquifiPoolFactoryArtifact from "../artifacts/contracts/LiquifiPoolFactory.sol/LiquifiPoolFactory.json";
import TestTokenArtifact from "../artifacts/contracts/test/TestToken.sol/TestToken.json";
import LiquifiGovernanceRouterArtifact from "../artifacts/contracts/LiquifiGovernanceRouter.sol/LiquifiGovernanceRouter.json";

import { TestToken } from "../typechain/TestToken"
import { LiquifiPoolFactory } from "../typechain/LiquifiPoolFactory"
import { LiquifiGovernanceRouter } from "../typechain/LiquifiGovernanceRouter"

chai.use(solidity);
const { expect } = chai;

describe("Liquifi Pool Factory", () => {

    var liquidityProvider: Signer;
    var factoryOwner: Signer;

    var tokenA: TestToken;
    var tokenB: TestToken;
    var tokenC: TestToken;

    var factory: LiquifiPoolFactory;

    beforeEach(async () => {
        let fakeWeth;
        [liquidityProvider, factoryOwner, fakeWeth] = await ethers.getSigners();

        tokenA = await deployContract(liquidityProvider, TestTokenArtifact, [token(1000), "Token A", "TKA", []]) as TestToken
        tokenB = await deployContract(liquidityProvider, TestTokenArtifact, [token(1000), "Token B", "TKB", []]) as TestToken
        tokenC = await deployContract(liquidityProvider, TestTokenArtifact, [token(1000), "Token C", "TKC", []]) as TestToken
        const governanceRouter = await deployContract(factoryOwner, LiquifiGovernanceRouterArtifact, [3600, await fakeWeth.getAddress()]) as LiquifiGovernanceRouter;
        factory = await deployContract(factoryOwner, LiquifiPoolFactoryArtifact, [governanceRouter.address], { gasLimit: 9500000 }) as LiquifiPoolFactory
    })

    it("should deploy all contracts", async () => {
        expect(tokenA.address).to.be.properAddress
        expect(tokenB.address).to.be.properAddress
        expect(factory.address).to.be.properAddress
    })

    it("should create a new pool", async () => {
        expect(await factory.getPoolCount()).to.be.eq(0)
        await factory.getPool(tokenA.address, tokenB.address)
        expect(await factory.getPoolCount()).to.be.eq(1)
    })

    it("should not create the same pool twice", async () => {
        await factory.getPool(tokenA.address, tokenB.address)
        expect(await factory.getPoolCount()).to.be.eq(1)

        await factory.getPool(tokenA.address, tokenC.address)
        expect(await factory.getPoolCount()).to.be.eq(2)
        

        await factory.getPool(tokenB.address, tokenA.address);
        expect(await factory.getPoolCount()).to.be.eq(2)

        await factory.getPool(tokenA.address, tokenC.address)
        expect(await factory.getPoolCount()).to.be.eq(2)
    })
})