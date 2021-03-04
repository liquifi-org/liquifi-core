// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import {GovernanceRouter} from "../interfaces/GovernanceRouter.sol";
import {LiquifiInitialGovernor} from "../LiquifiInitialGovernor.sol";
import {PoolFactory} from "../interfaces/PoolFactory.sol";
import {DelayedExchangePool} from "../interfaces/DelayedExchangePool.sol";
import {Liquifi} from "../libraries/Liquifi.sol";

contract TestGovernor is LiquifiInitialGovernor {
    constructor(address _governanceRouter) LiquifiInitialGovernor(_governanceRouter, 100 * (10**18), 1) {}

    function lockPoolTest(address pool) external {
        lockPool(pool);
    }

    function setProtocolFee(address pool, uint8 fee) external {
        (, uint256 governancePacked) = governanceRouter.governance();

        governancePacked = (governancePacked & ~uint96(uint256(~uint8(0)) << 72)) | (uint256(fee) << 72);
        governancePacked = governancePacked | (1 << uint256(Liquifi.Flag.GOVERNANCE_OVERRIDEN));
        DelayedExchangePool(pool).applyGovernance(governancePacked);
        governanceRouter.setProtocolFeeReceiver(address(this));
    }

    function setDesiredMaxHistory(address pool, uint256 maxHistory) external {
        (, uint256 governancePacked) = governanceRouter.governance();

        governancePacked = (governancePacked & ~uint96(uint256(~uint16(0)) << 24)) | (uint256(maxHistory) << 24);
        governancePacked = governancePacked | (1 << uint256(Liquifi.Flag.GOVERNANCE_OVERRIDEN));
        DelayedExchangePool(pool).applyGovernance(governancePacked);
        governanceRouter.setProtocolFeeReceiver(address(this));
    }

    function setFee(address pool, uint256 fee) external {
        (, uint256 governancePacked) = governanceRouter.governance();

        governancePacked = (governancePacked & ~uint96(uint256(~uint8(0)) << 80)) | (uint256(fee) << 80);
        governancePacked = governancePacked | (1 << uint256(Liquifi.Flag.GOVERNANCE_OVERRIDEN));
        DelayedExchangePool(pool).applyGovernance(governancePacked);
        governanceRouter.setProtocolFeeReceiver(address(this));
    }

    function setInstantSwapFee(address pool, uint256 fee) external {
        (, uint256 governancePacked) = governanceRouter.governance();

        governancePacked = (governancePacked & ~uint96(uint256(~uint8(0)) << 88)) | (uint256(fee) << 88);
        governancePacked = governancePacked | (1 << uint256(Liquifi.Flag.GOVERNANCE_OVERRIDEN));
        DelayedExchangePool(pool).applyGovernance(governancePacked);
        governanceRouter.setProtocolFeeReceiver(address(this));
    }
}
