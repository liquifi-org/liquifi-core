import { BigNumber, Signer } from "ethers"
import { LiquifiActivityReporter } from "../typechain/LiquifiActivityReporter"
import { LiquifiGovernanceRouter } from "../typechain/LiquifiGovernanceRouter"
import { LiquifiPoolFactory } from "../typechain/LiquifiPoolFactory"
import { LiquifiPoolRegister } from "../typechain/LiquifiPoolRegister"
import { TestMessenger } from "../typechain/TestMessenger"
import { TestToken } from "../typechain/TestToken"
import { TestWeth } from "../typechain/TestWeth"

import { ZERO_ADDRESS } from "./setup"
import { token } from "./util/TokenUtil"

export interface Liquifi {
    governanceRouter: LiquifiGovernanceRouter,
    poolFactory: LiquifiPoolFactory,
    messenger: TestMessenger,
    activityReporter: LiquifiActivityReporter,
    poolRegister: LiquifiPoolRegister,
    weth: TestWeth
}

export const deployLiquifi = async (ethers: any): Promise<Liquifi> => {
    const weth = await (await ethers.getContractFactory("TestWeth"))
        .deploy() as TestWeth;
    const governanceRouter = await (await ethers.getContractFactory("LiquifiGovernanceRouter"))
        .deploy(3600, weth.address) as LiquifiGovernanceRouter
    const poolFactory = await (await ethers.getContractFactory("LiquifiPoolFactory"))
        .deploy(governanceRouter.address, { gasLimit: 9500000 }) as LiquifiPoolFactory
    const messenger = await (await ethers.getContractFactory("TestMessenger"))
        .deploy() as TestMessenger
    const activityReporter = await (await ethers.getContractFactory("LiquifiActivityReporter"))
        .deploy(messenger.address, governanceRouter.address, ZERO_ADDRESS) as LiquifiActivityReporter
    const poolRegister = await (await ethers.getContractFactory("LiquifiPoolRegister"))
        .deploy(governanceRouter.address) as LiquifiPoolRegister

    return {
        governanceRouter,
        poolFactory,
        messenger,
        activityReporter,
        poolRegister,
        weth
    }
}

export const deployToken = async (ethers: any, owners: any[], name: string, supply: BigNumber = token(1000000)) => {
    return await (await ethers.getContractFactory("TestToken"))
        .deploy(supply, "Token " + name, name, owners) as TestToken
}