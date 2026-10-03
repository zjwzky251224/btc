// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICollateralOracle, IShareConverter, IPositionValue} from "../interfaces/Protocol.sol";

interface IFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Mode 0: ERC20 units; 1: convertible shares; 2: indivisible EigenPod position.
contract CollateralOracle is ICollateralOracle {
    IFeed public immutable collateralUsd;
    IFeed public immutable usdcUsd;
    address public immutable converter;
    uint8 public immutable mode;
    uint256 public immutable assetUnit;
    uint256 public immutable maxAge;
    uint256 public immutable recoveryBps;
    error InvalidPrice();

    constructor(address assetFeed, address debtFeed, uint8 decimals_, uint256 maxAge_,
        uint256 recoveryBps_, uint8 mode_, address converter_) {
        require(decimals_ <= 36 && maxAge_ > 0 && recoveryBps_ > 0 && recoveryBps_ <= 10000 && mode_ <= 2, "ORACLE_CONFIG");
        require(assetFeed.code.length > 0 && debtFeed.code.length > 0 && (mode_ == 0 || converter_.code.length > 0), "ORACLE_CODE");
        collateralUsd = IFeed(assetFeed); usdcUsd = IFeed(debtFeed);
        assetUnit = 10 ** decimals_; maxAge = maxAge_; recoveryBps = recoveryBps_;
        mode = mode_; converter = converter_;
    }
    function _price(IFeed feed) private view returns (uint256) {
        (, int256 answer,, uint256 updated,) = feed.latestRoundData();
        uint8 decimals_ = feed.decimals();
        if (answer <= 0 || updated == 0 || updated > block.timestamp || block.timestamp - updated > maxAge || decimals_ > 18) revert InvalidPrice();
        return uint256(answer) * 10 ** (18 - decimals_);
    }
    function value(uint256 units) external view returns (uint256) {
        uint256 assets = units;
        if (mode == 1) assets = IShareConverter(converter).convertToAssets(units);
        if (mode == 2) assets = Math.mulDiv(IPositionValue(converter).backingAssets(), units, 1e18);
        uint256 usd = Math.mulDiv(assets, _price(collateralUsd), assetUnit);
        uint256 usdc = Math.mulDiv(usd, 1e6, _price(usdcUsd));
        return Math.mulDiv(usdc, recoveryBps, 10000);
    }
}
