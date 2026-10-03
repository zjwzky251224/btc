// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MessageApp} from "../messaging/MessageApp.sol";
import {Protocol} from "../interfaces/Protocol.sol";
import {SequencerGuard} from "../risk/SequencerGuard.sol";

contract ArbitrumPool is MessageApp, ERC4626 {
    using SafeERC20 for IERC20;
    enum State { None, Prepared, Executed, Cancelled }
    struct Borrow { address borrower; address receiver; uint256 amount; uint64 deadline; State state; }
    mapping(bytes32 => Borrow) public borrows;
    mapping(address => uint256) public principal;
    mapping(bytes32 => bool) public settlements;
    SequencerGuard public immutable sequencerGuard;
    uint256 public immutable cashFloor;
    uint256 public reservedCash;
    uint256 public outstandingPrincipal;
    uint256 public remoteRecovery;
    uint256 public nonce;
    bool public borrowPaused;
    uint256 public cumulativeUtilization;
    uint256 public storedUtilization;
    uint256 public lastUtilizationTime;
    uint256 public lastSampleTime;
    uint256 public lastSampleCumulative;
    uint64 public sampleSequence;
    uint256 public constant SAMPLE_PERIOD = 60;
    event BorrowPrepared(bytes32 indexed id, address indexed borrower, uint256 amount);
    event BorrowExecuted(bytes32 indexed id, uint256 amount);
    event BorrowCancelled(bytes32 indexed id);
    event RecoveryRecorded(bytes32 indexed id, uint256 cash, uint256 retiredPrincipal);

    constructor(address owner_, address messenger_, uint64 domain_, address usdc_, address guard_, uint256 floor_)
        MessageApp(owner_, messenger_, domain_) ERC20("Omnichain USDC liquidity", "ocUSDC") ERC4626(IERC20(usdc_)) {
        require(IERC20Metadata(usdc_).decimals() == 6, "USDC_DECIMALS");
        require(guard_ != address(0) || block.chainid == 31337, "PRODUCTION_GUARD_REQUIRED");
        if (guard_ != address(0)) require(guard_.code.length > 0, "GUARD_CODE");
        sequencerGuard = SequencerGuard(guard_); cashFloor = floor_;
        lastUtilizationTime = block.timestamp; lastSampleTime = block.timestamp;
    }
    function _decimalsOffset() internal pure override returns (uint8) { return 6; }
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + outstandingPrincipal + remoteRecovery;
    }
    function availableCash() public view returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this)); uint256 locked = reservedCash + cashFloor;
        return balance > locked ? balance - locked : 0;
    }
    function maxWithdraw(address owner_) public view override returns (uint256) { return Math.min(super.maxWithdraw(owner_), availableCash()); }
    function maxRedeem(address owner_) public view override returns (uint256) { return Math.min(balanceOf(owner_), convertToShares(availableCash())); }
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        _checkpoint(); uint256 beforeBalance = IERC20(asset()).balanceOf(address(this));
        shares = super.deposit(assets, receiver);
        require(IERC20(asset()).balanceOf(address(this)) - beforeBalance == assets, "NONSTANDARD_USDC"); _updateUtilization();
    }
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        _checkpoint(); uint256 beforeBalance = IERC20(asset()).balanceOf(address(this)); assets = super.mint(shares, receiver);
        require(IERC20(asset()).balanceOf(address(this)) - beforeBalance == assets, "NONSTANDARD_USDC"); _updateUtilization();
    }
    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256 shares) {
        _checkpoint(); shares = super.withdraw(assets, receiver, owner_); _updateUtilization();
    }
    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256 assets) {
        _checkpoint(); assets = super.redeem(shares, receiver, owner_); _updateUtilization();
    }
    function depositWithMinShares(uint256 assets, address receiver, uint256 minimum) external returns (uint256 shares) {
        shares = deposit(assets, receiver); require(shares >= minimum, "SLIPPAGE");
    }
    function setBorrowPaused(bool paused) external onlyOwner { borrowPaused = paused; }
    function requestBorrow(uint256 amount, address receiver, uint64 deadline) external nonReentrant returns (bytes32 id) {
        // V1 supports direct EOA borrowing only. Address equality is not cross-chain smart-wallet authorization.
        require(msg.sender == tx.origin && msg.sender.code.length == 0, "EOA_BORROWER_ONLY");
        require(!borrowPaused && peer != address(0), "BORROW_PAUSED"); _guard();
        require(amount >= 1e6 && receiver != address(0) && deadline >= block.timestamp + 5 minutes && deadline <= block.timestamp + 1 days, "BORROW_TERMS");
        require(amount <= availableCash(), "INSUFFICIENT_LOCAL_CASH"); _checkpoint();
        id = keccak256(abi.encode(Protocol.DOMAIN, localDomain, address(this), msg.sender, ++nonce));
        borrows[id] = Borrow(msg.sender, receiver, amount, deadline, State.Prepared); reservedCash += amount;
        _reply(id, Protocol.Kind.Prepare); _updateUtilization(); emit BorrowPrepared(id, msg.sender, amount);
    }
    function cancelBorrow(bytes32 id) external nonReentrant {
        Borrow storage b = borrows[id]; require(b.state == State.Prepared, "NOT_PREPARED");
        require(msg.sender == b.borrower || block.timestamp >= b.deadline, "CANNOT_CANCEL"); _checkpoint();
        _cancel(id); _updateUtilization();
    }

    /// @notice A solver supplies real Arb USDC before requesting its L1 cash reimbursement.
    function rebalance(uint256 amount, address l1Receiver) external nonReentrant returns (bytes32 id) {
        require(amount > 0 && amount <= remoteRecovery && l1Receiver != address(0), "REBALANCE_AMOUNT"); _checkpoint();
        uint256 beforeBalance = IERC20(asset()).balanceOf(address(this));
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(asset()).balanceOf(address(this)) - beforeBalance == amount, "USDC_TRANSFER");
        remoteRecovery -= amount;
        id = keccak256(abi.encode(address(this), localDomain, "REBALANCE", ++nonce));
        _queue(Protocol.Message(Protocol.DOMAIN, Protocol.Kind.Rebalanced, id, address(0), l1Receiver, amount, 0, 0, 0));
        _updateUtilization();
    }
    function publishUtilization() external nonReentrant {
        require(block.timestamp - lastSampleTime >= SAMPLE_PERIOD, "SAMPLE_TOO_SOON"); _checkpoint();
        uint256 u = (cumulativeUtilization - lastSampleCumulative) / (block.timestamp - lastSampleTime);
        lastSampleCumulative = cumulativeUtilization; lastSampleTime = block.timestamp;
        _queue(Protocol.Message(Protocol.DOMAIN, Protocol.Kind.Utilization, bytes32(0), address(0), address(0), u, uint64(block.timestamp), ++sampleSequence, 0));
        _updateUtilization();
    }
    function _guard() private view { if (address(sequencerGuard) != address(0)) sequencerGuard.check(); }
    function _checkpoint() private {
        cumulativeUtilization += storedUtilization * (block.timestamp - lastUtilizationTime); lastUtilizationTime = block.timestamp;
    }
    function _updateUtilization() private {
        uint256 balance = IERC20(asset()).balanceOf(address(this)); uint256 denominator = balance + outstandingPrincipal;
        storedUtilization = denominator == 0 ? 0 : Math.min(1e18, Math.mulDiv(outstandingPrincipal + reservedCash, 1e18, denominator));
    }
    function _cancel(bytes32 id) private {
        Borrow storage b = borrows[id]; b.state = State.Cancelled; reservedCash -= b.amount;
        _reply(id, Protocol.Kind.Cancelled); emit BorrowCancelled(id);
    }
    function _reply(bytes32 id, Protocol.Kind kind) private {
        Borrow storage b = borrows[id];
        _queue(Protocol.Message(Protocol.DOMAIN, kind, id, b.borrower, b.receiver, b.amount, b.deadline, 0, 0));
    }
    function _receiveMessage(Protocol.Message memory message) internal override {
        if (message.kind == Protocol.Kind.Settled || message.kind == Protocol.Kind.Loss) {
            if (settlements[message.id]) return;
            uint256 retired = message.kind == Protocol.Kind.Loss ? message.amount : message.auxiliary;
            require(message.id != 0 && retired <= principal[message.borrower] && (message.kind != Protocol.Kind.Settled || retired <= message.amount), "SETTLEMENT_TERMS");
            _checkpoint(); settlements[message.id] = true;
            principal[message.borrower] -= retired; outstandingPrincipal -= retired;
            if (message.kind == Protocol.Kind.Settled) remoteRecovery += message.amount;
            _updateUtilization(); emit RecoveryRecorded(message.id, message.amount, retired); return;
        }
        require(message.kind == Protocol.Kind.Commit || message.kind == Protocol.Kind.CancelRequest, "MESSAGE_KIND");
        Borrow storage b = borrows[message.id];
        require(b.state != State.None && b.borrower == message.borrower && b.receiver == message.receiver
            && b.amount == message.amount && b.deadline == message.deadline, "LOAN_TERMS");
        if (b.state == State.Executed) { _reply(message.id, Protocol.Kind.Executed); return; }
        if (b.state == State.Cancelled) { _reply(message.id, Protocol.Kind.Cancelled); return; }
        _checkpoint();
        if (message.kind == Protocol.Kind.CancelRequest || borrowPaused || block.timestamp >= b.deadline) {
            _cancel(message.id); _updateUtilization(); return;
        }
        _guard();
        b.state = State.Executed; reservedCash -= b.amount; principal[b.borrower] += b.amount; outstandingPrincipal += b.amount;
        IERC20(asset()).safeTransfer(b.receiver, b.amount);
        _reply(message.id, Protocol.Kind.Executed); _updateUtilization(); emit BorrowExecuted(message.id, b.amount);
    }
}
