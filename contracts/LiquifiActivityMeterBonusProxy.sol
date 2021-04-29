// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.6;

import { ActivityMeter } from "./interfaces/ActivityMeter.sol";
import { Minter } from "./interfaces/Minter.sol";
import { Math } from "./libraries/Math.sol";

contract LiquifiActivityMeterBonusProxy {
    using Math for uint256;

    ActivityMeter immutable public activityMeter;
	Minter immutable public lqf;
	address immutable public lqfPoolAddress;
	address immutable owner;
	
	uint immutable public maxPeriod = 12;

    struct UserBonusSummary {
        uint ethLocked;
        uint ethLockedPeriod;
    }
	
	mapping(address => UserBonusSummary) public userBonusSummary;
	
	mapping(uint => uint) public ethLockedHistory;
	
	mapping(address => bool) exceptAddresses;
	
	event BonusTransferred(address indexed to, uint amount, uint period);
	
    constructor(address _activityMeter, address _lqfPoolAddress, address _lqfAddress) public {
        activityMeter = ActivityMeter(_activityMeter);
		lqfPoolAddress = _lqfPoolAddress;
		lqf = Minter(_lqfAddress);
		owner = msg.sender;
		
		exceptAddresses[0xd165390fC2D5285C1E355672e31E07499caeE093] = true;
		exceptAddresses[0xaF7E52564AD8cf64B2eAd3348F6D2c55D017dBCa] = true;
		exceptAddresses[0xd39Be3664A5a836efc5C69dB2cD4F1af43B31d96] = true;
    }

    function actualizeUserPools() external returns (uint ethLocked, uint mintedAmount) {
        address user = msg.sender;

        (uint currentPeriod, ) = activityMeter.effectivePeriod(block.timestamp);
        uint userPoolIndex = activityMeter.userPoolsLength(user);
		uint ethLockedTotal = activityMeter.ethLockedHistory(currentPeriod - 1);
		
		transferLQFBonus(user, currentPeriod);

        while(userPoolIndex > 0) {
            userPoolIndex--;
            address pool = activityMeter.userPools(user, userPoolIndex);
            (uint poolEthLocked, uint _mintedAmount) = activityMeter.actualizeUserPool(currentPeriod - 1, user, pool);
            ethLocked = Math.addWithClip(ethLocked, poolEthLocked, ~uint(0));
            mintedAmount = _mintedAmount > 0 ? _mintedAmount : mintedAmount;

			uint ethLockedTotalNew = activityMeter.ethLockedHistory(currentPeriod - 1);

			if(pool == lqfPoolAddress && !exceptAddresses[user]) {
				UserBonusSummary memory bonusSummary = userBonusSummary[user];
				bonusSummary.ethLocked += ethLockedTotalNew - ethLockedTotal;
				ethLockedHistory[currentPeriod - 1] += ethLockedTotalNew - ethLockedTotal;
				bonusSummary.ethLockedPeriod = currentPeriod - 1;
				userBonusSummary[user] = bonusSummary;
			}

			ethLockedTotal = ethLockedTotalNew;
        }
    }
	
	function transferLQFBonus(address user, uint currentPeriod) internal {
		if(currentPeriod > maxPeriod) return;
		
		UserBonusSummary memory bonusSummary = userBonusSummary[user];
		
		if(bonusSummary.ethLockedPeriod < currentPeriod - 1 && bonusSummary.ethLocked > 0) {
			uint totalEthLocked = activityMeter.ethLockedHistory(bonusSummary.ethLockedPeriod);
			if(totalEthLocked > 0) {
				uint bonusToTransfer = (uint(lqf.periodTokens(bonusSummary.ethLockedPeriod)) * bonusSummary.ethLocked) / totalEthLocked / 2;
				require(lqf.transfer(user, bonusToTransfer), "LQF transfer failed");
				bonusSummary.ethLocked = 0;
				bonusSummary.ethLockedPeriod = currentPeriod - 1;
				userBonusSummary[user] = bonusSummary;
				
				emit BonusTransferred(user, bonusToTransfer, currentPeriod - 1);
			}
		}
	}

	function withdraw(address to, uint amount) external {
		require(msg.sender == owner, "Only owner can do this");
		require(lqf.transfer(to, amount), "LQF transfer failed");
	}
	
	function totalBonus(uint period) external view returns(uint total) {
		uint ethLockedTotal = activityMeter.ethLockedHistory(period);
		
		if(ethLockedTotal > 0)
			total =  ethLockedHistory[period] * uint(lqf.periodTokens(period)) / ethLockedTotal / 2;
		else
			total = 0;
	}
	
	function bonusPayable(address user, uint currentPeriod) external view returns(uint amount) {
		amount = 0;
		if(currentPeriod <= maxPeriod) {
		
			UserBonusSummary memory bonusSummary = userBonusSummary[user];
			
			if(bonusSummary.ethLockedPeriod < currentPeriod - 1 && bonusSummary.ethLocked > 0) {
				uint totalEthLocked = activityMeter.ethLockedHistory(bonusSummary.ethLockedPeriod);
				if(totalEthLocked > 0) {
					amount = (uint(lqf.periodTokens(bonusSummary.ethLockedPeriod)) * bonusSummary.ethLocked) / totalEthLocked / 2;
				}
			}
		}
	}
}