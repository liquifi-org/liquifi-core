// SPDX-License-Identifier: ICS
pragma solidity >= 0.7.0 <0.8.0;

import {ERC20} from "./interfaces/ERC20.sol";

abstract contract LiquifiToken is ERC20 {

    function transfer(address to, uint256 value) public override returns (bool success) {
        if (accountBalances[msg.sender] >= value && value > 0) {
            accountBalances[msg.sender] -= value;
            accountBalances[to] += value;
            emit Transfer(msg.sender, to, value);
            return true;
        }
        return false;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool success) {
        if (accountBalances[from] >= value && allowed[from][msg.sender] >= value && value > 0) {
            accountBalances[to] += value;
            accountBalances[from] -= value;
            allowed[from][msg.sender] -= value;
            emit Transfer(from, to, value);
            return true;
        }
        return false;
    }

    function balanceOf(address owner) public override view returns (uint256 balance) {
        return accountBalances[owner];
    }

    function approve(address spender, uint256 value) external override returns (bool success) {
        allowed[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function allowance(address owner, address spender) external override view returns (uint256 remaining) {
      return allowed[owner][spender];
    }

    mapping (address => uint256) internal accountBalances;
    mapping (address => mapping (address => uint256)) internal allowed;
}