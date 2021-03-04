// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.8.0;

import "@eth-optimism/contracts/build/contracts/iOVM/bridge/iOVM_BaseCrossDomainMessenger.sol";

contract TestMessenger is iOVM_BaseCrossDomainMessenger {
    address public override xDomainMessageSender;

    function sendMessage(
        address _target,
        bytes memory _message,
        uint32 _gasLimit
    ) public override {
        emit SentMessage(_message);
    }
}
