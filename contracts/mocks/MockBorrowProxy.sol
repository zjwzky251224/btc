// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
interface IRequestPool { function requestBorrow(uint256 amount, address receiver, uint64 deadline) external returns (bytes32); }
contract MockBorrowProxy {
    function request(address pool, uint256 amount, address receiver, uint64 deadline) external {
        IRequestPool(pool).requestBorrow(amount, receiver, deadline);
    }
}
contract MockConstructorBorrower {
    constructor(address pool, uint256 amount, address receiver, uint64 deadline) {
        IRequestPool(pool).requestBorrow(amount, receiver, deadline);
    }
}
