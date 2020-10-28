// SPDX-License-Identifier: GPL-3.0
pragma solidity = 0.7.0;

import { GovernanceRouter } from "../interfaces/GovernanceRouter.sol";
import { LiquifiInitialGovernor } from "../LiquifiInitialGovernor.sol";
import { PoolFactory } from "../interfaces/PoolFactory.sol";
import { DelayedExchangePool } from "../interfaces/DelayedExchangePool.sol";
import { Liquifi } from "../libraries/Liquifi.sol";

contract TestGovernor is LiquifiInitialGovernor {
    constructor(address _governanceRouter) public LiquifiInitialGovernor(_governanceRouter, 100 * (10 ** 18), 1) {
        
    }

    function lockPoolTest(address pool) external {
        lockPool(pool);
    }

    function setProtocolFee(address pool, uint8 fee) external {
        (, uint governancePacked) = governanceRouter.governance();

        governancePacked = governancePacked & ~uint96(uint(~uint8(0)) << 72) | (uint(fee) << 72);
        governancePacked = governancePacked | (1 << uint(Liquifi.Flag.GOVERNANCE_OVERRIDEN));
        DelayedExchangePool(pool).applyGovernance(governancePacked);
        governanceRouter.setProtocolFeeReceiver(address(this));
    }

    function setDesiredMaxHistory(address pool, uint maxHistory) external {
        (, uint governancePacked) = governanceRouter.governance();

        governancePacked = governancePacked & ~uint96(uint(~uint16(0)) << 24) | (uint(maxHistory) << 24);
        governancePacked = governancePacked | (1 << uint(Liquifi.Flag.GOVERNANCE_OVERRIDEN));
        DelayedExchangePool(pool).applyGovernance(governancePacked);
        governanceRouter.setProtocolFeeReceiver(address(this));
    }

    function setFee(address pool, uint fee) external {
        (, uint governancePacked) = governanceRouter.governance();

        governancePacked = governancePacked & ~uint96(uint(~uint8(0)) << 80) | (uint(fee) << 80);
        governancePacked = governancePacked | (1 << uint(Liquifi.Flag.GOVERNANCE_OVERRIDEN));
        DelayedExchangePool(pool).applyGovernance(governancePacked);
        governanceRouter.setProtocolFeeReceiver(address(this));
    }

    function setInstantSwapFee(address pool, uint fee) external {
        (, uint governancePacked) = governanceRouter.governance();

        governancePacked = governancePacked & ~uint96(uint(~uint8(0)) << 88) | (uint(fee) << 88);
        governancePacked = governancePacked | (1 << uint(Liquifi.Flag.GOVERNANCE_OVERRIDEN));
        DelayedExchangePool(pool).applyGovernance(governancePacked);
        governanceRouter.setProtocolFeeReceiver(address(this));
    }
}