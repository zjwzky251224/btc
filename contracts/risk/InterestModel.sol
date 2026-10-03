// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract InterestModel {
    uint256 public constant WAD = 1e18;
    uint256 public immutable baseRate;
    uint256 public immutable slopeLow;
    uint256 public immutable slopeHigh;
    uint256 public immutable kink;
    uint256 public immutable maxRate;

    constructor(uint256 base_, uint256 low_, uint256 high_, uint256 kink_, uint256 max_) {
        require(kink_ > 0 && kink_ < WAD && base_ <= max_ && max_ <= 5e18, "RATE_CONFIG");
        baseRate = base_; slopeLow = low_; slopeHigh = high_; kink = kink_; maxRate = max_;
    }
    function rate(uint256 utilization) external view returns (uint256) {
        uint256 u = Math.min(utilization, WAD);
        uint256 result = u <= kink ? baseRate + Math.mulDiv(slopeLow, u, kink)
            : baseRate + slopeLow + Math.mulDiv(slopeHigh, u - kink, WAD - kink);
        return Math.min(result, maxRate);
    }
}
