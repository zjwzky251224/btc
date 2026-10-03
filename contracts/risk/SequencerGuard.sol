// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFeed} from "./CollateralOracle.sol";

contract SequencerGuard {
    IFeed public immutable feed;
    uint256 public immutable grace;
    constructor(address feed_, uint256 grace_) { require(feed_.code.length > 0 && grace_ > 0, "GUARD_CONFIG"); feed = IFeed(feed_); grace = grace_; }
    function check() external view {
        (, int256 status, uint256 startedAt,,) = feed.latestRoundData();
        require(status == 0 && startedAt != 0 && startedAt <= block.timestamp && block.timestamp - startedAt > grace, "SEQUENCER_UNAVAILABLE");
    }
}
