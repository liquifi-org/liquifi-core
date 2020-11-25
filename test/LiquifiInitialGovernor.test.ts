import { ethers } from "@nomiclabs/buidler";
import { Wallet } from "ethers";
import chai from "chai";
import { deployContract, solidity } from "ethereum-waffle";

chai.use(solidity);
const { expect } = chai;

import { LiquifiInitialGovernor } from "../typechain/LiquifiInitialGovernor";
import LiquifiInitialGovernorArtifact from "../artifacts/LiquifiInitialGovernor.json";

import { TestMinter } from "../typechain/TestMinter";
import TestMinterArtifact from "../artifacts/TestMinter.json";

import { LiquifiGovernanceRouter } from "../typechain/LiquifiGovernanceRouter";
import LiquifiGovernanceRouterArtifact from "../artifacts/LiquifiGovernanceRouter.json";

import { LiquifiProposal } from "../typechain/LiquifiProposal";
import { LiquifiProposalFactory } from "../typechain/LiquifiProposalFactory";

import { AddressZero } from "@ethersproject/constants";
import { token } from "./util/TokenUtil";

describe("Liquifi Initial Governor", () => {
    var governor: LiquifiInitialGovernor;
    var newGovernor: LiquifiInitialGovernor;
    var governanceToken: TestMinter;
    var governanceRouter: LiquifiGovernanceRouter;
    var governanceTokenOwner: Wallet;
    var governorOwner: Wallet;
    var weth: Wallet;
    var voter: Wallet;

    beforeEach(async () => {
        [governanceTokenOwner, governorOwner, weth, voter] = await ethers.getSigners() as Wallet[];
        governanceRouter = await deployContract(governanceTokenOwner, LiquifiGovernanceRouterArtifact, [3600, await weth.getAddress()]) as LiquifiGovernanceRouter
        governanceToken = await deployContract(governanceTokenOwner, TestMinterArtifact, [governanceRouter.address, token(250), []]) as TestMinter;
        governor = await deployContract(governanceTokenOwner, LiquifiInitialGovernorArtifact, [governanceRouter.address, token(100), 48]) as LiquifiInitialGovernor;
        newGovernor = await deployContract(governanceTokenOwner, LiquifiInitialGovernorArtifact, [governanceRouter.address, token(100), 48]) as LiquifiInitialGovernor;
    })

    it("Should deploy contracts", async () => {
        expect(governanceToken.address).to.properAddress;
        expect(governanceRouter.address).to.properAddress;
        expect(governor.address).to.properAddress;
    });

    it("Should have default values", async () => {
        expect(await governor.tokensRequiredToCreateProposal()).to.equal(token(100));
    });

    it("Should create proposal and take balance", async () => {
        await governanceToken.connect(governanceTokenOwner).transfer(await governorOwner.getAddress(), token(100));
        await governanceToken.connect(governorOwner).approve(governor.address, token(100));

        expect((await governor.getDeployedProposals()).length).to.equal(0);
        expect(await governanceToken.connect(governorOwner).balanceOf(await governorOwner.getAddress())).to.be.equal(token(100));

        expect(await governor.connect(governorOwner).createProposal("test", 2, 1, AddressZero, AddressZero)).to.be.ok;
        expect(await governanceToken.connect(governorOwner).balanceOf(await governorOwner.getAddress())).to.be.equal(token(0));
        expect((await governor.getDeployedProposals()).length).to.equal(1);
    })

    it("Should change governor", async () => {
        // Assign a governor
        expect((await governanceRouter.governance())[0]).to.eq(governor.address);

        // Create a proposal to change governor
        await governanceToken.connect(governanceTokenOwner).transfer(await governorOwner.getAddress(), token(100));
        await governanceToken.connect(governorOwner).approve(governor.address, token(100));
        expect((await governor.getDeployedProposals()).length).to.equal(0);
        expect(await governanceToken.connect(governorOwner).balanceOf(await governorOwner.getAddress())).to.be.equal(token(100));
        expect(await governor.connect(governorOwner).createProposal("test", 1, 0, newGovernor.address, AddressZero)).to.be.ok;

        // Vote for the proposal
        const proposal = LiquifiProposalFactory.connect((await governor.getDeployedProposals())[0], governorOwner) as LiquifiProposal;
        await governanceToken.connect(governanceTokenOwner).transfer(await voter.getAddress(), token(150));
        await governanceToken.connect(voter).approve(governor.address, token(150));
        await proposal.connect(voter)["vote(uint8)"](1);
        await proposal.connect(governorOwner)["vote(uint8,uint256)"](3, token(100));
        expect(await proposal.approvalsInfluence()).to.equal(token(150));
        expect(await governanceToken.balanceOf(await voter.getAddress())).to.be.eq(token(0));

        await expect(governor.connect(voter).withdraw()).to.be.revertedWith("LIQUIFI_GV: WITHDRAW FAILED");
        
        // Finalize the proposal
        await wait(60*60*24*3); //3 days
        await proposal.finalize()
        expect(await proposal.result()).to.equal(1);
        expect(await governanceToken.balanceOf(await voter.getAddress())).to.be.eq(token(150));

        // Check the new governor
        expect((await governanceRouter.governance())[0]).to.eq(newGovernor.address);
    })
})

const wait = async (seconds: number) => {
    await ethers.provider.send("evm_increaseTime", [seconds - 1]);   
    await ethers.provider.send("evm_mine", []); // mine the next block
}