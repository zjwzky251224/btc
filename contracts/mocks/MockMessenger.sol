// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMessenger, IMessageReceiver} from "../interfaces/Protocol.sol";

/// @dev TEST ONLY: trusted relayer can deliver arbitrary messages; not a bridge proof system.
contract MockMessenger is Ownable, IMessenger {
    struct Packet { uint64 source; uint64 destination; address sender; address receiver; bytes payload; }
    uint64 public immutable domain;
    uint256 public count;
    mapping(uint256 => Packet) private packets;
    constructor(address owner_, uint64 domain_) Ownable(owner_) { domain = domain_; }
    function send(uint64 destination, address receiver, bytes calldata payload) external payable returns (bytes32) {
        uint256 id = ++count; packets[id] = Packet(domain, destination, msg.sender, receiver, payload); return bytes32(id);
    }
    function packet(uint256 id) external view returns (Packet memory) { return packets[id]; }
    function deliver(uint64 source, address sender, address receiver, bytes calldata payload) external onlyOwner {
        IMessageReceiver(receiver).onMessage(source, sender, payload);
    }
}
