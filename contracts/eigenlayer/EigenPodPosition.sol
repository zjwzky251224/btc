// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IEigenPodMinimal, IEigenPodManagerMinimal, IDelegationManagerMinimal} from "./IEigenLayerMinimal.sol";

/// @notice One indivisible receipt controls one contract-owned native-restaking EigenPod.
/// @dev Minting the receipt does not create credit. Backing requires verified fresh checkpoints.
contract EigenPodPosition is ERC20, ReentrancyGuard {
    uint256 public constant POSITION_UNIT = 1e18;
    IEigenPodManagerMinimal public immutable podManager;
    IDelegationManagerMinimal public immutable delegationManager;
    IEigenPodMinimal public immutable pod;
    address public immutable fixedOperator;
    address public immutable nativeStrategy;
    uint256 public immutable checkpointMaxAge;
    event ValidatorStakeRequested(bytes32 indexed pubkeyHash);
    event ExitRequested(bytes32 indexed pubkeyHash);
    event WithdrawalQueued(bytes32 indexed root);
    error NotController();
    modifier onlyController() { if (balanceOf(msg.sender) != POSITION_UNIT) revert NotController(); _; }

    constructor(address beneficiary, address manager_, address delegation_, address operator_, uint256 checkpointAge_)
        ERC20("EigenPod collateral position", "epPOSITION") {
        require(beneficiary != address(0) && manager_.code.length > 0 && delegation_.code.length > 0 && operator_ != address(0)
            && checkpointAge_ > 0 && checkpointAge_ <= 1 days, "POSITION_CONFIG");
        podManager = IEigenPodManagerMinimal(manager_); delegationManager = IDelegationManagerMinimal(delegation_);
        require(podManager.delegationManager() == delegation_, "DELEGATION_MANAGER_PAIR");
        fixedOperator = operator_; checkpointMaxAge = checkpointAge_;
        address strategy = podManager.beaconChainETHStrategy();
        require(strategy != address(0) && delegationManager.beaconChainETHStrategy() == strategy, "NATIVE_STRATEGY"); nativeStrategy = strategy;
        IEigenPodMinimal newPod = IEigenPodMinimal(podManager.createPod());
        require(newPod.podOwner() == address(this) && newPod.eigenPodManager() == manager_ && podManager.ownerToPod(address(this)) == address(newPod), "POD_CONTROL");
        pod = newPod; _mint(beneficiary, POSITION_UNIT);
    }
    receive() external payable {}
    function _update(address from, address to, uint256 value) internal override {
        require(value == 0 || value == POSITION_UNIT, "INDIVISIBLE_POSITION"); super._update(from, to, value);
    }
    function stakeValidator(bytes calldata pubkey, bytes calldata signature, bytes32 root) external payable onlyController nonReentrant {
        require(msg.value == 32 ether && pubkey.length == 48 && signature.length == 96, "VALIDATOR_INPUT");
        podManager.stake{value: msg.value}(pubkey, signature, root); emit ValidatorStakeRequested(keccak256(pubkey));
    }
    function delegate(IDelegationManagerMinimal.SignatureWithExpiry calldata approval, bytes32 salt) external onlyController nonReentrant {
        require(delegationManager.delegatedTo(address(this)) == address(0), "ALREADY_DELEGATED");
        delegationManager.delegateTo(fixedOperator, approval, salt);
    }
    function submitCredentials(uint64 timestamp, IEigenPodMinimal.StateRootProof calldata proof,
        uint40[] calldata indices, bytes[] calldata proofs, bytes32[][] calldata fields) external nonReentrant {
        pod.verifyWithdrawalCredentials(timestamp, proof, indices, proofs, fields);
    }
    function startCheckpoint(bool revertIfNoBalance) external onlyController nonReentrant { pod.startCheckpoint(revertIfNoBalance); }
    // Anyone may submit checkpoint proofs directly to EigenPod; there is no arbitrary-call escape hatch.
    function requestExits(bytes[] calldata pubkeys) external payable onlyController nonReentrant {
        require(pubkeys.length > 0 && pubkeys.length <= 32, "EXIT_BATCH");
        IEigenPodMinimal.WithdrawalRequest[] memory requests = new IEigenPodMinimal.WithdrawalRequest[](pubkeys.length);
        for (uint256 i; i < pubkeys.length; ++i) { require(pubkeys[i].length == 48, "PUBKEY"); requests[i] = IEigenPodMinimal.WithdrawalRequest(pubkeys[i], 0); }
        pod.requestWithdrawal{value: msg.value}(requests);
        for (uint256 i; i < pubkeys.length; ++i) emit ExitRequested(keccak256(pubkeys[i]));
    }
    function queueWithdrawal(uint256 depositShares) external onlyController nonReentrant returns (bytes32 root) {
        require(depositShares > 0, "WITHDRAWAL_AMOUNT");
        address[] memory strategies = new address[](1); strategies[0] = nativeStrategy;
        uint256[] memory shares = new uint256[](1); shares[0] = depositShares;
        IDelegationManagerMinimal.QueuedWithdrawalParams[] memory params = new IDelegationManagerMinimal.QueuedWithdrawalParams[](1);
        params[0] = IDelegationManagerMinimal.QueuedWithdrawalParams(strategies, shares, address(this));
        bytes32[] memory roots = delegationManager.queueWithdrawals(params); require(roots.length == 1, "WITHDRAWAL_ROOT");
        root = roots[0]; emit WithdrawalQueued(root);
    }
    function completeWithdrawal(bytes32 root) external nonReentrant {
        (IDelegationManagerMinimal.Withdrawal memory withdrawal,) = delegationManager.getQueuedWithdrawal(root);
        require(withdrawal.staker == address(this) && withdrawal.withdrawer == address(this) && withdrawal.strategies.length == 1
            && withdrawal.strategies[0] == nativeStrategy, "WITHDRAWAL_CONTROL");
        address[] memory tokens = new address[](1); delegationManager.completeQueuedWithdrawal(withdrawal, tokens, true);
    }
    function withdrawLiquidEth(uint256 amount, address payable receiver) external onlyController nonReentrant {
        require(receiver != address(0) && amount <= address(this).balance, "LIQUID_ETH");
        (bool success,) = receiver.call{value: amount}(""); require(success, "ETH_TRANSFER");
    }
    function backingAssets() external view returns (uint256 assets) {
        uint64 checkpoint = pod.lastCheckpointTimestamp();
        require(checkpoint != 0 && checkpoint <= block.timestamp && block.timestamp - checkpoint <= checkpointMaxAge
            && pod.currentCheckpointTimestamp() == 0, "CHECKPOINT_STALE");
        address operator = delegationManager.delegatedTo(address(this));
        require(operator == address(0) || operator == fixedOperator, "OPERATOR_CHANGED");
        address[] memory strategies = new address[](1); strategies[0] = nativeStrategy;
        (uint256[] memory active,) = delegationManager.getWithdrawableShares(address(this), strategies);
        require(active.length == 1, "SHARE_RESULT"); assets = address(this).balance + active[0];
        (IDelegationManagerMinimal.Withdrawal[] memory withdrawals, uint256[][] memory queued) = delegationManager.getQueuedWithdrawals(address(this));
        require(withdrawals.length <= 16 && withdrawals.length == queued.length, "QUEUE_LIMIT");
        for (uint256 i; i < withdrawals.length; ++i) {
            require(withdrawals[i].staker == address(this) && withdrawals[i].withdrawer == address(this)
                && withdrawals[i].strategies.length == 1 && withdrawals[i].strategies[0] == nativeStrategy && queued[i].length == 1, "QUEUED_STRATEGY");
            assets += queued[i][0];
        }
    }
}
