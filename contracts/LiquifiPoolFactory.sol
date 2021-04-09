// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.6;

import { GovernanceRouter } from "./interfaces/GovernanceRouter.sol";
import { PoolFactory } from "./interfaces/PoolFactory.sol";
import { LiquifiDelayedExchangePool } from "./LiquifiDelayedExchangePool.sol";

contract LiquifiPoolFactory is PoolFactory {
    address private immutable weth;
    address private immutable governanceRouter;
    
    mapping(address => mapping(address => address)) private poolMap;
    address[] public override pools;

    constructor(address _governanceRouter) public {
        governanceRouter = _governanceRouter;
        weth = address(GovernanceRouter(_governanceRouter).weth());
        if (address(GovernanceRouter(_governanceRouter).poolFactory()) == address(0)) {
            GovernanceRouter(_governanceRouter).setPoolFactory(this);
        }
    }

    function getPool(address token1, address token2) external override returns (address pool) {
        address _weth = weth;
        if ((token1 == _weth ? address(0) : token1) > (token2 == _weth ? address(0) : token2)) {
            (token2, token1) = (token1, token2); // ensure that weth cannot become tokenB
        }

        bool aIsWETH = token1 == _weth;
        pool = poolMap[token1][token2];
        if (pool == address(0)) {
            pool = address(new LiquifiDelayedExchangePool{ /* make pool address deterministic */ salt: bytes32(uint(1))}(
                token1, token2, aIsWETH, governanceRouter, pools.length
            ));
            pools.push(pool);
            poolMap[token1][token2] = pool;
            poolMap[token2][token1] = pool;
            emit PoolCreatedEvent(token1, token2, aIsWETH, pool);
        }
    }

    function findPool(address token1, address token2) external override view returns (address pool) {
        return poolMap[token1][token2];
    }

    function getPoolCount() external override view returns (uint) {
        return pools.length;
    }
}