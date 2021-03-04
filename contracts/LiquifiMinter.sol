// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import {ActivityMeter} from "./interfaces/ActivityMeter.sol";
import {Math} from "./libraries/Math.sol";
import {LiquifiToken} from "./LiquifiToken.sol";
import {Minter} from "./interfaces/Minter.sol";

contract LiquifiMinter is LiquifiToken, Minter {
    using Math for uint256;

    string public constant override name = "Liquifi DAO Token";
    string public constant override symbol = "LQF";
    uint8 public constant override decimals = 18;
    uint256 public override totalSupply;

    ActivityMeter public activityMeter;

    uint128 public constant override initialPeriodTokens = 2500000 * (10**18);
    uint256 public constant override periodDecayK = 250; // pre-multiplied by 2**8

    address immutable owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyBy(address _account) {
        require(msg.sender == _account, "LIQUIFI: INVALID MESSAGE SENDER");
        _;
    }

    function setActivityMeter(address _activityMeter) public onlyBy(owner) {
        require(address(activityMeter) == address(0), "LIQUIFI: ACTIVITY METER HAS ALREADY BEEN SPECIFIED");
        activityMeter = ActivityMeter(_activityMeter);
    }

    function periodTokens(uint256 period) public pure override returns (uint128) {
        period -= 1; // decayK for 1st period = 1
        uint256 decay = periodDecayK**(period % 16); // process periods not covered by the loop
        decay = decay << ((16 - (period % 16)) * 8); // ensure that result is pre-multiplied by 2**128
        period = period / 16;
        uint256 numerator = periodDecayK**16;
        uint256 denominator = 1 << 128;
        while (period * decay != 0) {
            // one loop multiplies result by 16 periods decay
            decay = (decay * numerator) / denominator;
            period--;
        }
        return uint128((decay * initialPeriodTokens) >> 128);
    }

    function mint(
        address to,
        uint256 period,
        uint128 userEthLocked,
        uint256 totalEthLocked
    ) external override onlyBy(address(activityMeter)) returns (uint256 amount) {
        if (totalEthLocked == 0) {
            return 0;
        }
        amount = (uint256(periodTokens(period)) * userEthLocked) / totalEthLocked;
        totalSupply = totalSupply.add(amount);
        accountBalances[to] += amount;
        emit Mint(to, amount, period, userEthLocked, totalEthLocked);
    }

    function userTokensToClaim(address user) external view override returns (uint256 amount) {
        (uint256 ethLockedPeriod, uint256 userEthLocked, uint256 totalEthLocked) = activityMeter.userEthLocked(user);
        if (ethLockedPeriod != 0 && totalEthLocked != 0) {
            amount = (uint256(periodTokens(ethLockedPeriod)) * userEthLocked) / totalEthLocked;
        }
    }
}
