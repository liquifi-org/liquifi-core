// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import {ActivityMeter} from "./ActivityMeter.sol";
import {ActivityReporter} from "./ActivityReporter.sol";
import {Minter} from "./Minter.sol";
import {PoolFactory} from "./PoolFactory.sol";
import {WETH} from "./WETH.sol";
import {ERC20} from "./ERC20.sol";

interface GovernanceRouter {
    event GovernanceApplied(uint256 packedGovernance);
    event GovernorChanged(address covernor);
    event ProtocolFeeReceiverChanged(address protocolFeeReceiver);
    event PoolFactoryChanged(address poolFactory);

    function schedule() external returns (uint256 timeZero, uint256 miningPeriod);

    function creator() external returns (address);

    function weth() external returns (WETH);

    function activityMeter() external returns (ActivityMeter);

    function setActivityMeter(ActivityMeter _activityMeter) external;

    function activityReporter() external returns (ActivityReporter);

    function setActivityReporter(ActivityReporter _activityReporter) external;

    function minter() external returns (Minter);

    function setMinter(Minter _minter) external;

    function poolFactory() external returns (PoolFactory);

    function setPoolFactory(PoolFactory _poolFactory) external;

    function protocolFeeReceiver() external returns (address);

    function setProtocolFeeReceiver(address _protocolFeeReceiver) external;

    function governance() external view returns (address _governor, uint96 _defaultGovernancePacked);

    function setGovernor(address _governor) external;

    function applyGovernance(uint96 _defaultGovernancePacked) external;
}
