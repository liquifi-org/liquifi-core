// SPDX-License-Identifier: GPL-3.0
pragma solidity >= 0.7.0 <0.8.0;

import {LiquifiInitialGovernor} from "./LiquifiInitialGovernor.sol";
import {LiquifiDAO} from "./libraries/LiquifiDAO.sol";
import {ERC20} from "./interfaces/ERC20.sol";
import { Math } from "./libraries/Math.sol";
//import { Debug } from "./libraries/Debug.sol";

contract LiquifiProposal {
    using Math for uint256;
    event ProposalVoted(address user, Vote vote, uint influence);

    ERC20 public immutable govToken;
    LiquifiInitialGovernor public immutable governor;

    enum Vote {
        NONE, YES, NO, ABSTAIN, NO_WITH_VETO
    }

    mapping(address => Vote) public voted;
    // 0 - hasn't voted
    // 1 - voted yes
    // 2 - voted no
    // 3 - voted abstain
    // 4 - voted noWithVeto

    string public description;
    uint public approvalsInfluence = 0;
    uint public againstInfluence = 0;
    uint public abstainInfluence = 0;
    uint public noWithVetoInfluence = 0;
    
    LiquifiDAO.ProposalStatus public result;
    
    uint public immutable started; //time when proposal was created
    uint public immutable totalInfluence;
    
    uint public immutable option;
    uint public immutable newValue;
    uint public immutable quorum;
    uint public immutable vetoPercentage;
    uint public immutable votingPeriod;
    uint public immutable threshold;
    address public immutable addr;
    address public immutable addr2;

    constructor(string memory _description, 
            uint _totalInfluence, 
            address _govToken, 
            uint _option, uint _newValue, 
            uint _quorum, uint _threshold, uint _vetoPercentage, uint _votingPeriod, 
            address _address, address _address2) {
        description = _description;
        started = block.timestamp;
        totalInfluence = _totalInfluence; 
        governor = LiquifiInitialGovernor(msg.sender);
        govToken = ERC20(_govToken);

        option = _option;
        newValue = _newValue;

        quorum = _quorum;
        threshold = _threshold;
        vetoPercentage = _vetoPercentage;
        votingPeriod = _votingPeriod;
        addr = _address;
        addr2 = _address2;
    }

    function vote(Vote _vote) public {
        address user = msg.sender;
        uint influence = govToken.balanceOf(user);
        (uint deposited,) = governor.deposits(user);
        influence = influence.add(deposited);
        vote(_vote, influence);
    }


    function vote(Vote _vote, uint influence) public {
        address user = msg.sender;
        require(voted[user] == Vote.NONE, "You have already voted!");

        voted[user] = _vote; // prevent reentrance

        require(influence > 0, "Proposal.vote: No governance tokens in wallet");
        governor.proposalVote(user, influence, endTime());

        if (checkIfEnded() != LiquifiDAO.ProposalStatus.IN_PROGRESS)
            return;
            
        if (_vote == Vote.YES) {
            approvalsInfluence += influence;
        } else if (_vote == Vote.NO) {
            againstInfluence += influence;
        } else if (_vote == Vote.ABSTAIN) {
            abstainInfluence += influence;
        } else if (_vote == Vote.NO_WITH_VETO) {
            noWithVetoInfluence += influence;
            againstInfluence += influence;
        }
        emit ProposalVoted(user, _vote, influence);
    }

    function endTime() public view returns (uint) {
        return started + 1 hours * votingPeriod;
    }

    function checkIfEnded() public returns (LiquifiDAO.ProposalStatus) {
        require(result == LiquifiDAO.ProposalStatus.IN_PROGRESS, "voting completed");
        
        if (block.timestamp > endTime()) {
            return finalize();
        } else {
            return LiquifiDAO.ProposalStatus.IN_PROGRESS;
        }
    }

    function finalize() public returns (LiquifiDAO.ProposalStatus) {
        require(block.timestamp > endTime(), "Proposal: Period hasn't passed");

        if ((totalInfluence != 0) 
            && (100 * (approvalsInfluence + againstInfluence + abstainInfluence) / totalInfluence < quorum )){
            result = LiquifiDAO.ProposalStatus.DECLINED;
            governor.proposalFinalization(result, 0, 0, address(0), address(0));
            return result;        
        }

        if ((approvalsInfluence + againstInfluence + abstainInfluence) != 0 &&
            (100 * noWithVetoInfluence / (approvalsInfluence + againstInfluence + abstainInfluence) >= vetoPercentage)) {
            result = LiquifiDAO.ProposalStatus.VETO;
            governor.proposalFinalization(result, 0, 0, address(0), address(0));
        }
        else if ((approvalsInfluence + againstInfluence) != 0 &&
            (100 * approvalsInfluence / (approvalsInfluence + againstInfluence) > threshold)) {
            result = LiquifiDAO.ProposalStatus.APPROVED;
            governor.proposalFinalization(result, option, newValue, addr, addr2);
        }
        else {
            result = LiquifiDAO.ProposalStatus.DECLINED;
            governor.proposalFinalization(result, 0, 0, address(0), address(0));
        }

        return result;
    }
}
