import chai from "chai";

import { ethers } from "hardhat";
import { deployContract, solidity } from "ethereum-waffle";
import { Signer } from "ethers"
import { token } from "./util/TokenUtil"

import TestLiquidityPoolArtifact from "../artifacts/contracts/test/TestLiquidityPool.sol/TestLiquidityPool.json";

import TestTokenArtifact from "../artifacts/contracts/test/TestToken.sol/TestToken.json";
import LiquifiGovernanceRouterArtifact from "../artifacts/contracts/LiquifiGovernanceRouter.sol/LiquifiGovernanceRouter.json";

import { TestToken } from "../typechain/TestToken"
import { TestLiquidityPool } from "../typechain/TestLiquidityPool";
import { LiquifiGovernanceRouter } from "../typechain/LiquifiGovernanceRouter"

chai.use(solidity);
const { expect } = chai;



const initialTokenA = 1000;
const initialTokenB = 8000000000000;


describe("Liquifi Liquidity Pool", () => {

    var liquidityProvider: Signer;
    var factoryOwner: Signer;

    var tokenA: TestToken;
    var tokenB: TestToken;

    var pool: TestLiquidityPool;

    beforeEach(async () => {
        let fakeWeth;
        [liquidityProvider, factoryOwner, fakeWeth] = await ethers.getSigners();
        tokenA = await deployContract(liquidityProvider, TestTokenArtifact, [token(initialTokenA), "Token A", "TKA", []]) as TestToken
        tokenB = await deployContract(liquidityProvider, TestTokenArtifact, [token(initialTokenB), "Token B", "TKB", []]) as TestToken
        const governanceRouter = await deployContract(factoryOwner, LiquifiGovernanceRouterArtifact, [3600, await fakeWeth.getAddress()]) as LiquifiGovernanceRouter;
        pool = await deployContract(factoryOwner, TestLiquidityPoolArtifact, [tokenA.address, tokenB.address, governanceRouter.address]) as TestLiquidityPool
    })

    it("should deploy all contracts", async () => {
        expect(tokenA.address).to.be.properAddress
        expect(tokenB.address).to.be.properAddress
        expect(pool.address).to.be.properAddress
    })

    it("should mint liquidity tokens", async () => {
        await addLiquidity(100, 100);
        expect(await pool.balanceOf(await liquidityProvider.getAddress())).to.be.eq(token(100).sub(1000))
    })

    it("should give minimul liquidity", async () => {
        await addLiquidity(36, 64);
        expect(await pool.balanceOf(await liquidityProvider.getAddress())).to.be.eq(token(48).sub(1000))
        await addLiquidity(100, 100);
        //expect(await pool.balanceOf(await liquidityProvider.getAddress())).to.be.eq(token(123))
    })

    it("should burn liquidity tokens", async () => {
        await addLiquidity(100, 100)

        const provider = await liquidityProvider.getAddress()
        expect(await pool.balanceOf(provider)).to.be.eq(token(100).sub(1000))

        await pool.connect(liquidityProvider).transfer(pool.address, token(100).sub(1000))
        await pool.burn(provider, false)

        expect(await tokenA.balanceOf(provider)).to.be.eq(token(initialTokenA).sub(1000))
        expect(await tokenB.balanceOf(provider)).to.be.eq(token(initialTokenB).sub(1000))
        expect(await pool.balanceOf(provider)).to.be.eq(0)
    })

    it("should swap tokens A -> B", async () => {
        const mintedA = 100;
        const mintedB = 30;
        await addLiquidity(mintedA, mintedB);
        
        const amountIn = token(10);
        const amountInWithFee = amountIn.mul(997);
        const numerator = amountInWithFee.mul(token(mintedB));
        const denominator = token(mintedA).mul(1000).add(amountInWithFee);
        const amountOut = numerator.div(denominator);

        const provider = await liquidityProvider.getAddress();
        await tokenA.transfer(pool.address, amountIn);
        

        expect(await pool.swap(provider, false, token(0), amountOut, [])).is.ok
        expect(await tokenA.balanceOf(provider)).to.be.eq(token(initialTokenA).sub(token(mintedA)).sub(amountIn))
        expect(await tokenB.balanceOf(provider)).to.be.eq(token(initialTokenB).sub(token(mintedB)).add(amountOut))
    })

    it("should not swap tokens A -> B with wrong rate", async () => {
        const mintedA = 100;
        const mintedB = 30;
        await addLiquidity(mintedA, mintedB);
        
        const amountIn = token(10);
        const amountInWithFee = amountIn.mul(997);
        const numerator = amountInWithFee.mul(token(mintedB));
        const denominator = token(mintedA).mul(1000).add(amountInWithFee);
        const amountOut = numerator.div(denominator).add(1);

        const provider = await liquidityProvider.getAddress();
        await tokenA.transfer(pool.address, amountIn);

        await expect(pool.swap(provider, false, token(0), amountOut, [])).to.be.revertedWith("FAIL https://err.liquifi.org/JF");
    })

    it("should fail on zero amount", async () => {
        const mintedA = 80;
        const mintedB = 850;
        await addLiquidity(mintedA, mintedB);
        
        const provider = await liquidityProvider.getAddress();
        await expect(pool.swap(provider, false, token(2), token(1), [])).to.be.revertedWith("FAIL https://err.liquifi.org/FB");
    })

    it("should swap tokens B -> A", async () => {
        const mintedA = 80;
        const mintedB = 850;
        await addLiquidity(mintedA, mintedB);
        
        const amountIn = token(765354565548);
        const amountInWithFee = amountIn.mul(997);
        const numerator = amountInWithFee.mul(token(mintedA));
        const denominator = token(mintedB).mul(1000).add(amountInWithFee);
        const amountOut = numerator.div(denominator);

        const provider = await liquidityProvider.getAddress();
        await tokenB.transfer(pool.address, amountIn);
        
        expect(await pool.swap(provider, false, amountOut, token(0), [])).is.ok
        expect(await tokenA.balanceOf(provider)).to.be.eq(token(initialTokenA).sub(token(mintedA)).add(amountOut))
        expect(await tokenB.balanceOf(provider)).to.be.eq(token(initialTokenB).sub(token(mintedB)).sub(amountIn))
    })

    const addLiquidity = async (amountA: number, amountB: number) => {
        await tokenA.transfer(pool.address, token(amountA));
        await tokenB.transfer(pool.address, token(amountB));
        await pool.mint(await liquidityProvider.getAddress());
    }
})