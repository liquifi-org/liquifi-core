// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.6;

import { LiquifiToken } from "../LiquifiToken.sol";

contract TestToken is LiquifiToken {

    string public override name;
    uint8 public override decimals = 18;
    string public override symbol;
    string public version = 'v1.0';
    uint public override totalSupply;

    constructor(uint amount, string memory tokenName, string memory tokenSymbol, address[] memory owners) public {
        uint ownersLength = owners.length;
        totalSupply = amount * (ownersLength + 1);
        for (uint i = 0; i < ownersLength; i++) {
            accountBalances[owners[uint(i)]] = amount;
        }
        accountBalances[msg.sender] = amount;

        name = tokenName;
        symbol = tokenSymbol;
    }
}