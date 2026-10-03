// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSDC is ERC20, Ownable {
    constructor(address owner_) ERC20("Mock USDC", "mUSDC") Ownable(owner_) {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address receiver, uint256 amount) external onlyOwner { _mint(receiver, amount); }
}
contract MockWETH is ERC20 {
    constructor() ERC20("Mock Wrapped ETH", "mWETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external { _burn(msg.sender, amount); (bool ok,) = msg.sender.call{value: amount}(""); require(ok, "ETH_TRANSFER"); }
}
