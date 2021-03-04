// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import {GovernanceRouter} from "../interfaces/GovernanceRouter.sol";
import {LiquifiMinter} from "../LiquifiMinter.sol";

contract TestMinter is LiquifiMinter {
    constructor(
        address _governanceRouter,
        uint256 amount,
        address[] memory owners
    ) LiquifiMinter() {
        uint256 ownersLength = owners.length;
        totalSupply = amount * (ownersLength + 1);
        for (uint256 i = 0; i < ownersLength; i++) {
            accountBalances[owners[uint256(i)]] = amount;
        }
        accountBalances[msg.sender] = amount;
    }
}
