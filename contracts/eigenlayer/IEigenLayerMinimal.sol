// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice ABI-only declarations. Addresses/ABI must match the selected EigenLayer deployment.
/// @dev References: Layr-Labs/eigenlayer-contracts, interfaces IEigenPod/IDelegationManager.
interface IEigenPodMinimal {
    struct StateRootProof { bytes32 beaconStateRoot; bytes proof; }
    struct WithdrawalRequest { bytes pubkey; uint64 amountGwei; }
    function podOwner() external view returns (address);
    function eigenPodManager() external view returns (address);
    function lastCheckpointTimestamp() external view returns (uint64);
    function currentCheckpointTimestamp() external view returns (uint64);
    function startCheckpoint(bool revertIfNoBalance) external;
    function verifyWithdrawalCredentials(uint64 timestamp, StateRootProof calldata proof, uint40[] calldata indices, bytes[] calldata proofs, bytes32[][] calldata fields) external;
    function requestWithdrawal(WithdrawalRequest[] calldata requests) external payable;
}
interface IEigenPodManagerMinimal {
    function delegationManager() external view returns (address);
    function createPod() external returns (address);
    function stake(bytes calldata pubkey, bytes calldata signature, bytes32 root) external payable;
    function ownerToPod(address owner) external view returns (address);
    function beaconChainETHStrategy() external view returns (address);
}
interface IDelegationManagerMinimal {
    struct SignatureWithExpiry { bytes signature; uint256 expiry; }
    struct Withdrawal { address staker; address delegatedTo; address withdrawer; uint256 nonce; uint32 startBlock; address[] strategies; uint256[] scaledShares; }
    struct QueuedWithdrawalParams { address[] strategies; uint256[] depositShares; address deprecatedWithdrawer; }
    function beaconChainETHStrategy() external view returns (address);
    function delegatedTo(address staker) external view returns (address);
    function delegateTo(address operator, SignatureWithExpiry calldata approval, bytes32 salt) external;
    function getWithdrawableShares(address staker, address[] calldata strategies) external view returns (uint256[] memory, uint256[] memory);
    function queueWithdrawals(QueuedWithdrawalParams[] calldata params) external returns (bytes32[] memory);
    function getQueuedWithdrawals(address staker) external view returns (Withdrawal[] memory, uint256[][] memory);
    function getQueuedWithdrawal(bytes32 root) external view returns (Withdrawal memory, uint256[] memory);
    function completeQueuedWithdrawal(Withdrawal calldata withdrawal, address[] calldata tokens, bool receiveAsTokens) external;
}
