// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;
import {GovernanceRouter} from "./GovernanceRouter.sol";

interface ActivityMeter {
    event Deposit(address indexed user, address indexed pool, uint256 amount);
    event Withdraw(address indexed user, address indexed pool, uint256 amount);

    function actualizeUserPool(
        uint256 endPeriod,
        address user,
        address pool
    ) external returns (uint256 ethLocked, uint256 mintedAmount);

    function deposit(address pool, uint128 amount) external returns (uint256 ethLocked, uint256 mintedAmount);

    function withdraw(address pool, uint128 amount) external returns (uint256 ethLocked, uint256 mintedAmount);

    function actualizeUserPools() external returns (uint256 ethLocked, uint256 mintedAmount);

    function liquidityEthPriceChanged(
        address pool,
        uint256 effectiveTime,
        uint256 availableBalanceEth,
        uint256 totalSupply
    ) external;

    function effectivePeriod(uint256 effectiveTime) external view returns (uint256 periodNumber, uint256 quantaElapsed);

    function userEthLocked(address user)
        external
        view
        returns (
            uint256 ethLockedPeriod,
            uint256 ethLocked,
            uint256 totalEthLocked
        );

    function ethLockedHistory(uint256 period) external view returns (uint256 ethLockedTotal);

    function poolsPriceHistory(uint256 period, address pool)
        external
        view
        returns (
            uint256 cumulativeEthPrice,
            uint240 lastEthPrice,
            uint16 timeRef
        );

    function userPoolsSummaries(address user, address pool)
        external
        view
        returns (
            uint144 cumulativeAmountLocked,
            uint16 amountChangeQuantaElapsed,
            uint128 lastAmountLocked,
            uint16 firstPeriod,
            uint16 lastPriceRecord,
            uint16 earnedForPeriod
        );

    function userPools(address user, uint256 poolIndex) external view returns (address pool);

    function userPoolsLength(address user) external view returns (uint256 length);

    function userSummaries(address user)
        external
        view
        returns (
            uint128 ethLocked,
            uint16 ethLockedPeriod,
            uint16 firstPeriod
        );

    function poolSummaries(address pool) external view returns (uint16 lastPriceRecord);

    function users(uint256 userIndex) external view returns (address user);

    function usersLength() external view returns (uint256);
}
