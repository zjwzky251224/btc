// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IFeed} from "../risk/CollateralOracle.sol";

contract MockFeed is IFeed, Ownable {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    constructor(address owner_, uint8 decimals_, int256 answer_) Ownable(owner_) { decimals = decimals_; answer = answer_; startedAt = block.timestamp; updatedAt = block.timestamp; }
    function set(int256 answer_, uint256 started_, uint256 updated_) external onlyOwner { answer = answer_; startedAt = started_; updatedAt = updated_; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) { return (1, answer, startedAt, updatedAt, 1); }
}
