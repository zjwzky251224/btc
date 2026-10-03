// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

/// @dev TEST ONLY: does not implement verifier attestations or real CCIP finality.
contract MockCCIPRouter is Ownable {
    uint256 public constant fee = 1e12;
    uint256 public count;
    event MessageSent(bytes32 id, address sender, uint64 destination, bytes receiver, bytes data);
    constructor(address owner_) Ownable(owner_) {}
    function getFee(uint64, Client.EVM2AnyMessage calldata) external pure returns (uint256) { return fee; }
    function isChainSupported(uint64 domain) external pure returns (bool) { return domain != 0; }
    function ccipSend(uint64 destination, Client.EVM2AnyMessage calldata message) external payable returns (bytes32 id) {
        require(msg.value == fee, "FEE"); id = bytes32(++count); emit MessageSent(id, msg.sender, destination, message.receiver, message.data);
    }
    function deliver(address receiver, Client.Any2EVMMessage calldata message) external onlyOwner { IAny2EVMMessageReceiver(receiver).ccipReceive(message); }
}
