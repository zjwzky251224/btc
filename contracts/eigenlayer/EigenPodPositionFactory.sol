// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EigenPodPosition} from "./EigenPodPosition.sol";

/// @notice Native restaking admission is off until an owner/timelock explicitly enables it.
contract EigenPodPositionFactory is Ownable {
    address public immutable podManager;
    address public immutable delegationManager;
    bool public enabled;
    mapping(address => bool) public operators;
    mapping(address => bool) public isPosition;
    event PositionCreated(address indexed beneficiary, address indexed position, address operator);
    constructor(address owner_, address podManager_, address delegation_) Ownable(owner_) {
        require(podManager_.code.length > 0 && delegation_.code.length > 0, "FACTORY_CONFIG"); podManager = podManager_; delegationManager = delegation_;
    }
    function setEnabled(bool enabled_) external onlyOwner { enabled = enabled_; }
    function setOperator(address operator, bool allowed) external onlyOwner { require(operator != address(0), "ZERO_OPERATOR"); operators[operator] = allowed; }
    function create(address operator, uint256 checkpointAge) external returns (address position) {
        require(enabled && operators[operator], "NATIVE_RESTAKING_DISABLED");
        position = address(new EigenPodPosition(msg.sender, podManager, delegationManager, operator, checkpointAge));
        isPosition[position] = true; emit PositionCreated(msg.sender, position, operator);
    }
}
