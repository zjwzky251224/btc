// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEigenPodMinimal, IEigenPodManagerMinimal, IDelegationManagerMinimal} from "../eigenlayer/IEigenLayerMinimal.sol";

/// @dev ABI/state-machine fixture. No BLS, beacon proofs, operator-set allocation or real AVS validation.
contract MockEigenPod is IEigenPodMinimal {
    address public immutable podOwner;
    address public immutable eigenPodManager;
    address public immutable delegation;
    uint64 public lastCheckpointTimestamp;
    uint64 public currentCheckpointTimestamp;
    bool public exitRequested;
    uint256 public exitReadyAt;
    constructor(address owner_, address manager_, address delegation_) { podOwner = owner_; eigenPodManager = manager_; delegation = delegation_; }
    receive() external payable {}
    function startCheckpoint(bool) external { require(msg.sender == podOwner, "POD_OWNER"); lastCheckpointTimestamp = uint64(block.timestamp); }
    function verifyWithdrawalCredentials(uint64, StateRootProof calldata, uint40[] calldata, bytes[] calldata, bytes32[][] calldata) external {
        require(msg.sender == podOwner, "POD_OWNER"); lastCheckpointTimestamp = uint64(block.timestamp);
    }
    function requestWithdrawal(WithdrawalRequest[] calldata) external payable {
        require(msg.sender == podOwner, "POD_OWNER"); exitRequested = true; exitReadyAt = block.timestamp + 1 days;
    }
    function release(address payable receiver, uint256 amount) external {
        require(msg.sender == delegation && exitRequested && block.timestamp >= exitReadyAt, "BEACON_EXIT_PENDING");
        (bool ok,) = receiver.call{value: amount}(""); require(ok, "ETH_TRANSFER");
    }
}

contract MockEigenPodManager is IEigenPodManagerMinimal {
    address public immutable delegation;
    address public immutable beaconChainETHStrategy = address(0xBEEF);
    mapping(address => address) public ownerToPod;
    constructor(address delegation_) { delegation = delegation_; }
    function delegationManager() external view returns (address) { return delegation; }
    function createPod() external returns (address) {
        require(ownerToPod[msg.sender] == address(0), "POD_EXISTS");
        address pod = address(new MockEigenPod(msg.sender, address(this), delegation)); ownerToPod[msg.sender] = pod; return pod;
    }
    function stake(bytes calldata, bytes calldata, bytes32) external payable {
        require(msg.value == 32 ether && ownerToPod[msg.sender] != address(0), "STAKE");
        (bool ok,) = ownerToPod[msg.sender].call{value: msg.value}(""); require(ok, "POD_FUNDING");
        MockDelegationManager(delegation).credit(msg.sender, msg.value);
    }
}

contract MockDelegationManager is Ownable, IDelegationManagerMinimal {
    address public manager;
    address public immutable beaconChainETHStrategy = address(0xBEEF);
    mapping(address => address) public delegatedTo;
    mapping(address => uint256) public rawShares;
    mapping(address => uint256) private factors;
    mapping(address => uint256) public queuedNonce;
    mapping(bytes32 => Withdrawal) private withdrawals;
    mapping(bytes32 => bool) public completed;
    mapping(address => bytes32[]) private roots;
    constructor(address owner_) Ownable(owner_) {}
    function setManager(address manager_) external onlyOwner { require(manager == address(0), "SET_ONCE"); manager = manager_; }
    function credit(address staker, uint256 amount) external { require(msg.sender == manager, "MANAGER"); rawShares[staker] += amount; }
    function delegateTo(address operator, SignatureWithExpiry calldata, bytes32) external { require(delegatedTo[msg.sender] == address(0), "DELEGATED"); delegatedTo[msg.sender] = operator; }
    function factor(address staker) public view returns (uint256) { return factors[staker] == 0 ? 1e18 : factors[staker] - 1; }
    function slash(address staker, uint256 bps) external onlyOwner { require(bps <= 10000, "BPS"); factors[staker] = Math.mulDiv(factor(staker), 10000 - bps, 10000) + 1; }
    function getWithdrawableShares(address staker, address[] calldata strategies) external view returns (uint256[] memory withdrawable, uint256[] memory deposited) {
        require(strategies.length == 1 && strategies[0] == beaconChainETHStrategy, "STRATEGY");
        withdrawable = new uint256[](1); deposited = new uint256[](1); deposited[0] = rawShares[staker]; withdrawable[0] = Math.mulDiv(deposited[0], factor(staker), 1e18);
    }
    function queueWithdrawals(QueuedWithdrawalParams[] calldata params) external returns (bytes32[] memory result) {
        result = new bytes32[](params.length);
        for (uint256 i; i < params.length; ++i) {
            require(params[i].strategies.length == 1 && params[i].strategies[0] == beaconChainETHStrategy && params[i].depositShares.length == 1, "STRATEGY");
            uint256 amount = params[i].depositShares[0]; require(amount <= rawShares[msg.sender], "SHARES"); rawShares[msg.sender] -= amount;
            Withdrawal memory w = Withdrawal(msg.sender, delegatedTo[msg.sender], msg.sender, ++queuedNonce[msg.sender], uint32(block.number), params[i].strategies, params[i].depositShares);
            bytes32 root = keccak256(abi.encode(w)); withdrawals[root] = w; roots[msg.sender].push(root); result[i] = root;
        }
    }
    function _effective(Withdrawal memory w) private view returns (uint256[] memory shares) {
        shares = new uint256[](1); shares[0] = Math.mulDiv(w.scaledShares[0], factor(w.staker), 1e18);
    }
    function getQueuedWithdrawals(address staker) external view returns (Withdrawal[] memory result, uint256[][] memory shares) {
        uint256 count; for (uint256 i; i < roots[staker].length; ++i) if (!completed[roots[staker][i]]) ++count;
        result = new Withdrawal[](count); shares = new uint256[][](count); uint256 next;
        for (uint256 i; i < roots[staker].length; ++i) { bytes32 root = roots[staker][i]; if (!completed[root]) { result[next] = withdrawals[root]; shares[next] = _effective(result[next]); ++next; } }
    }
    function getQueuedWithdrawal(bytes32 root) external view returns (Withdrawal memory w, uint256[] memory shares) {
        require(withdrawals[root].staker != address(0) && !completed[root], "WITHDRAWAL"); w = withdrawals[root]; shares = _effective(w);
    }
    function completeQueuedWithdrawal(Withdrawal calldata w, address[] calldata tokens, bool receiveAsTokens) external {
        bytes32 root = keccak256(abi.encode(w)); require(withdrawals[root].staker == msg.sender && !completed[root] && tokens.length == 1 && receiveAsTokens, "WITHDRAWAL");
        require(block.number >= w.startBlock + 2, "WITHDRAWAL_DELAY"); completed[root] = true;
        uint256[] memory effective = _effective(w);
        MockEigenPod(payable(MockEigenPodManager(manager).ownerToPod(msg.sender))).release(payable(msg.sender), effective[0]);
    }
}
