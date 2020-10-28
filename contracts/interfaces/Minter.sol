// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.0;
import { GovernanceRouter } from "./GovernanceRouter.sol";
import { ActivityMeter } from "./ActivityMeter.sol";
import { ERC20 } from "./ERC20.sol";

interface Minter is ERC20 {
    event Mint(address indexed to, uint256 value, uint indexed period, uint userEthLocked, uint totalEthLocked);

    function governanceRouter() external view returns (GovernanceRouter);
    function mint(address to, uint period, uint128 userEthLocked, uint totalEthLocked) external returns (uint amount);
    function userTokensToClaim(address user) external view returns (uint amount);
    function periodTokens(uint period) external pure returns (uint128);
    function periodDecayK() external pure returns (uint decayK);
    function initialPeriodTokens() external pure returns (uint128);
}