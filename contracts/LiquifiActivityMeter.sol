// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import {ActivityMeter} from "./interfaces/ActivityMeter.sol";
import {Minter} from "./interfaces/Minter.sol";
import {Math} from "./libraries/Math.sol";
import {DelayedExchangePool} from "./interfaces/DelayedExchangePool.sol";

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
        uint256 cumulativeEthPrice;
        uint240 lastEthPrice;
        uint16 timeRef; // for last period - contains time quanta since period start; for historic periods contains next record number
    }

    address private immutable minter;
    uint256 private immutable timeZero;
    uint256 private immutable miningPeriod;

    /*period*/
    /*ethLockedTotal premultiplied on 2 ** 112 */
    mapping(uint256 => uint256) public override ethLockedHistory;
    /*period*/
    /*pool*/
    mapping(uint256 => mapping(address => PoolPriceRecord)) public override poolsPriceHistory;
    /*user*/
    /*pool*/
    mapping(address => mapping(address => UserPoolSummary)) public override userPoolsSummaries;

    /*user*/
    /*pool*/
    mapping(address => address[]) public override userPools;

    function userPoolsLength(address user) external view override returns (uint256) {
        return userPools[user].length;
    }

    /*user*/
    mapping(address => UserSummary) public override userSummaries;
    /*pool*/
    mapping(address => PoolSummary) public override poolSummaries;

    address[] public override users;

    uint public counter; //FIXME: delete

    function usersLength() external view override returns (uint256) {
        return users.length;
    }

    constructor(address _minter, uint256 _miningPeriod) {
        timeZero = block.timestamp;
        miningPeriod = _miningPeriod;
        minter = _minter;
    }

    function effectivePeriod(uint256 effectiveTime)
        public
        view
        override
        returns (uint256 periodNumber, uint256 quantaElapsed)
    {
        uint256 _miningPeriod = miningPeriod;
        uint256 _timeZero = timeZero;
        require(effectiveTime > _timeZero, "LIQUIFI METER: prehistoric time");
        uint256 timeElapsed = effectiveTime - _timeZero;
        periodNumber = 1 + (timeElapsed / _miningPeriod); // periods have numbers starting with 1
        quantaElapsed = ((timeElapsed % _miningPeriod) << 16) / _miningPeriod; // time elapsed in period measured in quantas: 1/2**16 parts of period
    }

    function actualizeUserPool(
        uint256 endPeriod,
        address user,
        address pool
    ) external override returns (uint256 ethLocked, uint256 mintedAmount) {
        (uint256 currentPeriod, ) = effectivePeriod(block.timestamp);
        require(endPeriod < currentPeriod, "LIQUIFY: BAD EARNING PERIOD");
        UserPoolSummary memory userPoolSummary = userPoolsSummaries[user][pool];
        require(userPoolSummary.firstPeriod != 0, "LIQUIFY: NO USER POOL");
        (ethLocked, mintedAmount) = _actualizeUserPool(endPeriod, user, pool, userPoolSummary);
        userPoolsSummaries[user][pool] = userPoolSummary;
    }

    function deposit(address pool, uint128 amount) external override returns (uint256 ethLocked, uint256 mintedAmount) {
        address user = msg.sender; // this method should be called by the user
        (ethLocked, mintedAmount) = updateAmountLocked(user, pool, amount, true);
        emit Deposit(user, pool, amount);
        require(DelayedExchangePool(pool).transferFrom(user, address(this), amount), "LIQUIFY: TRANSFER FROM FAILED");
    }

    function withdraw(address pool, uint128 amount)
        external
        override
        returns (uint256 ethLocked, uint256 mintedAmount)
    {
        address user = msg.sender; // this method should be called by the user
        (ethLocked, mintedAmount) = updateAmountLocked(user, pool, amount, false);
        emit Withdraw(user, pool, amount);
        require(DelayedExchangePool(pool).transfer(user, amount), "LIQUIFY: TRANSFER FAILED");
    }

    // for brave users having few pools and actualized recently
    // others could run out of gas
    function actualizeUserPools() external override returns (uint256 ethLocked, uint256 mintedAmount) {
        address user = msg.sender;

        (uint256 currentPeriod, ) = effectivePeriod(block.timestamp);
        uint256 userPoolIndex = userPools[user].length;

        while (userPoolIndex > 0) {
            userPoolIndex--;
            address pool = userPools[user][userPoolIndex];
            UserPoolSummary memory userPoolSummary = userPoolsSummaries[user][pool];
            (uint256 poolEthLocked, uint256 _mintedAmount) =
                _actualizeUserPool(currentPeriod - 1, user, pool, userPoolSummary);
            userPoolsSummaries[user][pool] = userPoolSummary;
            ethLocked = Math.addWithClip(ethLocked, poolEthLocked, ~uint256(0));
            mintedAmount = _mintedAmount > 0 ? _mintedAmount : mintedAmount;
        }
    }

    function liquidityEthPriceChanged(
        address pool,
        uint256 effectiveTime,
        uint256 availableBalanceEth,
        uint256 totalSupply
    ) external override {
        // we don't care if someone pretending to be our pool will spend some gas on price reporting:
        // this price will be just never used
        if (totalSupply == 0 || availableBalanceEth == 0) {
            // should never happen, just in case
            return;
        }

        // next effectiveTime is never less than previous one in our pools
        (uint256 period, uint256 quantaElapsed) = effectivePeriod(effectiveTime);
        PoolPriceRecord storage priceRecord = poolsPriceHistory[period][pool];
        (uint256 lastEthPrice, uint256 timeRef) = (priceRecord.lastEthPrice, priceRecord.timeRef);
        uint256 cumulativeEthPrice;
        if (lastEthPrice == 0) {
            // no price record for this period
            PoolSummary memory poolSummary = poolSummaries[pool];
            if (poolSummary.lastPriceRecord != 0) {
                PoolPriceRecord memory prevPriceRecord = poolsPriceHistory[poolSummary.lastPriceRecord][pool];
                lastEthPrice = prevPriceRecord.lastEthPrice;
                cumulativeEthPrice = lastEthPrice * quantaElapsed;
                prevPriceRecord.cumulativeEthPrice =
                    prevPriceRecord.cumulativeEthPrice +
                    lastEthPrice *
                    ((1 << 16) - prevPriceRecord.timeRef);
                prevPriceRecord.timeRef = uint16(period);
                poolsPriceHistory[poolSummary.lastPriceRecord][pool] = prevPriceRecord;
            }
            poolSummary.lastPriceRecord = uint16(period);
            poolSummaries[pool] = poolSummary;
        } else {
            uint256 quantaElapsedSinceLastUpdate = quantaElapsed - timeRef;
            cumulativeEthPrice = priceRecord.cumulativeEthPrice + lastEthPrice * quantaElapsedSinceLastUpdate;
        }

        priceRecord.cumulativeEthPrice = cumulativeEthPrice;
        uint256 currentPrice = (totalSupply << 112) / availableBalanceEth;
        (priceRecord.lastEthPrice, priceRecord.timeRef) = (uint240(currentPrice), uint16(quantaElapsed));
        counter++;
    }

    function userEthLocked(address user)
        external
        view
        override
        returns (
            uint256 ethLockedPeriod,
            uint256 ethLocked,
            uint256 totalEthLocked
        )
    {
        (uint256 currentPeriod, ) = effectivePeriod(block.timestamp);
        uint256 currentEthLockedPeriod = currentPeriod - 1;
        UserSummary memory userSummary = userSummaries[user];
        if (currentEthLockedPeriod > 0 && userSummary.ethLockedPeriod < currentEthLockedPeriod) {
            if (userSummary.ethLockedPeriod > 0) {
                ethLockedPeriod = userSummary.ethLockedPeriod;
                ethLocked = userSummary.ethLocked;
                totalEthLocked = ethLockedHistory[userSummary.ethLockedPeriod];
            }
        }
    }

    function _actualizeUserPool(
        uint256 period,
        address user,
        address pool,
        UserPoolSummary memory userPoolSummary
    ) private returns (uint256 ethLocked, uint256 mintedAmount) {
        UserSummary memory userSummary = userSummaries[user];
        uint256 currentEthLockedPeriod;
        {
            (uint256 currentPeriod, ) = effectivePeriod(block.timestamp);
            currentEthLockedPeriod = currentPeriod - 1;
        }

        if (currentEthLockedPeriod > 0 && userSummary.ethLockedPeriod < currentEthLockedPeriod) {
            if (userSummary.ethLockedPeriod > 0) {
                mintedAmount = Minter(minter).mint(
                    user,
                    userSummary.ethLockedPeriod,
                    userSummary.ethLocked,
                    ethLockedHistory[userSummary.ethLockedPeriod]
                );
            }
            userSummary.ethLocked = 0;
            userSummary.ethLockedPeriod = uint16(currentEthLockedPeriod);
            userSummaries[user] = userSummary;
        }
        uint256 earningPeriod = userPoolSummary.earnedForPeriod;
        if (earningPeriod >= period) {
            return (0, mintedAmount);
        }
        // currentPeriod >= 2 at this line
        // currentEthLockedPeriod >= 1

        // 02.03.2020
        // Uncomment delayed orders  processing after migrating pool logic to OPTIMISM L2
        //DelayedExchangePool(pool).processDelayedOrders();

        PoolSummary memory poolSummary = poolSummaries[pool];
        PoolPriceRecord memory poolPriceRecord = poolsPriceHistory[userPoolSummary.lastPriceRecord][pool];
        while ((++earningPeriod) <= period) {
            // if there is a newer price record and current one is obsolete and it doesn't refer to itself
            if (
                earningPeriod <= poolSummary.lastPriceRecord &&
                poolPriceRecord.timeRef == earningPeriod &&
                earningPeriod > userPoolSummary.lastPriceRecord
            ) {
                // switch to next price record
                userPoolSummary.lastPriceRecord = uint16(earningPeriod);
                poolPriceRecord = poolsPriceHistory[earningPeriod][pool];
            }

            uint256 cumulativeEthPrice = poolPriceRecord.cumulativeEthPrice;
            if (earningPeriod == poolSummary.lastPriceRecord) {
                cumulativeEthPrice += uint256(poolPriceRecord.lastEthPrice) * ((1 << 16) - poolPriceRecord.timeRef); // no overflow here
            } else if (earningPeriod > userPoolSummary.lastPriceRecord) {
                // amount record is not related to current period
                cumulativeEthPrice = uint256(poolPriceRecord.lastEthPrice) << 16;
            }

            uint256 cumulativeAmountLocked = userPoolSummary.cumulativeAmountLocked;
            if (cumulativeAmountLocked > 0 || userPoolSummary.amountChangeQuantaElapsed > 0) {
                cumulativeAmountLocked +=
                    uint256(userPoolSummary.lastAmountLocked) *
                    ((1 << 16) - userPoolSummary.amountChangeQuantaElapsed); // no overflow here
                userPoolSummary.cumulativeAmountLocked = 0;
                userPoolSummary.amountChangeQuantaElapsed = 0;
            } else {
                cumulativeAmountLocked = uint256(userPoolSummary.lastAmountLocked) << 16;
            }

            if (cumulativeEthPrice != 0 && cumulativeAmountLocked != 0) {
                cumulativeAmountLocked = cumulativeAmountLocked.mulWithClip(2**112, ~uint256(0));
                ethLocked = Math.addWithClip(ethLocked, cumulativeAmountLocked / cumulativeEthPrice, ~uint128(0));
            }
        }

        userPoolSummary.earnedForPeriod = uint16(period);

        uint256 ethLockedTotal = ethLockedHistory[currentEthLockedPeriod];
        uint256 ethLockedTotalNew = Math.addWithClip(ethLockedTotal, ethLocked, ~uint256(0));
        ethLockedHistory[currentEthLockedPeriod] = ethLockedTotalNew;
        ethLocked = Math.addWithClip(userSummary.ethLocked, ethLockedTotalNew - ethLockedTotal, ~uint128(0)); // adjust value in case of overflow
        userSummary.ethLocked = uint128(ethLocked);

        userSummaries[user] = userSummary;
    }

    function registerUserPool(
        uint256 period,
        address user,
        address pool,
        UserPoolSummary memory userPoolSummary
    ) private {
        // 03.03.2020
        // Pool verification and delayed order processing are moved to Activity Reporter

        // address tokenA = address(DelayedExchangePool(pool).tokenA());
        // address tokenB = address(DelayedExchangePool(pool).tokenB());
        // require(governanceRouter.poolFactory().findPool(tokenA, tokenB) == pool,
        //         "LIQUIFY: POOL IS UNKNOWN");

        // require(address(governanceRouter.weth()) == tokenA,
        //         "LIQUIFY: ETH BASED POOL NEEDED");

        // DelayedExchangePool(pool).processDelayedOrders();

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

    function updateAmountLocked(
        address user,
        address pool,
        uint128 amount,
        bool positiveAmount
    ) private returns (uint256 ethLocked, uint256 mintedAmount) {
        (uint256 period, uint256 quantaElapsed) = effectivePeriod(block.timestamp);

        UserPoolSummary memory userPoolSummary = userPoolsSummaries[user][pool];
        if (userPoolSummary.firstPeriod == 0) {
            // pool is not registered for this user
            registerUserPool(period, user, pool, userPoolSummary);
        } else {
            (ethLocked, mintedAmount) = _actualizeUserPool(period - 1, user, pool, userPoolSummary);
        }

        uint256 quantaElapsedSinceLastUpdate = quantaElapsed - userPoolSummary.amountChangeQuantaElapsed;
        uint256 lastAmountLocked = userPoolSummary.lastAmountLocked;
        userPoolSummary.cumulativeAmountLocked = uint144(
            userPoolSummary.cumulativeAmountLocked + lastAmountLocked * quantaElapsedSinceLastUpdate
        ); // no overflow here

        userPoolSummary.amountChangeQuantaElapsed = uint16(quantaElapsed);
        if (positiveAmount) {
            lastAmountLocked = lastAmountLocked.add(amount);
            require(lastAmountLocked < (1 << 128), "LIQUIFY: GOV DEPOSIT OVERFLOW");
        } else {
            require(lastAmountLocked >= amount, "LIQUIFY: GOV WITHDRAW UNDERFLOW");
            lastAmountLocked = lastAmountLocked - amount;
        }

        userPoolSummary.lastAmountLocked = uint128(lastAmountLocked);
        userPoolsSummaries[user][pool] = userPoolSummary;
    }
}
