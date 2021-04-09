// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.6;

import { ActivityMeter } from "./interfaces/ActivityMeter.sol";
import { GovernanceRouter } from "./interfaces/GovernanceRouter.sol";
import { Math } from "./libraries/Math.sol";
import { LiquifiToken } from "./LiquifiToken.sol";
import { Minter } from "./interfaces/Minter.sol";
//import { Debug } from "./libraries/Debug.sol";

contract LiquifiMinter is LiquifiToken, Minter {
    using Math for uint256;

    string public constant override name = "Liquifi DAO Token";
    string public constant override symbol = "LQF";
    uint8 public constant override decimals = 18;
    uint public override totalSupply;
    GovernanceRouter public override immutable governanceRouter;
    ActivityMeter public immutable activityMeter;

    uint128 public override constant initialPeriodTokens = 2500000 * (10 ** 18);
    uint public override constant periodDecayK = 250; // pre-multiplied by 2**8

    constructor(address _governanceRouter) public {
        GovernanceRouter(_governanceRouter).setMinter(this);
        governanceRouter = GovernanceRouter(_governanceRouter);
        activityMeter = GovernanceRouter(_governanceRouter).activityMeter();
    }

    function periodTokens(uint period) public override pure returns (uint128) {
        period -= 1; // decayK for 1st period = 1
        uint decay = periodDecayK ** (period % 16); // process periods not covered by the loop
        decay = decay << ((16 - period % 16) * 8); // ensure that result is pre-multiplied by 2**128
        period = period / 16;
        uint numerator = periodDecayK ** 16;
        uint denominator = 1 << 128;
        while(period * decay != 0) { // one loop multiplies result by 16 periods decay
            decay = (decay * numerator) / denominator;
            period--;
        }

        return uint128((decay * initialPeriodTokens) >> 128);
    }

    function mint(address to, uint period, uint128 userEthLocked, uint totalEthLocked) external override returns (uint amount) {
        require(msg.sender == address(activityMeter), "LIQUIFI: INVALID MINT SENDER");
        if (totalEthLocked == 0) {
            return 0;
        }
        amount = (uint(periodTokens(period)) * userEthLocked) / totalEthLocked;
        totalSupply = totalSupply.add(amount);
        accountBalances[to] += amount;
        emit Mint(to, amount, period, userEthLocked, totalEthLocked);
    }

    function userTokensToClaim(address user) external view override returns (uint amount) {
        (uint ethLockedPeriod, uint userEthLocked, uint totalEthLocked) = activityMeter.userEthLocked(user);
        if (ethLockedPeriod != 0 && totalEthLocked != 0) {
            amount = (uint(periodTokens(ethLockedPeriod)) * userEthLocked) / totalEthLocked;
        }
    }
}