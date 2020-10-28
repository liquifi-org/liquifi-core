// SPDX-License-Identifier: ISC
pragma solidity = 0.7.0;
import { ERC20 } from "../interfaces/ERC20.sol";

library LiquifiDAO {
    enum ProposalStatus { 
        IN_PROGRESS,
        APPROVED,
        DECLINED,
        VETO
    }
}