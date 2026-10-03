// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {IMessenger, IMessageReceiver} from "../interfaces/Protocol.sol";

/// @notice Data-only integration pinned to CCIP 2.0.0. No user-controlled finality.
contract CCIPGateway is CCIPReceiver, Ownable, ReentrancyGuard, IMessenger {
    uint256 public immutable callbackGas;
    address public app;
    uint64 public remoteDomain;
    address public remoteGateway;
    address public remoteApp;
    address[] private requiredVerifiers;

    constructor(address owner_, address router_, uint256 callbackGas_) CCIPReceiver(router_) Ownable(owner_) {
        require(router_.code.length > 0 && callbackGas_ >= 200000 && callbackGas_ <= 2000000, "CCIP_CONFIG"); callbackGas = callbackGas_;
    }
    function bind(address app_, uint64 remoteDomain_, address remoteGateway_, address remoteApp_, address[] calldata verifiers) external onlyOwner {
        require(app == address(0) && app_.code.length > 0 && remoteDomain_ != 0 && remoteGateway_ != address(0) && remoteApp_ != address(0), "ALREADY_BOUND");
        for (uint256 i; i < verifiers.length; ++i) {
            require(verifiers[i] != address(0) && (i == 0 || verifiers[i] > verifiers[i-1]), "VERIFIER_CONFIG"); requiredVerifiers.push(verifiers[i]);
        }
        app = app_; remoteDomain = remoteDomain_; remoteGateway = remoteGateway_; remoteApp = remoteApp_;
    }
    function _message(bytes memory payload) private view returns (Client.EVM2AnyMessage memory) {
        return Client.EVM2AnyMessage({ receiver: abi.encode(remoteGateway), data: abi.encode(app, payload),
            tokenAmounts: new Client.EVMTokenAmount[](0), feeToken: address(0),
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: callbackGas, allowOutOfOrderExecution: true})) });
    }
    function quote(bytes calldata payload) external view returns (uint256) { require(app != address(0), "NOT_BOUND"); return IRouterClient(getRouter()).getFee(remoteDomain, _message(payload)); }
    function send(uint64 destination, address receiver, bytes calldata payload) external payable nonReentrant returns (bytes32) {
        require(msg.sender == app && destination == remoteDomain && receiver == remoteApp, "CCIP_ROUTE");
        Client.EVM2AnyMessage memory message = _message(payload);
        uint256 fee = IRouterClient(getRouter()).getFee(destination, message); require(msg.value == fee, "EXACT_FEE_REQUIRED");
        return IRouterClient(getRouter()).ccipSend{value: fee}(destination, message);
    }
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override nonReentrant {
        require(app != address(0) && message.sourceChainSelector == remoteDomain && message.sender.length == 32
            && abi.decode(message.sender, (address)) == remoteGateway && message.destTokenAmounts.length == 0, "CCIP_ORIGIN");
        (address sender, bytes memory payload) = abi.decode(message.data, (address, bytes)); require(sender == remoteApp, "CCIP_APPLICATION");
        IMessageReceiver(app).onMessage(remoteDomain, sender, payload);
    }
    function getCCVsAndFinalityConfig(uint64 source, bytes calldata) external view override
        returns (address[] memory requiredCCVs, address[] memory optionalCCVs, uint8 optionalThreshold, bytes4 allowedFinalityConfig) {
        require(source == remoteDomain && app != address(0), "CCIP_ROUTE");
        return (requiredVerifiers, new address[](0), 0, FinalityCodec.WAIT_FOR_FINALITY_FLAG);
    }
}
