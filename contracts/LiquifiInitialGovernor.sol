// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.0;

import {LiquifiProposal} from "./LiquifiProposal.sol";
import {LiquifiDAO} from "./libraries/LiquifiDAO.sol";
import {GovernanceRouter} from "./interfaces/GovernanceRouter.sol";
import {ERC20} from "./interfaces/ERC20.sol";
import { DelayedExchangePool } from "./interfaces/DelayedExchangePool.sol";
import { Liquifi } from "./libraries/Liquifi.sol";

contract LiquifiInitialGovernor {
    event EmergencyLock(address sender, address pool);
    event ProposalCreated(address proposal);
    event ProposalFinalized(address proposal, LiquifiDAO.ProposalStatus proposalStatus, uint tokensRefunded);

    struct CreatedProposals{
        uint amountDeposited;
        LiquifiDAO.ProposalStatus status;
        address creator;
    }
    
    LiquifiProposal[] public deployedProposals;
    mapping(address => CreatedProposals) proposalInfo;

    uint public immutable tokensRequiredToCreateProposal; 
    uint public constant quorum = 50; //percenrage
    uint public constant threshold = 50;
    uint public constant vetoPercentage = 33;
    uint public immutable votingPeriod; //hours

    ERC20 private immutable govToken;
    GovernanceRouter public immutable governanceRouter;

    constructor(address _governanceRouterAddress, uint _tokensRequiredToCreateProposal, uint _votingPeriod) {
        tokensRequiredToCreateProposal = _tokensRequiredToCreateProposal;
        votingPeriod = _votingPeriod;
        govToken = GovernanceRouter(_governanceRouterAddress).minter();
        governanceRouter = GovernanceRouter(_governanceRouterAddress);
        (address oldGovernor,) = GovernanceRouter(_governanceRouterAddress).governance();
        if (oldGovernor == address(0)) {
            GovernanceRouter(_governanceRouterAddress).setGovernor(address(this));
        }
    }

    function createProposal(string memory _proposal, uint _option, uint _newValue, address _address, address _address2) public {
        require(govToken.balanceOf(msg.sender) >= tokensRequiredToCreateProposal, "LIQUIFI_GV: LOW BALANCE");
        require(govToken.transferFrom(msg.sender, address(this), tokensRequiredToCreateProposal), 
            "LIQUIFI_GV: TRANSFER FAILED");

        LiquifiProposal newProposal = new LiquifiProposal(_proposal, govToken.totalSupply(), address(govToken), _option, _newValue, quorum, threshold, vetoPercentage, votingPeriod, _address, _address2);

        deployedProposals.push(newProposal);

        proposalInfo[address(newProposal)].amountDeposited = tokensRequiredToCreateProposal;
        proposalInfo[address(newProposal)].creator = msg.sender;
        emit ProposalCreated(address(newProposal));
    }

    function emergencyLock(address pool) public returns (bool locked) {
        uint gasBefore = gasleft();
        try DelayedExchangePool(pool).processDelayedOrders() {
            return false;
        } catch (bytes memory /*lowLevelData*/) {
            uint gasAfter = gasleft();
            require((gasBefore - gasAfter) * 10 / gasBefore >= 1, "LIQUIFI: LOW GAS");
            lockPool(pool);
            if (knownPool(pool)) {
                emit EmergencyLock(msg.sender, pool);
            }
            return true;
        }
    }

    function getDeployedProposals() public view returns (LiquifiProposal[] memory) {
        return deployedProposals;
    }

    function proposalFinalization(LiquifiDAO.ProposalStatus _proposalStatus, uint _option, uint /* _value */, address _address, address /* _address2 */) public {
        address proposal = msg.sender;
        require(proposalInfo[proposal].amountDeposited > 0, "LIQUIFI_GV: BAD SENDER");
        require(proposalInfo[proposal].status == LiquifiDAO.ProposalStatus.IN_PROGRESS, "LIQUIFI_GV: PROPOSAL FINALIZED");

        if (_proposalStatus == LiquifiDAO.ProposalStatus.APPROVED) {
            if (_option ==  0) { changeGovernor(_address); }
        }

        proposalInfo[proposal].status = _proposalStatus;   

        bool refunded = govToken.transfer(proposalInfo[proposal].creator, proposalInfo[proposal].amountDeposited);
        emit ProposalFinalized(proposal, _proposalStatus, refunded ? proposalInfo[proposal].amountDeposited : 0);   
    }

    function changeGovernor(address _newGovernor) private {
        governanceRouter.setGovernor(_newGovernor);
    }

    function lockPool(address pool) internal {
        (,uint governancePacked,,,,,,) = DelayedExchangePool(pool).poolState();

        governancePacked = governancePacked | (1 << uint(Liquifi.Flag.POOL_LOCKED));
        governancePacked = governancePacked | (1 << uint(Liquifi.Flag.GOVERNANCE_OVERRIDEN));
        DelayedExchangePool(pool).applyGovernance(governancePacked);
    }

    function knownPool(address pool) private returns (bool) {
        address tokenA = address(DelayedExchangePool(pool).tokenA());
        address tokenB = address(DelayedExchangePool(pool).tokenB());
        return governanceRouter.poolFactory().findPool(tokenA, tokenB) == pool;
    }
}