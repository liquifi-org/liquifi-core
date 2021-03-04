// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import {LiquifiToken} from "../LiquifiToken.sol";

contract TestToken is LiquifiToken {
    string public override name;
    uint8 public override decimals = 18;
    string public override symbol;
    string public version = "v1.0";
    uint256 public override totalSupply;

    constructor(
        uint256 amount,
        string memory tokenName,
        string memory tokenSymbol,
        address[] memory owners
    ) {
        uint256 ownersLength = owners.length;
        totalSupply = amount * (ownersLength + 1);
        for (uint256 i = 0; i < ownersLength; i++) {
            accountBalances[owners[uint256(i)]] = amount;
        }
        accountBalances[msg.sender] = amount;

        name = tokenName;
        symbol = tokenSymbol;
    }
}
