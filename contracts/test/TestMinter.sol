// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.6;

import { GovernanceRouter } from "../interfaces/GovernanceRouter.sol";
import { LiquifiMinter } from "../LiquifiMinter.sol";

contract TestMinter is LiquifiMinter {
    constructor(address _governanceRouter, uint amount, address[] memory owners) public LiquifiMinter(_governanceRouter) {
        uint ownersLength = owners.length;
        totalSupply = amount * (ownersLength + 1);
        for (uint i = 0; i < ownersLength; i++) {
            accountBalances[owners[uint(i)]] = amount;
        }
        accountBalances[msg.sender] = amount;
    }
}