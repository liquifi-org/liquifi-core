// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.0;

import { ActivityMeter } from "./interfaces/ActivityMeter.sol";
import { GovernanceRouter } from "./interfaces/GovernanceRouter.sol";
import { Math } from "./libraries/Math.sol";
import { DelayedExchangePool } from "./interfaces/DelayedExchangePool.sol";
//import { Debug } from "./libraries/Debug.sol";

contract LiquifiActivityMeter is ActivityMeter {
    using Math for uint256;

    struct PoolSummary {
        uint16 lastPriceRecord;
    }

    struct UserSummary {
        uint128 ethLocked;
        uint16 ethLockedPeriod;
        uint16 firstPeriod;
    }

    struct UserPoolSummary {  
        uint144 cumulativeAmountLocked;
        uint16 amountChangeQuantaElapsed;
        
        uint128 lastAmountLocked;
        uint16 firstPeriod;
        uint16 lastPriceRecord;
        uint16 earnedForPeriod;
    }

    struct PoolPriceRecord {
        uint cumulativeEthPrice;
        uint240 lastEthPrice;
        uint16 timeRef; // for last period - contains time quanta since period start; for historic periods contains next record number
    } 

    GovernanceRouter immutable public override governanceRouter;
    uint immutable private timeZero;
    uint immutable private miningPeriod;

    mapping (/*period*/uint =>  /*ethLockedTotal premultiplied on 2 ** 112 */uint) public override ethLockedHistory;
    mapping (/*period*/uint => mapping(/*pool*/address => PoolPriceRecord)) public override poolsPriceHistory;
    mapping (/*user*/address => mapping(/*pool*/address => UserPoolSummary)) public override userPoolsSummaries;
    
    mapping (/*user*/address => /*pool*/address[]) public override userPools;
    function userPoolsLength(address user) external view override returns (uint) { return userPools[user].length; }

    mapping(/*user*/address => UserSummary) public override userSummaries;
    mapping(/*pool*/address => PoolSummary) public override poolSummaries;
    
    address[] public override users;
    function usersLength() external view override returns (uint) { return users.length; }
    
    constructor(address _governanceRouter) public {
        GovernanceRouter(_governanceRouter).setActivityMeter(this);
        (timeZero, miningPeriod)  = GovernanceRouter(_governanceRouter).schedule();
        governanceRouter = GovernanceRouter(_governanceRouter);
    }

    function effectivePeriod(uint effectiveTime) public override view returns (uint periodNumber, uint quantaElapsed) {
        uint _miningPeriod = miningPeriod;
        uint _timeZero = timeZero;
        require(effectiveTime > _timeZero, "LIQUIFI METER: prehistoric time");
        uint timeElapsed = effectiveTime - _timeZero;
        periodNumber = 1 + (timeElapsed / _miningPeriod); // periods have numbers starting with 1
        quantaElapsed = ((timeElapsed % _miningPeriod) << 16) / _miningPeriod; // time elapsed in period measured in quantas: 1/2**16 parts of period
    }

    function actualizeUserPool(uint endPeriod, address user, address pool) external override returns (uint ethLocked, uint mintedAmount) {
        (uint currentPeriod, ) = effectivePeriod(block.timestamp);
        require(endPeriod < currentPeriod, "LIQUIFY: BAD EARNING PERIOD");
        UserPoolSummary memory userPoolSummary = userPoolsSummaries[user][pool];
        require(userPoolSummary.firstPeriod != 0, "LIQUIFY: NO USER POOL");
        (ethLocked, mintedAmount) = _actualizeUserPool(endPeriod, user, pool, userPoolSummary);
        userPoolsSummaries[user][pool] = userPoolSummary;
    }
    
    function deposit(address pool, uint128 amount) external override returns (uint ethLocked, uint mintedAmount) {
        address user = msg.sender; // this method should be called by the user
        (ethLocked, mintedAmount) = updateAmountLocked(user, pool, amount, true);
        emit Deposit(user, pool, amount);
        require(DelayedExchangePool(pool).transferFrom(user, address(this), amount), 
            "LIQUIFY: TRANSFER FROM FAILED");
    }

    function withdraw(address pool, uint128 amount) external override returns (uint ethLocked, uint mintedAmount) {
        address user = msg.sender; // this method should be called by the user
        (ethLocked, mintedAmount) = updateAmountLocked(user, pool, amount, false);
        emit Withdraw(user, pool, amount);
        require(DelayedExchangePool(pool).transfer(user, amount),
            "LIQUIFY: TRANSFER FAILED");
    }

    // for brave users having few pools and actualized recently
    // others could run out of gas
    function actualizeUserPools() external override returns (uint ethLocked, uint mintedAmount) {
        address user = msg.sender;

        (uint currentPeriod, ) = effectivePeriod(block.timestamp);
        uint userPoolIndex = userPools[user].length;

        while(userPoolIndex > 0) {
            userPoolIndex--;
            address pool = userPools[user][userPoolIndex];
            UserPoolSummary memory userPoolSummary = userPoolsSummaries[user][pool];
            (uint poolEthLocked, uint _mintedAmount) = _actualizeUserPool(currentPeriod - 1, user, pool, userPoolSummary);
            userPoolsSummaries[user][pool] = userPoolSummary;
            ethLocked = Math.addWithClip(ethLocked, poolEthLocked, ~uint(0));
            mintedAmount = _mintedAmount > 0 ? _mintedAmount : mintedAmount; 
        }
    }

    function liquidityEthPriceChanged(uint effectiveTime, uint availableBalanceEth, uint totalSupply) external override {
        // we don't care if someone pretending to be our pool will spend some gas on price reporting:
        // this price will be just never used
        address pool = msg.sender;
        if (totalSupply == 0 || availableBalanceEth == 0) { // should never happen, just in case
            return;
        }

        // next effectiveTime is never less than previous one in our pools
        (uint period, uint quantaElapsed) = effectivePeriod(effectiveTime);
        PoolPriceRecord storage priceRecord = poolsPriceHistory[period][pool];
        (uint lastEthPrice, uint timeRef) = (priceRecord.lastEthPrice, priceRecord.timeRef);
        uint cumulativeEthPrice;
        if (lastEthPrice == 0) { // no price record for this period
            PoolSummary memory poolSummary = poolSummaries[pool];
            if (poolSummary.lastPriceRecord != 0) {
                PoolPriceRecord memory prevPriceRecord = poolsPriceHistory[poolSummary.lastPriceRecord][pool];
                lastEthPrice = prevPriceRecord.lastEthPrice;
                cumulativeEthPrice = lastEthPrice * quantaElapsed;
                prevPriceRecord.cumulativeEthPrice = prevPriceRecord.cumulativeEthPrice + lastEthPrice * ((1 << 16) - prevPriceRecord.timeRef);
                prevPriceRecord.timeRef = uint16(period);
                poolsPriceHistory[poolSummary.lastPriceRecord][pool] = prevPriceRecord;
            }
            poolSummary.lastPriceRecord = uint16(period);
            poolSummaries[pool] = poolSummary;
        } else {
            uint quantaElapsedSinceLastUpdate = quantaElapsed - timeRef;
            cumulativeEthPrice = priceRecord.cumulativeEthPrice + lastEthPrice * quantaElapsedSinceLastUpdate;
        }

        priceRecord.cumulativeEthPrice = cumulativeEthPrice;
        uint currentPrice = (totalSupply << 112) / availableBalanceEth;
        (priceRecord.lastEthPrice, priceRecord.timeRef) = (uint240(currentPrice), uint16(quantaElapsed));
    }

    function userEthLocked(address user) external override view returns (uint ethLockedPeriod, uint ethLocked, uint totalEthLocked) {
        (uint currentPeriod, ) = effectivePeriod(block.timestamp);
        uint currentEthLockedPeriod = currentPeriod - 1;
        UserSummary memory userSummary = userSummaries[user];
        if (currentEthLockedPeriod > 0 && userSummary.ethLockedPeriod < currentEthLockedPeriod) {
            if (userSummary.ethLockedPeriod > 0) {
                ethLockedPeriod = userSummary.ethLockedPeriod;
                ethLocked = userSummary.ethLocked;
                totalEthLocked = ethLockedHistory[userSummary.ethLockedPeriod];
            }
        }
    }
    
    function _actualizeUserPool(uint period, address user, address pool, UserPoolSummary memory userPoolSummary) private returns (uint ethLocked, uint mintedAmount) {
        UserSummary memory userSummary = userSummaries[user];
        uint currentEthLockedPeriod;
        {
            (uint currentPeriod, ) = effectivePeriod(block.timestamp);
            currentEthLockedPeriod = currentPeriod - 1;
        }
        if (currentEthLockedPeriod > 0 && userSummary.ethLockedPeriod < currentEthLockedPeriod) {
            if (userSummary.ethLockedPeriod > 0) {
                mintedAmount = governanceRouter.minter().mint(
                    user, userSummary.ethLockedPeriod, userSummary.ethLocked, ethLockedHistory[userSummary.ethLockedPeriod]
                );
            }
            userSummary.ethLocked = 0;
            userSummary.ethLockedPeriod = uint16(currentEthLockedPeriod);
            userSummaries[user] = userSummary;
        }
        
        uint earningPeriod = userPoolSummary.earnedForPeriod;
        if (earningPeriod >= period) {
            return (0, mintedAmount);
        }
        // currentPeriod >= 2 at this line
        // currentEthLockedPeriod >= 1

        DelayedExchangePool(pool).processDelayedOrders();
        
        PoolSummary memory poolSummary = poolSummaries[pool];
        PoolPriceRecord memory poolPriceRecord = poolsPriceHistory[userPoolSummary.lastPriceRecord][pool];
        while ((++earningPeriod) <= period) {

            // if there is a newer price record and current one is obsolete and it doesn't refer to itself
            if (earningPeriod <= poolSummary.lastPriceRecord && poolPriceRecord.timeRef == earningPeriod && earningPeriod > userPoolSummary.lastPriceRecord) { 
                // switch to next price record
                userPoolSummary.lastPriceRecord = uint16(earningPeriod);
                poolPriceRecord = poolsPriceHistory[earningPeriod][pool];
            }

            uint cumulativeEthPrice = poolPriceRecord.cumulativeEthPrice;
            if (earningPeriod == poolSummary.lastPriceRecord) {
                cumulativeEthPrice += uint(poolPriceRecord.lastEthPrice) * ((1 << 16) - poolPriceRecord.timeRef); // no overflow here
            } else if (earningPeriod > userPoolSummary.lastPriceRecord) { // amount record is not related to current period
                cumulativeEthPrice = uint(poolPriceRecord.lastEthPrice) << 16;
            }

            uint cumulativeAmountLocked = userPoolSummary.cumulativeAmountLocked;
            if (cumulativeAmountLocked > 0 || userPoolSummary.amountChangeQuantaElapsed > 0) {
                cumulativeAmountLocked += uint(userPoolSummary.lastAmountLocked) * ((1 << 16) - userPoolSummary.amountChangeQuantaElapsed); // no overflow here
                userPoolSummary.cumulativeAmountLocked = 0;
                userPoolSummary.amountChangeQuantaElapsed = 0;
            } else {
                cumulativeAmountLocked = uint(userPoolSummary.lastAmountLocked) << 16;
            }
            
            if (cumulativeEthPrice != 0 && cumulativeAmountLocked != 0) {
                cumulativeAmountLocked = cumulativeAmountLocked.mulWithClip(2 ** 112, ~uint(0));
                ethLocked = Math.addWithClip(ethLocked, cumulativeAmountLocked / cumulativeEthPrice, ~uint128(0));
            }
        }

        userPoolSummary.earnedForPeriod = uint16(period);

        uint ethLockedTotal = ethLockedHistory[currentEthLockedPeriod];
        uint ethLockedTotalNew = Math.addWithClip(ethLockedTotal, ethLocked, ~uint(0));
        ethLockedHistory[currentEthLockedPeriod] = ethLockedTotalNew;
        ethLocked = Math.addWithClip(userSummary.ethLocked, ethLockedTotalNew - ethLockedTotal, ~uint128(0)); // adjust value in case of overflow
        userSummary.ethLocked = uint128(ethLocked);

        userSummaries[user] = userSummary;
    }

    function registerUserPool(uint period, address user, address pool, UserPoolSummary memory userPoolSummary) private {
        address tokenA = address(DelayedExchangePool(pool).tokenA());
        address tokenB = address(DelayedExchangePool(pool).tokenB());
        require(governanceRouter.poolFactory().findPool(tokenA, tokenB) == pool, 
                "LIQUIFY: POOL IS UNKNOWN");

        require(address(governanceRouter.weth()) == tokenA, 
                "LIQUIFY: ETH BASED POOL NEEDED");

        DelayedExchangePool(pool).processDelayedOrders();
        
        PoolSummary memory poolSummary = poolSummaries[pool];
        require(poolSummary.lastPriceRecord != 0, "LIQUIFY: POOL HAS NO PRICES");
        
        userPoolSummary.firstPeriod = uint16(period);
        userPoolSummary.lastPriceRecord = poolSummary.lastPriceRecord;
        userPoolSummary.earnedForPeriod = uint16(period - 1);
        userPools[user].push(pool);

        UserSummary memory userSummary = userSummaries[user];
        if (userSummary.firstPeriod == 0) {
            userSummary.firstPeriod = uint16(period);
            userSummaries[user] = userSummary;
            users.push(user);
        }
    }

    function updateAmountLocked(address user, address pool, uint128 amount, bool positiveAmount) private returns (uint ethLocked, uint mintedAmount) {
        (uint period, uint quantaElapsed) = effectivePeriod(block.timestamp);

        UserPoolSummary memory userPoolSummary = userPoolsSummaries[user][pool];
        if (userPoolSummary.firstPeriod == 0) { // pool is not registered for this user
            registerUserPool(period, user, pool, userPoolSummary);
        } else {
            (ethLocked, mintedAmount) = _actualizeUserPool(period - 1, user, pool, userPoolSummary);
        }
        
        uint quantaElapsedSinceLastUpdate = quantaElapsed - userPoolSummary.amountChangeQuantaElapsed;
        uint lastAmountLocked = userPoolSummary.lastAmountLocked;
        userPoolSummary.cumulativeAmountLocked = uint144(userPoolSummary.cumulativeAmountLocked + lastAmountLocked * quantaElapsedSinceLastUpdate); // no overflow here

        userPoolSummary.amountChangeQuantaElapsed = uint16(quantaElapsed);
        if (positiveAmount) {
            lastAmountLocked = lastAmountLocked.add(amount);
            require(lastAmountLocked < (1<<128), "LIQUIFY: GOV DEPOSIT OVERFLOW");
        } else {
            require(lastAmountLocked > amount, "LIQUIFY: GOV WITHDRAW UNDERFLOW");
            lastAmountLocked = lastAmountLocked - amount;
        }
        
        userPoolSummary.lastAmountLocked = uint128(lastAmountLocked);
        userPoolsSummaries[user][pool] = userPoolSummary;
    }
}