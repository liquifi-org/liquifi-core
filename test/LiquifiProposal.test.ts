import { ethers } from "@nomiclabs/buidler";
import { Wallet, BigNumber } from "ethers";
import chai from "chai";
import { deployContract, solidity } from "ethereum-waffle";



chai.use(solidity);
const { expect } = chai;

import { LiquifiProposal } from "../typechain/LiquifiProposal";
import { LiquifiProposalFactory } from "../typechain/LiquifiProposalFactory";

import { LiquifiInitialGovernor } from "../typechain/LiquifiInitialGovernor";
import LiquifiInitialGovernorArtifact from "../artifacts/LiquifiInitialGovernor.json";

import { LiquifiGovernanceRouter } from "../typechain/LiquifiGovernanceRouter";
import LiquifiGovernanceRouterArtifact from "../artifacts/LiquifiGovernanceRouter.json";

const token = (value: Number) => BigNumber.from(value).mul(BigNumber.from(10).pow(18))

async function skipTime(seconds: number) {
    await ethers.provider.send("evm_increaseTime", [seconds]);
    await ethers.provider.send("evm_mine", []);      // mine the next block
}

import { TestMinter } from "../typechain/TestMinter";
import TestMinterArtifact from "../artifacts/TestMinter.json";

import { AddressZero } from "@ethersproject/constants";

describe("Proposals", () => {
    var proposal: LiquifiProposal;
    var govToken: TestMinter;
    var signers: Wallet[];
    var gov: LiquifiInitialGovernor;

    beforeEach(async () => {
        signers = await ethers.getSigners() as Wallet[];
        const governanceRouter = await deployContract(signers[0], LiquifiGovernanceRouterArtifact, [3600, AddressZero]) as LiquifiGovernanceRouter
        govToken = await deployContract(signers[0], TestMinterArtifact, [governanceRouter.address, token(300), []]) as TestMinter;
        gov = await deployContract(signers[0], LiquifiInitialGovernorArtifact, [governanceRouter.address, token(100), 48]) as LiquifiInitialGovernor;
    })

    it("Should deploy all contracts", async() => {
        expect(govToken.address).to.properAddress;
        expect(gov.address).to.properAddress;
    })

    it("Voting 2 people", async () => {
        // await expect(await proposal.connect(signers[0]).vote("yes", 1)).to.be.reverted;
        await govToken.connect(signers[0]).transfer(await signers[1].getAddress(), token(50));
        await govToken.connect(signers[0]).transfer(await signers[2].getAddress(), token(100));
        await govToken.connect(signers[0]).approve(gov.address, token(100));
        await govToken.connect(signers[1]).approve(gov.address, token(50));
        await govToken.connect(signers[2]).approve(gov.address, token(100));

        //creating proposal
        await expect(await gov.connect(signers[0]).createProposal("test", 1, 1, AddressZero, AddressZero)).to.be.ok;
        expect((await gov.getDeployedProposals()).length).to.be.equal(1);
        let prop = (await gov.getDeployedProposals())[0];
        proposal = LiquifiProposalFactory.connect(prop, signers[5]);

        await proposal.connect(signers[1])["vote(uint8)"](2);
        await proposal.connect(signers[2])["vote(uint8)"](1);
        expect(await proposal.approvalsInfluence()).to.equal(token(100));
        expect(await proposal.againstInfluence()).to.equal(token(50));

        skipTime(60 * 60 * 24 * 3); //3 days

        await proposal.finalize()

        expect(await proposal.approvalsInfluence()).to.equal(token(100));
        expect(await proposal.againstInfluence()).to.equal(token(50));
        expect(await proposal.result()).to.equal(1);
    })

    it("Voting 2 people should fail", async () => {
        // await expect(await proposal.connect(signers[0]).vote("yes", 1)).to.be.reverted;
        await govToken.connect(signers[0]).transfer(await signers[1].getAddress(), token(40));
        await govToken.connect(signers[0]).transfer(await signers[2].getAddress(), token(100));
        await govToken.connect(signers[0]).approve(gov.address, token(100));
        await govToken.connect(signers[1]).approve(gov.address, token(40));
        await govToken.connect(signers[2]).approve(gov.address, token(100));

        //creating proposal
        await expect(await gov.connect(signers[0]).createProposal("test", 1, 1, AddressZero, AddressZero)).to.be.ok;
        let prop = (await gov.getDeployedProposals())[0];
        proposal = LiquifiProposalFactory.connect(prop, signers[5]);

        await proposal.connect(signers[1])["vote(uint8)"](1);
        await proposal.connect(signers[2])["vote(uint8)"](2);
        
        expect(await proposal.approvalsInfluence()).to.equal(token(40));
        expect(await proposal.againstInfluence()).to.equal(token(100));

        skipTime(60 * 60 * 24 * 3); //3 days

        await proposal.finalize()

        expect(await proposal.result()).to.equal(2);
    })
})