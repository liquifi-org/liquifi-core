// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.0;

import { ERC20 } from "./ERC20.sol";

interface WETH is ERC20 {
    function deposit() external payable;
    function withdraw(uint) external;
}