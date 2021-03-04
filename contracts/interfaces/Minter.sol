// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;
import {GovernanceRouter} from "./GovernanceRouter.sol";
import {ActivityMeter} from "./ActivityMeter.sol";
import {ERC20} from "./ERC20.sol";

interface Minter is ERC20 {
    event Mint(
        address indexed to,
        uint256 value,
        uint256 indexed period,
        uint256 userEthLocked,
        uint256 totalEthLocked
    );

    function mint(
        address to,
        uint256 period,
        uint128 userEthLocked,
        uint256 totalEthLocked
    ) external returns (uint256 amount);

    function userTokensToClaim(address user) external view returns (uint256 amount);

    function periodTokens(uint256 period) external pure returns (uint128);

    function periodDecayK() external pure returns (uint256 decayK);

    function initialPeriodTokens() external pure returns (uint128);
}
