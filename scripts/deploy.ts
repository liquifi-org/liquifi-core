import { ethers, network } from "hardhat";
import { wethAddress } from "./weth";
import { BigNumber } from "ethers";
import fs from 'fs';
import { LiquifiActivityReporterFactory } from "../typechain";
import contracts from "./contracts.json"
import { storeAddresses } from "./addresses";

const l2Messenger = "0x6418E5Da52A3d7543d393ADD3Fa98B0795d27736"

var ADDR = {
  'governanceRouter': '',
  'activityReporter': '',
  'governor': '',
  'register': '',
  'factory': ''
}

async function deployGovernanceRouter(wethAddress: string) {
    const LiquifiGovernanceRouter = await ethers.getContractFactory("LiquifiGovernanceRouter");
    //var options = { gasLimit: 7000000 };
    const miningPeriod = 7*24*60*60; // 1 week
    //const miningPeriod = 15*60; // 15 minutes
    const liquifiGovernanceRouter = await LiquifiGovernanceRouter.deploy(miningPeriod, wethAddress);
    await liquifiGovernanceRouter.deployed();
    console.log("LiquiFi Governance Router address:", liquifiGovernanceRouter.address);
    ADDR['governanceRouter']  = liquifiGovernanceRouter.address
    return liquifiGovernanceRouter.address
}

async function deployActivityReporter(governanceRouterAddress: string) {
    const LiquifiActivityReporter = await ethers.getContractFactory("LiquifiActivityReporter") as LiquifiActivityReporterFactory;
    const liquifiActivityReporter = await LiquifiActivityReporter.deploy(governanceRouterAddress, contracts.activityMeter);
    await liquifiActivityReporter.deployed();
    console.log("LiquiFi Activity Reporter address:", liquifiActivityReporter.address);
    ADDR['activityReporter'] = liquifiActivityReporter.address
    return liquifiActivityReporter.address
}

async function deployGovernor(governanceRouterAddress: string) {
    const LiquifiInitialGovernor = await ethers.getContractFactory("LiquifiInitialGovernor");
    //var options = { gasLimit: 7000000 };
    const tokensRequiredToCreateProposal = BigNumber.from(10).pow(18).mul(20000); // 20 000 tokens
    const votingPeriod = 48; // hours
    const liquifiInitialGovernor = await LiquifiInitialGovernor.deploy(governanceRouterAddress, tokensRequiredToCreateProposal, votingPeriod);
    await liquifiInitialGovernor.deployed();
    console.log("LiquiFi Governor address:", liquifiInitialGovernor.address);
    ADDR['governor'] = liquifiInitialGovernor.address
    return liquifiInitialGovernor.address
}

async function deployFactory(governanceRouterAddress: string) {
    const LiquifiPoolFactory = await ethers.getContractFactory("LiquifiPoolFactory");
    //var options = { gasLimit: 7000000 };
    const liquifiPoolFactory = await LiquifiPoolFactory.deploy(governanceRouterAddress);
    await liquifiPoolFactory.deployed();
    console.log("LiquiFi Pool Factory address:", liquifiPoolFactory.address);
    ADDR['factory'] = liquifiPoolFactory.address
    return liquifiPoolFactory.address
}

async function deployRegister(governanceRouterAddress: string) {
    const LiquifiPoolRegister = await ethers.getContractFactory("LiquifiPoolRegister");
    const liquifiPoolRegister = await LiquifiPoolRegister.deploy(governanceRouterAddress);
    await liquifiPoolRegister.deployed();
    console.log("LiquiFi Pool Register address:", liquifiPoolRegister.address);
    ADDR['register'] = liquifiPoolRegister.address
    return liquifiPoolRegister.address
}


async function main() {
    const governanceRouter = await deployGovernanceRouter(wethAddress[network.name]);
    await deployActivityReporter(governanceRouter);
    await deployFactory(governanceRouter);
    await deployGovernor(governanceRouter);
    await deployRegister(governanceRouter);
    try {
      fs.writeFileSync('contract-addresses.json', JSON.stringify(ADDR))
      storeAddresses(ADDR)
    } catch {
      console.log('Failed to create addresses file')
    }
}

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
