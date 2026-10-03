// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MessageApp} from "../messaging/MessageApp.sol";
import {Protocol, ICollateralOracle, IWrappedNative, INativePosition, IPositionRisk} from "../interfaces/Protocol.sol";
import {InterestModel} from "../risk/InterestModel.sol";
import {InterestMath} from "../risk/InterestMath.sol";

/// @notice Canonical debt and commitment authority. One immutable peer, no upgrade proxy.
contract CreditHub is MessageApp {
    using SafeERC20 for IERC20;
    uint256 private constant WAD = 1e18;
    enum LoanState { None, Committed, Executed, Cancelled, Rejected }
    struct Market {
        ICollateralOracle oracle;
        uint16 ltvBps;
        uint16 liquidationBps;
        uint16 bonusBps;
        uint256 debtCap;
        uint256 debtShares;
        bool indivisible;
        bool enabled;
        bytes32 riskGroup;
    }
    struct Account { address collateralToken; uint256 collateral; uint256 activeShares; uint256 principal; bytes32 pending; }
    struct Loan { bytes32 terms; address borrower; uint256 shares; LoanState state; }
    IERC20 public immutable usdc;
    address public immutable wrappedNative;
    InterestModel public immutable interestModel;
    mapping(address => Market) public markets;
    mapping(address => Account) public accounts;
    mapping(bytes32 => Loan) public loans;
    mapping(bytes32 => bool) public consumedRebalances;
    mapping(bytes32 => uint256) public groupShares;
    mapping(bytes32 => uint256) public groupCaps;
    uint256 public totalDebtShares;
    uint256 public immutable globalDebtCap;
    uint256 public debtIndex = WAD;
    uint256 public annualRate;
    uint256 public lastAccrual;
    uint256 public lastSnapshot;
    uint64 public snapshotSequence;
    uint256 public smoothedUtilization;
    uint256 public recoveryCash;
    uint256 public settlementNonce;
    bool public borrowPaused;
    uint256 public constant SNAPSHOT_MAX_AGE = 1 hours;
    uint256 public constant RATE_STEP_PER_SECOND = uint256(1e17) / 1 days;

    error RiskCheckFailed();
    error PendingCommitment();
    error InvalidOperation();
    event CollateralDeposited(address indexed borrower, address token, uint256 units);
    event DebtCommitted(bytes32 indexed id, address indexed borrower, uint256 amount);
    event Repaid(address indexed borrower, uint256 cash, uint256 sharesBurned);
    event Liquidated(address indexed borrower, address indexed buyer, uint256 payment, uint256 collateral);
    event BadDebtRecognized(address indexed borrower, uint256 debt, uint256 principal);
    event RateUpdated(uint256 rate, uint256 utilization);

    constructor(address owner_, address messenger_, uint64 domain_, address usdc_, address wrappedNative_, address model_, uint256 globalCap_)
        MessageApp(owner_, messenger_, domain_) {
        require(usdc_.code.length > 0 && wrappedNative_.code.length > 0 && model_.code.length > 0, "HUB_CONFIG");
        require(IERC20Metadata(usdc_).decimals() == 6 && IERC20Metadata(wrappedNative_).decimals() == 18, "ASSET_DECIMALS");
        require(globalCap_ > 0, "GLOBAL_CAP"); globalDebtCap = globalCap_;
        usdc = IERC20(usdc_); wrappedNative = wrappedNative_; interestModel = InterestModel(model_);
        annualRate = interestModel.rate(0); lastAccrual = block.timestamp; lastSnapshot = block.timestamp;
    }

    /// @dev Production owner must be a timelock; markets cannot be silently replaced.
    function registerMarket(address token, address oracle, uint16 ltv, uint16 threshold, uint16 bonus, uint256 cap, bool indivisible) external onlyOwner {
        require(token.code.length > 0 && oracle.code.length > 0 && address(markets[token].oracle) == address(0), "MARKET_CONFIG");
        require(ltv > 0 && ltv < threshold && threshold < 10000 && bonus <= 2500 && cap > 0, "RISK_CONFIG");
        bytes32 group = indivisible ? keccak256(abi.encode("EIGENLAYER_NATIVE", IPositionRisk(token).fixedOperator())) : keccak256(abi.encode(token));
        if (groupCaps[group] == 0) groupCaps[group] = cap;
        markets[token] = Market(ICollateralOracle(oracle), ltv, threshold, bonus, cap, 0, indivisible, true, group);
    }
    function setBorrowPaused(bool paused) external onlyOwner { borrowPaused = paused; }
    function disableMarket(address token) external onlyOwner { markets[token].enabled = false; }
    function reduceGroupCap(bytes32 group, uint256 cap) external onlyOwner {
        require(cap > 0 && cap < groupCaps[group], "CAP_ONLY_DECREASES"); groupCaps[group] = cap;
    }
    function _changeShares(address token, uint256 shares, bool increase) private {
        Market storage m = markets[token];
        if (increase) { m.debtShares += shares; groupShares[m.riskGroup] += shares; totalDebtShares += shares; }
        else { m.debtShares -= shares; groupShares[m.riskGroup] -= shares; totalDebtShares -= shares; }
    }

    function depositCollateral(address token, uint256 units) external nonReentrant {
        require(units > 0 && address(markets[token].oracle) != address(0), "UNKNOWN_COLLATERAL");
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), units);
        uint256 received = IERC20(token).balanceOf(address(this)) - beforeBalance;
        require(received == units, "NONSTANDARD_COLLATERAL");
        _deposit(msg.sender, token, received);
    }
    function depositNative() external payable nonReentrant {
        require(msg.value > 0 && address(markets[wrappedNative].oracle) != address(0), "UNKNOWN_COLLATERAL");
        IWrappedNative(wrappedNative).deposit{value: msg.value}();
        _deposit(msg.sender, wrappedNative, msg.value);
    }
    function _deposit(address borrower, address token, uint256 units) private {
        Account storage account = accounts[borrower];
        require(account.collateralToken == address(0) || account.collateralToken == token, "ONE_MARKET_PER_ACCOUNT");
        account.collateralToken = token; account.collateral += units;
        emit CollateralDeposited(borrower, token, units);
    }
    function withdrawCollateral(uint256 units, address receiver) external nonReentrant {
        Account storage account = accounts[msg.sender];
        if (account.pending != bytes32(0)) revert PendingCommitment();
        require(receiver != address(0) && units > 0 && units <= account.collateral, "WITHDRAW_AMOUNT");
        _accrue(); account.collateral -= units;
        uint256 owed = _debt(account.activeShares, debtIndex);
        if (owed != 0) {
            Market storage market = markets[account.collateralToken];
            if (Math.mulDiv(market.oracle.value(account.collateral), market.ltvBps, 10000) < owed) revert RiskCheckFailed();
        }
        IERC20(account.collateralToken).safeTransfer(receiver, units);
    }
    function currentIndex() public view returns (uint256) { return InterestMath.grow(debtIndex, annualRate, block.timestamp - lastAccrual); }
    function activeDebt(address borrower) public view returns (uint256) { return _debt(accounts[borrower].activeShares, currentIndex()); }
    function debt(address borrower) public view returns (uint256) {
        Account storage a = accounts[borrower];
        return _debt(a.activeShares + (a.pending == 0 ? 0 : loans[a.pending].shares), currentIndex());
    }
    function healthFactor(address borrower) public view returns (uint256) {
        uint256 d = debt(borrower); if (d == 0) return type(uint256).max;
        Account storage a = accounts[borrower]; Market storage m = markets[a.collateralToken];
        return Math.mulDiv(Math.mulDiv(m.oracle.value(a.collateral), m.liquidationBps, 10000), WAD, d);
    }
    function repay(address borrower, uint256 maxPayment) external nonReentrant returns (uint256 paid) {
        _accrue(); (paid,) = _repay(borrower, maxPayment, msg.sender);
    }
    function _repay(address borrower, uint256 maxPayment, address payer) private returns (uint256 paid, uint256 burned) {
        Account storage a = accounts[borrower]; uint256 owed = _debt(a.activeShares, debtIndex);
        require(owed > 0 && maxPayment > 0, "NO_ACTIVE_DEBT");
        uint256 payment = Math.min(maxPayment, owed);
        burned = payment == owed ? a.activeShares : Math.mulDiv(payment, WAD, debtIndex);
        require(burned > 0, "PAYMENT_DUST"); paid = _debt(burned, debtIndex);
        uint256 beforeCash = usdc.balanceOf(address(this)); usdc.safeTransferFrom(payer, address(this), paid);
        require(usdc.balanceOf(address(this)) - beforeCash == paid, "USDC_TRANSFER");
        a.activeShares -= burned; _changeShares(a.collateralToken, burned, false);
        uint256 retiredPrincipal = Math.min(a.principal, paid);
        a.principal -= retiredPrincipal; recoveryCash += paid;
        _delta(Protocol.Kind.Settled, borrower, paid, retiredPrincipal, address(0)); emit Repaid(borrower, paid, burned);
    }

    /// @notice Permissionless batches; a keeper must submit each batch. No automatic streaming.
    function liquidate(address borrower, uint256 maxPayment, uint256 minCollateral) external nonReentrant returns (uint256 paid, uint256 seized) {
        _accrue(); Account storage a = accounts[borrower]; Market storage m = markets[a.collateralToken];
        if (a.pending != 0) revert PendingCommitment();
        require(!m.indivisible && a.collateral > 0 && maxPayment > 0, "USE_POSITION_SALE");
        uint256 hf = healthFactor(borrower); require(hf < WAD, "HEALTHY");
        uint256 value = m.oracle.value(a.collateral); uint256 owed = _debt(a.activeShares, debtIndex);
        uint256 capacity = Math.mulDiv(value, 10000, 10000 + m.bonusBps);
        uint256 closeLimit = hf < 9e17 ? owed : Math.max(1, owed / 4);
        uint256 limit = Math.min(maxPayment, Math.min(closeLimit, Math.max(1, capacity)));
        (paid,) = _repay(borrower, limit, msg.sender);
        seized = paid >= capacity ? a.collateral : Math.mulDiv(Math.mulDiv(paid, 10000 + m.bonusBps, 10000), a.collateral, value);
        require(seized > 0 && seized >= minCollateral, "SLIPPAGE");
        a.collateral -= seized; IERC20(a.collateralToken).safeTransfer(msg.sender, seized);
        emit Liquidated(borrower, msg.sender, paid, seized);
    }

    /// @notice Whole-position fixed-discount take. The buyer acquires real EigenPod control.
    function buyFullPosition(address borrower, uint256 maxPayment) external nonReentrant returns (uint256 price) {
        _accrue(); Account storage a = accounts[borrower]; Market storage m = markets[a.collateralToken];
        if (a.pending != 0) revert PendingCommitment();
        require(m.indivisible && a.collateral > 0 && healthFactor(borrower) < WAD, "POSITION_NOT_LIQUIDATABLE");
        price = Math.max(1, Math.mulDiv(m.oracle.value(a.collateral), 10000, 10000 + m.bonusBps, Math.Rounding.Ceil));
        require(price <= maxPayment, "SLIPPAGE");
        (uint256 paid,) = _repay(borrower, price, msg.sender);
        uint256 surplus = price - paid;
        if (surplus > 0) { usdc.safeTransferFrom(msg.sender, borrower, surplus); }
        uint256 units = a.collateral; a.collateral = 0;
        IERC20(a.collateralToken).safeTransfer(msg.sender, units);
        emit Liquidated(borrower, msg.sender, price, units);
    }
    function recognizeBadDebt(address borrower) external nonReentrant {
        _accrue(); Account storage a = accounts[borrower];
        require(a.pending == 0 && a.collateral == 0 && a.activeShares > 0, "RECOVERY_NOT_COMPLETE");
        uint256 lostDebt = _debt(a.activeShares, debtIndex); uint256 lostPrincipal = a.principal;
        _changeShares(a.collateralToken, a.activeShares, false); a.activeShares = 0; a.principal = 0;
        _delta(Protocol.Kind.Loss, borrower, lostPrincipal, 0, address(0));
        emit BadDebtRecognized(borrower, lostDebt, lostPrincipal);
    }
    function requestPositionExits(address borrower, bytes[] calldata pubkeys) external payable nonReentrant {
        Account storage a = accounts[borrower];
        require(markets[a.collateralToken].indivisible && a.collateral == 1e18 && healthFactor(borrower) < WAD, "EXIT_NOT_AUTHORIZED");
        INativePosition(a.collateralToken).requestExits{value: msg.value}(pubkeys);
    }
    /// @notice Start only through governance while the Hub holds the complete receipt.
    /// @dev Permissionless initiation would allow repeated unfinished checkpoints to block valuation.
    function startPositionCheckpoint(address borrower, bool revertIfNoBalance) external onlyOwner nonReentrant {
        Account storage a = accounts[borrower];
        require(markets[a.collateralToken].indivisible && a.collateral == 1e18, "NO_CONTROLLED_POSITION");
        INativePosition(a.collateralToken).startCheckpoint(revertIfNoBalance);
    }
    function _debt(uint256 shares, uint256 index) private pure returns (uint256) { return Math.mulDiv(shares, index, WAD, Math.Rounding.Ceil); }
    function _accrue() private { debtIndex = currentIndex(); lastAccrual = block.timestamp; }
    function _terms(Protocol.Message memory message) private pure returns (bytes32) {
        return keccak256(abi.encode(message.id, message.borrower, message.receiver, message.amount, message.deadline));
    }
    function _delta(Protocol.Kind kind, address borrower, uint256 amount, uint256 auxiliary, address receiver) private {
        bytes32 id = keccak256(abi.encode(address(this), localDomain, ++settlementNonce));
        _queue(Protocol.Message(Protocol.DOMAIN, kind, id, borrower, receiver, amount, 0, uint64(settlementNonce), auxiliary));
    }
    function _receiveMessage(Protocol.Message memory message) internal override {
        if (message.kind == Protocol.Kind.Utilization) { _snapshot(message); return; }
        if (message.kind == Protocol.Kind.Rebalanced) {
            if (consumedRebalances[message.id]) return;
            require(message.amount > 0 && message.amount <= recoveryCash && message.receiver != address(0), "REBALANCE_CASH");
            consumedRebalances[message.id] = true; recoveryCash -= message.amount;
            usdc.safeTransfer(message.receiver, message.amount); return;
        }
        if (message.kind != Protocol.Kind.Prepare && message.kind != Protocol.Kind.Executed && message.kind != Protocol.Kind.Cancelled) revert InvalidOperation();
        require(message.id != 0 && message.borrower != address(0) && message.receiver != address(0) && message.amount > 0, "LOAN_TERMS");
        Loan storage loan = loans[message.id]; bytes32 terms = _terms(message);
        if (loan.state != LoanState.None && loan.terms != terms) revert InvalidOperation();
        if (message.kind == Protocol.Kind.Prepare) { _prepare(message, loan, terms); return; }
        if (message.kind == Protocol.Kind.Cancelled) {
            if (loan.state == LoanState.Executed) revert InvalidOperation();
            if (loan.state == LoanState.Committed) {
                Account storage a = accounts[loan.borrower]; require(a.pending == message.id, "PENDING_ID");
                _changeShares(a.collateralToken, loan.shares, false); a.pending = 0;
            }
            loan.terms = terms; loan.borrower = message.borrower; loan.state = LoanState.Cancelled; return;
        }
        if (loan.state == LoanState.Executed) return;
        require(loan.state == LoanState.Committed && accounts[loan.borrower].pending == message.id, "NO_COMMITMENT");
        Account storage account = accounts[loan.borrower]; account.activeShares += loan.shares;
        account.principal += message.amount; account.pending = 0; loan.state = LoanState.Executed;
    }
    function _prepare(Protocol.Message memory message, Loan storage loan, bytes32 terms) private {
        if (loan.state != LoanState.None) {
            if (loan.state == LoanState.Committed || loan.state == LoanState.Executed) message.kind = Protocol.Kind.Commit;
            else message.kind = Protocol.Kind.CancelRequest;
            _queue(message); return;
        }
        _accrue(); Account storage a = accounts[message.borrower]; Market storage market = markets[a.collateralToken];
        bool accepted = !borrowPaused && market.enabled && a.pending == 0 && message.deadline > block.timestamp
            && block.timestamp - lastSnapshot <= SNAPSHOT_MAX_AGE;
        uint256 shares = Math.mulDiv(message.amount, WAD, debtIndex, Math.Rounding.Ceil);
        if (accepted) {
            try market.oracle.value(a.collateral) returns (uint256 value) {
                accepted = _debt(a.activeShares + shares, debtIndex) <= Math.mulDiv(value, market.ltvBps, 10000)
                    && _debt(market.debtShares + shares, debtIndex) <= market.debtCap
                    && _debt(groupShares[market.riskGroup] + shares, debtIndex) <= groupCaps[market.riskGroup]
                    && _debt(totalDebtShares + shares, debtIndex) <= globalDebtCap;
            } catch { accepted = false; }
        }
        loan.terms = terms; loan.borrower = message.borrower;
        if (accepted) {
            loan.state = LoanState.Committed; loan.shares = shares; a.pending = message.id; _changeShares(a.collateralToken, shares, true);
            message.kind = Protocol.Kind.Commit; emit DebtCommitted(message.id, message.borrower, message.amount);
        } else { loan.state = LoanState.Rejected; message.kind = Protocol.Kind.CancelRequest; }
        _queue(message);
    }
    function _snapshot(Protocol.Message memory message) private {
        if (message.sequence <= snapshotSequence) return;
        require(message.amount <= WAD && message.deadline <= block.timestamp && block.timestamp - message.deadline <= SNAPSHOT_MAX_AGE, "SNAPSHOT_STALE");
        _accrue(); uint256 dt = block.timestamp - lastSnapshot;
        uint256 alpha = Math.min(dt, 1 hours);
        smoothedUtilization = (smoothedUtilization * (1 hours - alpha) + message.amount * alpha) / 1 hours;
        uint256 target = interestModel.rate(smoothedUtilization); uint256 step = RATE_STEP_PER_SECOND * dt;
        annualRate = target > annualRate ? Math.min(target, annualRate + step) : annualRate - Math.min(annualRate - target, step);
        snapshotSequence = message.sequence; lastSnapshot = block.timestamp; emit RateUpdated(annualRate, smoothedUtilization);
    }
}
