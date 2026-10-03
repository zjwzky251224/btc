// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library Protocol {
    bytes32 internal constant DOMAIN = keccak256("OMNICHAIN_LENDING_V1");
    enum Kind { Prepare, Commit, Executed, CancelRequest, Cancelled, Settled, Rebalanced, Loss, Utilization }
    struct Message {
        bytes32 domain;
        Kind kind;
        bytes32 id;
        address borrower;
        address receiver;
        uint256 amount;
        uint64 deadline;
        uint64 sequence;
        uint256 auxiliary;
    }
}

interface IMessenger {
    function send(uint64 destination, address receiver, bytes calldata payload) external payable returns (bytes32);
}
interface IMessageReceiver {
    function onMessage(uint64 source, address sender, bytes calldata payload) external;
}
interface ICollateralOracle { function value(uint256 collateralUnits) external view returns (uint256 usdcUnits); }
interface IShareConverter { function convertToAssets(uint256 shares) external view returns (uint256); }
interface IPositionValue { function backingAssets() external view returns (uint256); }
interface IWrappedNative {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}
interface INativePosition {
    function requestExits(bytes[] calldata pubkeys) external payable;
    function startCheckpoint(bool revertIfNoBalance) external;
}
interface IPositionRisk { function fixedOperator() external view returns (address); }
