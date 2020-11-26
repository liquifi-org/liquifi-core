import { ethers, network } from "@nomiclabs/buidler";
import { wethAddress } from "./weth";
import { BigNumber } from "ethers";
import fs from 'fs';

var ADDR = {
  'governanceRouter': '',
  'activityMeter': '',
  'minter': '',
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

async function deployActivityMeter(governanceRouterAddress: string) {
    const LiquifiActivityMeter = await ethers.getContractFactory("LiquifiActivityMeter");
    //var options = { gasLimit: 7000000 };
    const liquifiActivityMeter = await LiquifiActivityMeter.deploy(governanceRouterAddress);
    await liquifiActivityMeter.deployed();
    console.log("LiquiFi Activity Meter address:", liquifiActivityMeter.address);
    ADDR['activityMeter'] = liquifiActivityMeter.address
    return liquifiActivityMeter.address
}

async function deployMinter(governanceRouterAddress: string) {
    const LiquifiMinter = await ethers.getContractFactory("LiquifiMinter");
    //var options = { gasLimit: 7000000 };
    const liquifiMinter = await LiquifiMinter.deploy(governanceRouterAddress);
    await liquifiMinter.deployed();
    console.log("LiquiFi Minter address:", liquifiMinter.address);
    ADDR['minter'] = liquifiMinter.address
    return liquifiMinter.address
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
    await deployActivityMeter(governanceRouter);
    await deployMinter(governanceRouter);
    await deployFactory(governanceRouter);
    await deployGovernor(governanceRouter);
    await deployRegister(governanceRouter);
    try {
      fs.writeFileSync('contract-addresses.json', JSON.stringify(ADDR))
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
