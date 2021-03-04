// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;
import {ERC20} from "../interfaces/ERC20.sol";

library LiquifiDAO {
    enum ProposalStatus {IN_PROGRESS, APPROVED, DECLINED, VETO}
}
