// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library InterestMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    function grow(uint256 index, uint256 annualRate, uint256 elapsed) internal pure returns (uint256) {
        uint256 base = WAD + Math.ceilDiv(annualRate, YEAR);
        uint256 factor = WAD;
        while (elapsed != 0) {
            if (elapsed & 1 != 0) factor = Math.mulDiv(factor, base, WAD, Math.Rounding.Ceil);
            elapsed >>= 1;
            if (elapsed != 0) base = Math.mulDiv(base, base, WAD, Math.Rounding.Ceil);
        }
        return Math.mulDiv(index, factor, WAD, Math.Rounding.Ceil);
    }
}
