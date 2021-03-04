import { ethers } from "hardhat"
import { expect } from "./setup"
import { Signer } from "ethers"
import { token } from "./util/TokenUtil"
import { deployLiquifi, deployToken, Liquifi } from "./Liquifi.deploy"
import { TestToken } from "../typechain/TestToken"


const timeout = 429496729600

describe("Activity Reporter", async () => {
    let liquifi: Liquifi
    let tokenA: TestToken
    let tokenB: TestToken
    let traderA: Signer

    beforeEach(async () => {
        [traderA] = await ethers.getSigners()
        const traders = [await traderA.getAddress()]
        liquifi = await deployLiquifi(ethers)
        tokenA = await deployToken(ethers, traders, "TKA", token(1000))
        tokenB = await deployToken(ethers, traders, "TKB", token(1000))
    })

    it("Should configure test environment", async () => {
        expect(liquifi.messenger.address).to.be.properAddress
        expect(liquifi.activityReporter.address).to.be.properAddress
        expect(liquifi.poolRegister.address).to.be.properAddress
        expect(await tokenA.balanceOf(await traderA.getAddress())).to.equal(token(1000))
        expect(await tokenB.balanceOf(await traderA.getAddress())).to.equal(token(1000))
    })

    it("Should report pool price change on contract creation", async () => {
        await tokenA.connect(traderA).approve(liquifi.poolRegister.address, token(1000))
        const initialDepositTx = liquifi.poolRegister.connect(traderA)
            .depositWithETH(tokenA.address, token(100), await traderA.getAddress(), timeout, { value: token(1) })
        await expect(initialDepositTx).to.emit(liquifi.activityReporter, "LiquidityETHPriceChanged")

        const pool = await liquifi.poolFactory.findPool(tokenA.address, liquifi.weth.address)
        expect(pool).to.be.properAddress

        const depositTx = liquifi.poolRegister.connect(traderA)
            .depositWithETH(tokenA.address, token(100), await traderA.getAddress(), timeout, { value: token(1) })
        await expect(depositTx).to.emit(liquifi.activityReporter, "LiquidityETHPriceChanged").withArgs(pool)
    })
})