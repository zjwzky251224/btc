// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Protocol, IMessenger, IMessageReceiver} from "../interfaces/Protocol.sol";

/// @notice Fee-funded dispatch is independent of business state transitions.
abstract contract MessageApp is Ownable, ReentrancyGuard, IMessageReceiver {
    IMessenger public immutable messenger;
    uint64 public immutable localDomain;
    uint64 public peerDomain;
    address public peer;
    uint256 public outboxCount;
    mapping(uint256 => bytes) public outbox;
    event Queued(uint256 indexed index, bytes32 indexed operationId, Protocol.Kind kind);
    event Dispatched(uint256 indexed index, bytes32 transportId);
    error UnauthorizedPeer();
    error InvalidConfiguration();

    constructor(address owner_, address messenger_, uint64 localDomain_) Ownable(owner_) {
        if (messenger_.code.length == 0 || localDomain_ == 0) revert InvalidConfiguration();
        messenger = IMessenger(messenger_);
        localDomain = localDomain_;
    }

    function configurePeer(uint64 domain_, address peer_) external onlyOwner {
        if (peer != address(0) || peer_ == address(0) || domain_ == 0 || domain_ == localDomain) revert InvalidConfiguration();
        peerDomain = domain_;
        peer = peer_;
    }

    /// @dev Re-dispatching uses the same business ID; receivers must be idempotent.
    function dispatch(uint256 index) external payable nonReentrant returns (bytes32 id) {
        bytes memory data = outbox[index];
        if (data.length == 0 || peer == address(0)) revert InvalidConfiguration();
        id = messenger.send{value: msg.value}(peerDomain, peer, data);
        emit Dispatched(index, id);
    }

    function onMessage(uint64 source, address sender, bytes calldata payload) external nonReentrant {
        if (msg.sender != address(messenger) || peer == address(0) || source != peerDomain || sender != peer) revert UnauthorizedPeer();
        Protocol.Message memory message = abi.decode(payload, (Protocol.Message));
        if (message.domain != Protocol.DOMAIN) revert UnauthorizedPeer();
        _receiveMessage(message);
    }

    function _queue(Protocol.Message memory message) internal {
        message.domain = Protocol.DOMAIN;
        uint256 index = ++outboxCount;
        outbox[index] = abi.encode(message);
        emit Queued(index, message.id, message.kind);
    }
    function _receiveMessage(Protocol.Message memory message) internal virtual;
}
