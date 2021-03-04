import { LiquifiActivityReporter } from "../typechain/LiquifiActivityReporter";
import { LiquifiGovernanceRouter } from "../typechain/LiquifiGovernanceRouter";
import { LiquifiPoolFactory } from "../typechain/LiquifiPoolFactory";
import { LiquifiPoolRegister } from "../typechain/LiquifiPoolRegister";
import { TestWeth } from "../typechain/TestWeth";
import contracts from "./contracts.json"
import { Erc20Token } from "../typechain/Erc20Token";
import { LiquifiDelayedExchangePool } from "../typechain/LiquifiDelayedExchangePool";

export interface Liquifi {
    governanceRouter: LiquifiGovernanceRouter,
    poolFactory: LiquifiPoolFactory,
    activityReporter: LiquifiActivityReporter,
    poolRegister: LiquifiPoolRegister,
    weth: TestWeth
}

export const loadContracts = async (ethers: any): Promise<Liquifi> => ({
    governanceRouter: await ethers.getContractAt("LiquifiGovernanceRouter", contracts.governanceRouter) as LiquifiGovernanceRouter,
    poolFactory: await ethers.getContractAt("LiquifiPoolFactory", contracts.factory) as LiquifiPoolFactory,
    activityReporter: await ethers.getContractAt("LiquifiActivityReporter", contracts.activityReporter) as LiquifiActivityReporter,
    poolRegister: await ethers.getContractAt("LiquifiPoolRegister", contracts.register) as LiquifiPoolRegister,
    weth: await ethers.getContractAt("TestWeth", contracts.weth) as TestWeth
})

export const loadToken = async (ethers: any, tokenAddress: any): Promise<Erc20Token> =>
    await ethers.getContractAt("ERC20", tokenAddress) as Erc20Token

export const loadPool = async (ethers: any, tokenA: string, tokenB: string): Promise<LiquifiDelayedExchangePool> => {
    const poolFactory = await ethers.getContractAt("LiquifiPoolFactory", contracts.factory) as LiquifiPoolFactory
    return await ethers.getContractAt("LiquifiDelayedExchangePool", await poolFactory.findPool(tokenA, tokenB)) as LiquifiDelayedExchangePool
}
