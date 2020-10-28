// SPDX-License-Identifier: ISC
pragma solidity = 0.7.0;

import {LiquifiInitialGovernor} from "./LiquifiInitialGovernor.sol";
import {LiquifiDAO} from "./libraries/LiquifiDAO.sol";
import {ERC20} from "./interfaces/ERC20.sol";

contract LiquifiProposal {
    event ProposalVoted(address user, uint vote, uint influence);

    ERC20 public immutable govToken;
    LiquifiInitialGovernor public immutable governor;

    mapping(address => uint8) public voted;
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

    function vote(uint _vote) public {
        address user = msg.sender;
        require(voted[user] == 0, "You have already voted!");

        voted[user] = uint8(_vote); // prevent reentrance
        uint influence = govToken.balanceOf(user);

        require(influence > 0, "Proposal.vote: No governance tokens in wallet");
        require(_vote > 0 && _vote < 5, "Invalid vote option");

        if (checkIfEnded() != LiquifiDAO.ProposalStatus.IN_PROGRESS)
            return;
            
        if (_vote == 1) {
            approvalsInfluence += influence;
        } else if (_vote == 2) {
            againstInfluence += influence;
        } else if (_vote == 3) {
            abstainInfluence += influence;
        } else if (_vote == 4) {
            noWithVetoInfluence += influence;
            againstInfluence += influence;
        }
        emit ProposalVoted(user, _vote, influence);
    }

    function checkIfEnded() public returns (LiquifiDAO.ProposalStatus) {
        require(result == LiquifiDAO.ProposalStatus.IN_PROGRESS, "voting completed");
        
        if (block.timestamp > started + 1 hours * votingPeriod) {
            return finalize();
        }
    }

    function finalize() public returns (LiquifiDAO.ProposalStatus) {
        require(block.timestamp > started + 1 hours * votingPeriod, "Proposal: Period hasn't passed");

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
