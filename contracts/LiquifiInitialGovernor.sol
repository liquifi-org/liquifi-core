// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import {LiquifiProposal} from "./LiquifiProposal.sol";
import {LiquifiDAO} from "./libraries/LiquifiDAO.sol";
import {GovernanceRouter} from "./interfaces/GovernanceRouter.sol";
import {ERC20} from "./interfaces/ERC20.sol";
import {DelayedExchangePool} from "./interfaces/DelayedExchangePool.sol";
import {Liquifi} from "./libraries/Liquifi.sol";
import {Math} from "./libraries/Math.sol";

//import { Debug } from "./libraries/Debug.sol";

contract LiquifiInitialGovernor {
    using Math for uint256;

    event EmergencyLock(address sender, address pool);
    event ProposalCreated(address proposal);
    event ProposalFinalized(address proposal, LiquifiDAO.ProposalStatus proposalStatus);
    event DepositWithdrawn(address user, uint256 amount);

    struct CreatedProposals {
        uint256 amountDeposited;
        LiquifiDAO.ProposalStatus status;
        address creator;
    }

    struct Deposit {
        uint256 amount;
        uint256 unfreezeTime;
    }

    LiquifiProposal[] public deployedProposals;
    mapping(address => CreatedProposals) proposalInfo;
    /* user */
    mapping(address => Deposit) public deposits;
    address[] public userDepositsList;

    uint256 public immutable tokensRequiredToCreateProposal;
    uint256 public constant quorum = 10; //percenrage
    uint256 public constant threshold = 50;
    uint256 public constant vetoPercentage = 33;
    uint256 public immutable votingPeriod; //hours

    ERC20 private immutable govToken;
    GovernanceRouter public immutable governanceRouter;

    constructor(
        address _governanceRouterAddress,
        uint256 _tokensRequiredToCreateProposal,
        uint256 _votingPeriod
    ) {
        tokensRequiredToCreateProposal = _tokensRequiredToCreateProposal;
        votingPeriod = _votingPeriod;
        govToken = GovernanceRouter(_governanceRouterAddress).minter();
        governanceRouter = GovernanceRouter(_governanceRouterAddress);
        (address oldGovernor, ) = GovernanceRouter(_governanceRouterAddress).governance();
        if (oldGovernor == address(0)) {
            GovernanceRouter(_governanceRouterAddress).setGovernor(address(this));
        }
    }

    function deposit(
        address user,
        uint256 amount,
        uint256 unfreezeTime
    ) private {
        uint256 deposited = deposits[user].amount;
        if (deposited < amount) {
            uint256 remainingAmount = amount.subWithClip(deposited);
            require(govToken.transferFrom(user, address(this), remainingAmount), "LIQUIFI_GV: TRANSFER FAILED");
            deposits[user].amount = amount;
        }
        deposits[user].unfreezeTime = Math.max(deposits[user].unfreezeTime, unfreezeTime);
        userDepositsList.push(user);
    }

    function withdraw() public {
        require(_withdraw(msg.sender, block.timestamp) > 0, "LIQUIFI_GV: WITHDRAW FAILED");
    }

    function _withdraw(address user, uint256 maxTime) private returns (uint256) {
        uint256 amount = deposits[user].amount;
        if (amount == 0 || deposits[user].unfreezeTime >= maxTime) {
            return 0;
        }

        deposits[user].amount = 0;
        require(govToken.transfer(user, amount), "LIQUIFI_GV: TRANSFER FAILED");
        emit DepositWithdrawn(user, amount);
        return amount;
    }

    function withdrawAll() public {
        withdrawMultiple(0, userDepositsList.length);
    }

    function withdrawMultiple(uint256 fromIndex, uint256 toIndex) public {
        uint256 maxWithdrawTime = block.timestamp;
        (address currentGovernor, ) = governanceRouter.governance();

        if (currentGovernor != address(this)) {
            maxWithdrawTime = type(uint256).max;
        }

        for (uint256 userIndex = fromIndex; userIndex < toIndex; userIndex++) {
            _withdraw(userDepositsList[userIndex], maxWithdrawTime);
        }
    }

    function createProposal(
        string memory _proposal,
        uint256 _option,
        uint256 _newValue,
        address _address,
        address _address2
    ) public {
        address creator = msg.sender;
        LiquifiProposal newProposal =
            new LiquifiProposal(
                _proposal,
                govToken.totalSupply(),
                address(govToken),
                _option,
                _newValue,
                quorum,
                threshold,
                vetoPercentage,
                votingPeriod,
                _address,
                _address2
            );

        uint256 tokensRequired = deposits[creator].amount.add(tokensRequiredToCreateProposal);
        deposit(creator, tokensRequired, newProposal.endTime());

        deployedProposals.push(newProposal);

        proposalInfo[address(newProposal)].amountDeposited = tokensRequiredToCreateProposal;
        proposalInfo[address(newProposal)].creator = creator;
        emit ProposalCreated(address(newProposal));
    }

    function emergencyLock(address pool) public returns (bool locked) {
        uint256 gasBefore = gasleft();
        try DelayedExchangePool(pool).processDelayedOrders() {
            return false;
        } catch (
            bytes memory /*lowLevelData*/
        ) {
            uint256 gasAfter = gasleft();
            require(((gasBefore - gasAfter) * 10) / gasBefore >= 1, "LIQUIFI: LOW GAS");
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

    function proposalVote(
        address user,
        uint256 influence,
        uint256 unfreezeTime
    ) public {
        address proposal = msg.sender;
        require(proposalInfo[proposal].amountDeposited > 0, "LIQUIFI_GV: BAD SENDER");
        require(
            proposalInfo[proposal].status == LiquifiDAO.ProposalStatus.IN_PROGRESS,
            "LIQUIFI_GV: PROPOSAL FINALIZED"
        );

        deposit(user, influence, unfreezeTime);
    }

    function proposalFinalization(
        LiquifiDAO.ProposalStatus _proposalStatus,
        uint256 _option,
        uint256, /* _value */
        address _address,
        address /* _address2 */
    ) public {
        address proposal = msg.sender;
        require(proposalInfo[proposal].amountDeposited > 0, "LIQUIFI_GV: BAD SENDER");
        require(
            proposalInfo[proposal].status == LiquifiDAO.ProposalStatus.IN_PROGRESS,
            "LIQUIFI_GV: PROPOSAL FINALIZED"
        );

        if (_proposalStatus == LiquifiDAO.ProposalStatus.APPROVED) {
            if (_option == 1) {
                changeGovernor(_address);
            }
        }

        proposalInfo[proposal].status = _proposalStatus;
        emit ProposalFinalized(proposal, _proposalStatus);
    }

    function changeGovernor(address _newGovernor) private {
        governanceRouter.setGovernor(_newGovernor);
    }

    function lockPool(address pool) internal {
        (, uint256 governancePacked, , , , , , ) = DelayedExchangePool(pool).poolState();

        governancePacked = governancePacked | (1 << uint256(Liquifi.Flag.POOL_LOCKED));
        governancePacked = governancePacked | (1 << uint256(Liquifi.Flag.GOVERNANCE_OVERRIDEN));
        DelayedExchangePool(pool).applyGovernance(governancePacked);
    }

    function knownPool(address pool) private returns (bool) {
        address tokenA = address(DelayedExchangePool(pool).tokenA());
        address tokenB = address(DelayedExchangePool(pool).tokenB());
        return governanceRouter.poolFactory().findPool(tokenA, tokenB) == pool;
    }
}
