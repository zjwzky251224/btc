import test from 'node:test';
import assert from 'node:assert/strict';
import { AbiCoder, keccak256, toUtf8Bytes } from 'ethers';
import { fixture, tx, eth, usd, WAD, clock, deploy, event, artifacts } from './helpers.mjs';

const coder = AbiCoder.defaultAbiCoder();
const MESSAGE = 'tuple(bytes32 domain,uint8 kind,bytes32 id,address borrower,address receiver,uint256 amount,uint64 deadline,uint64 sequence,uint256 auxiliary)';
async function run(t, options) { const f = await fixture(options); t.after(() => f.close()); return f; }
async function collateral(f, amount = eth(1), actor = 1) { await tx(f.hub.connect(f.l1.signers[actor]).depositNative({ value: amount })); }
async function reject(promise) { await assert.rejects(async () => tx(promise)); }

test('two independent EVMs: committed credit stays locked; duplicate delivery never pays twice', async t => {
  const f = await run(t); await collateral(f); const id = await f.prepare(); const prepare = await f.relay(f.pool);
  assert.equal((await f.hub.loans(id)).state, 1n); assert.equal(await f.hub.debt(f.user), usd(1000));
  await reject(f.hub.connect(f.l1.signers[1]).withdrawCollateral(eth(1), f.user));
  const commit = await f.relay(f.hub); const before = await f.u2.balanceOf(f.user); await f.deliver(commit, true);
  assert.equal(await f.u2.balanceOf(f.user), before); await f.relay(f.pool);
  await f.deliver(prepare, false); await f.relay(f.hub); await f.relay(f.pool);
  assert.equal(await f.u2.balanceOf(f.user), usd(1000)); assert.equal(await f.hub.activeDebt(f.user), usd(1000));
  assert.equal(await f.pool.reservedCash(), 0n); assert.equal(await f.pool.totalAssets(), usd(100000));
});

test('destination cancellation arriving before PREPARE is a permanent tombstone', async t => {
  const f = await run(t); await collateral(f); const id = await f.prepare(); const originalIndex = await f.pool.outboxCount();
  await tx(f.pool.connect(f.l2.signers[1]).cancelBorrow(id)); await f.relay(f.pool);
  await f.relay(f.pool, originalIndex); await f.relay(f.hub); await f.relay(f.pool);
  assert.equal((await f.pool.borrows(id)).state, 3n); assert.equal((await f.hub.loans(id)).state, 3n);
  assert.equal(await f.hub.totalDebtShares(), 0n); assert.equal(await f.u2.balanceOf(f.user), 0n);
  await tx(f.hub.connect(f.l1.signers[1]).withdrawCollateral(eth(1), f.user));
});

test('timeout alone never releases credit; late COMMIT cannot revive cancellation', async t => {
  const f = await run(t); await collateral(f); const id = await f.prepare(); await f.relay(f.pool); const commitIndex = await f.hub.outboxCount();
  await f.advance(3601); await reject(f.hub.connect(f.l1.signers[1]).withdrawCollateral(eth(1), f.user));
  await tx(f.pool.connect(f.l2.signers[5]).cancelBorrow(id)); await f.relay(f.pool);
  await f.relay(f.hub, commitIndex); await f.relay(f.pool);
  assert.equal(await f.hub.debt(f.user), 0n); assert.equal(await f.u2.balanceOf(f.user), 0n);
  await tx(f.hub.connect(f.l1.signers[1]).withdrawCollateral(eth(1), f.user));
});

test('a second outstanding request cannot reuse the same collateral allowance', async t => {
  const f = await run(t); await collateral(f); const first = await f.prepare(usd(1000)); await f.relay(f.pool);
  const second = await f.prepare(usd(1000)); await f.relay(f.pool); await f.relay(f.hub); await f.relay(f.pool);
  assert.equal((await f.hub.loans(second)).state, 3n); assert.equal((await f.hub.accounts(f.user)).pending, first);
  assert.equal(await f.hub.debt(f.user), usd(1000));
});

test('risk rejection returns reserved Arb cash without creating debt', async t => {
  const f = await run(t); await collateral(f); const id = await f.prepare(usd(2000));
  await f.relay(f.pool); await f.relay(f.hub); await f.relay(f.pool);
  assert.equal((await f.pool.borrows(id)).state, 3n); assert.equal(await f.hub.debt(f.user), 0n); assert.equal(await f.pool.reservedCash(), 0n);
});

test('global cap includes pending commitments across borrowers', async t => {
  const f = await run(t, { globalCap: usd(1500) }); await collateral(f); await collateral(f, eth(1), 5);
  await f.prepare(usd(1000)); await f.relay(f.pool);
  const second = await f.prepare(usd(1000), 5); await f.relay(f.pool); await f.relay(f.hub); await f.relay(f.pool);
  assert.equal((await f.pool.borrows(second)).state, 3n); assert.equal(await f.hub.totalDebtShares(), usd(1000));
});

test('EOA injection, wrong peer, modified loan terms and cancelled-state execution are rejected', async t => {
  const f = await run(t); await collateral(f); const id = await f.prepare();
  const payload = await f.pool.outbox(await f.pool.outboxCount());
  await reject(f.hub.onMessage(222, f.pool.target, payload));
  await reject(f.m1.deliver(222, f.l1.addresses[5], f.hub.target, payload));
  await f.relay(f.pool); const commit = await f.hub.outbox(await f.hub.outboxCount());
  const decoded = Array.from(coder.decode([MESSAGE], commit)[0]); decoded[5] += 1n;
  await reject(f.m2.deliver(111, f.hub.target, f.pool.target, coder.encode([MESSAGE], [decoded])));
  assert.equal((await f.pool.borrows(id)).state, 1n);
});

test('local real USDC repayment creates L1 recovery, not instantaneous Arb cash; solver rebalances once', async t => {
  const f = await run(t); await collateral(f); await f.borrow(); await f.advance(86400);
  const before = await f.u2.balanceOf(f.pool.target); const debt = await f.hub.activeDebt(f.user);
  await tx(f.hub.connect(f.l1.signers[3]).repay(f.user, debt)); const settlement = await f.relay(f.hub); await f.deliver(settlement, true);
  assert.equal(await f.pool.outstandingPrincipal(), 0n); assert.equal(await f.pool.remoteRecovery(), debt);
  assert.equal(await f.u2.balanceOf(f.pool.target), before); assert.equal(await f.pool.totalAssets(), before + debt);
  await tx(f.u2.mint(f.l2.addresses[4], debt)); await tx(f.u2.connect(f.l2.signers[4]).approve(f.pool.target, debt));
  await tx(f.pool.connect(f.l2.signers[4]).rebalance(debt, f.l1.addresses[4])); const packet = await f.relay(f.pool); await f.deliver(packet, false);
  assert.equal(await f.pool.remoteRecovery(), 0n); assert.equal(await f.hub.recoveryCash(), 0n);
  assert.equal(await f.u1.balanceOf(f.l1.addresses[4]), debt); assert.equal(await f.u2.balanceOf(f.pool.target), before + debt);
});

test('old repayment interest cannot retire principal of a newer loan when messages reorder', async t => {
  const f = await run(t); await collateral(f); await f.borrow(); await f.advance(864000); await f.refresh();
  await tx(f.hub.connect(f.l1.signers[3]).repay(f.user, await f.hub.activeDebt(f.user))); const settledIndex = await f.hub.outboxCount();
  const actualCash = await f.hub.recoveryCash(); assert.ok(actualCash > usd(1000));
  await tx(f.pool.publishUtilization()); await f.relay(f.pool); await f.borrow();
  assert.equal(await f.pool.outstandingPrincipal(), usd(2000));
  await f.relay(f.hub, settledIndex); assert.equal(await f.pool.outstandingPrincipal(), usd(1000));
  assert.equal(await f.pool.remoteRecovery(), actualCash);
});

test('soft liquidation executes bounded batches and stops once healthy', async t => {
  const f = await run(t); await collateral(f); await f.borrow(); await f.refresh(1250);
  const oldHF = await f.hub.healthFactor(f.user);
  await tx(f.hub.connect(f.l1.signers[3]).liquidate(f.user, usd(1000), 1));
  assert.equal(await f.hub.activeDebt(f.user), usd(750)); assert.ok(await f.hub.healthFactor(f.user) > oldHF);
  await f.relay(f.hub); await tx(f.hub.connect(f.l1.signers[3]).liquidate(f.user, usd(1000), 1)); await f.relay(f.hub);
  assert.ok(await f.hub.healthFactor(f.user) >= WAD);
  await reject(f.hub.connect(f.l1.signers[3]).liquidate(f.user, usd(1000), 1));
});

test('hard liquidation recognizes real loss; LOSS and recovery may arrive in either order', async t => {
  const f = await run(t); await collateral(f); await f.borrow(); await f.refresh(800);
  await tx(f.hub.connect(f.l1.signers[3]).liquidate(f.user, usd(1000), 1)); const settled = await f.hub.outboxCount();
  assert.equal((await f.hub.accounts(f.user)).collateral, 0n); assert.ok(await f.hub.activeDebt(f.user) > 0n);
  await tx(f.hub.recognizeBadDebt(f.user)); const loss = await f.relay(f.hub); await f.deliver(loss, true); await f.relay(f.hub, settled);
  assert.equal(await f.pool.outstandingPrincipal(), 0n); assert.equal(await f.hub.totalDebtShares(), 0n);
  assert.ok(await f.pool.totalAssets() < usd(100000));
});

test('invalid, future and stale oracle data do not originate credit; USDC depeg changes valuation', async t => {
  const f = await run(t); await collateral(f); const now = await clock(f.l1.provider);
  for (const values of [[0n, now, now], [3000n * 10n ** 8n, now, now + 1], [3000n * 10n ** 8n, now - 3601, now - 3601]]) {
    await tx(f.ethFeed.set(...values)); await assert.rejects(() => f.oracle.value(eth(1)));
    const id = await f.prepare(); await f.relay(f.pool); await f.relay(f.hub); await f.relay(f.pool); assert.equal((await f.pool.borrows(id)).state, 3n);
  }
  await f.refresh(3000, 1.05); assert.ok(await f.oracle.value(eth(1)) < usd(3000));
});

test('sequencer down, uninitialized state and recovery grace block new borrowing', async t => {
  const f = await run(t, { guard: true }); await collateral(f); const now = await clock(f.l2.provider);
  for (const [status, started] of [[1, now - 4000], [0, 0], [0, now]]) {
    await tx(f.uptime.set(status, started, now)); await reject(f.pool.connect(f.l2.signers[1]).requestBorrow(usd(1000), f.user, now + 7200));
  }
  await tx(f.uptime.set(0, now - 3601, now)); await f.borrow(); assert.equal(await f.hub.activeDebt(f.user), usd(1000));
});

test('LP withdrawals cannot spend reserved cash or the cash floor', async t => {
  const f = await run(t); await collateral(f); await f.prepare();
  assert.equal(await f.pool.availableCash(), usd(98900));
  await reject(f.pool.connect(f.l2.signers[2]).withdraw(usd(99000), f.l2.addresses[2], f.l2.addresses[2]));
});

test('time-weighted samples and rate limits resist instantaneous utilization spikes and old snapshots', async t => {
  const f = await run(t); await collateral(f); await f.advance(3600);
  const id = await f.prepare(); await tx(f.pool.connect(f.l2.signers[1]).cancelBorrow(id));
  await tx(f.pool.publishUtilization()); const packet = await f.relay(f.pool);
  assert.equal(await f.hub.smoothedUtilization(), 0n); const before = await f.hub.annualRate(); await f.deliver(packet, false);
  assert.equal(await f.hub.annualRate(), before);
  assert.equal(await f.model.rate(8n * WAD / 10n), WAD / 10n); assert.equal(await f.model.rate(WAD), WAD);
});

test('pausing borrowing does not prevent confirmed debt repayment', async t => {
  const f = await run(t); await collateral(f); await f.borrow();
  await tx(f.hub.setBorrowPaused(true)); await tx(f.pool.setBorrowPaused(true));
  await tx(f.hub.connect(f.l1.signers[3]).repay(f.user, usd(1000))); assert.equal(await f.hub.activeDebt(f.user), 0n);
});

test('EigenLayer factory is disabled by default and unverified positions have no backing valuation', async t => {
  const f = await run(t); const dm = await deploy(f.l1, 'MockDelegationManager', [f.owner]);
  const pm = await deploy(f.l1, 'MockEigenPodManager', [dm.target]); await tx(dm.setManager(pm.target));
  const factory = await deploy(f.l1, 'EigenPodPositionFactory', [f.owner, pm.target, dm.target]);
  await reject(factory.connect(f.l1.signers[1]).create(f.l1.addresses[6], 3600));
  const p = await deploy(f.l1, 'EigenPodPosition', [f.user, pm.target, dm.target, f.l1.addresses[6], 3600]);
  await assert.rejects(() => p.backingAssets());
  await reject(p.connect(f.l1.signers[1]).transfer(f.l1.addresses[5], WAD / 2n));
  const wrongDm = await deploy(f.l1, 'MockDelegationManager', [f.owner]);
  await assert.rejects(() => deploy(f.l1, 'EigenPodPosition', [f.user, pm.target, wrongDm.target, f.l1.addresses[6], 3600]));
});

test('EigenPod collateral: slashing changes credit; whole-position buyer controls exits and delayed withdrawals', async t => {
  const f = await run(t); const { position, pubkey } = await f.native(); await f.borrow(usd(20000));
  await reject(position.queueWithdrawal(eth(32))); await tx(f.dm.slash(position.target, 7000));
  assert.equal(await position.backingAssets(), eth(9.6)); assert.ok(await f.hub.healthFactor(f.user) < WAD);
  const buyer = position.connect(f.l1.signers[3]); await tx(f.hub.connect(f.l1.signers[3]).buyFullPosition(f.user, usd(30000)));
  assert.equal(await buyer.balanceOf(f.l1.addresses[3]), WAD); assert.equal(await f.hub.activeDebt(f.user), 0n);
  assert.ok(await f.u1.balanceOf(f.user) > 0n); await tx(buyer.requestExits([pubkey]));
  const root = event(buyer, await tx(buyer.queueWithdrawal(eth(32))), 'WithdrawalQueued').root;
  await reject(buyer.completeWithdrawal(root)); await tx(f.dm.slash(position.target, 1500));
  assert.equal(await buyer.backingAssets(), eth(8.16)); await f.advance(86401); await tx(buyer.startCheckpoint(false));
  await tx(buyer.completeWithdrawal(root)); assert.equal(await f.l1.provider.getBalance(position.target), eth(8.16));
  const recipient = f.l1.addresses[5]; const before = await f.l1.provider.getBalance(recipient);
  await tx(buyer.withdrawLiquidEth(eth(8.16), recipient)); assert.equal(await f.l1.provider.getBalance(recipient) - before, eth(8.16));
  await reject(buyer.completeWithdrawal(root));
});

test('native positions sharing an operator cannot bypass aggregate risk caps', async t => {
  const f = await run(t); await f.native(1, usd(25000)); await f.native(5, usd(100000));
  await f.borrow(usd(20000)); const id = await f.prepare(usd(10000), 5);
  await f.relay(f.pool); await f.relay(f.hub); await f.relay(f.pool);
  assert.equal((await f.pool.borrows(id)).state, 3n);
});

test('CCIP 2.0 adapter authenticates Router, gateway, app and source; requires finalized policy', async t => {
  const f = await run(t); const router = await deploy(f.l1, 'MockCCIPRouter', [f.owner]);
  const gateway = await deploy(f.l1, 'CCIPGateway', [f.owner, router.target, 800000]);
  const local = await deploy(f.l1, 'CreditHub', [f.owner, gateway.target, 111, f.u1.target, f.weth.target, f.model.target, usd(100000)]);
  await tx(local.configurePeer(222, f.pool.target)); await tx(gateway.bind(local.target, 222, f.l1.addresses[7], f.pool.target, []));
  const policy = await gateway.getCCVsAndFinalityConfig(222, '0x'); assert.equal(policy[3], '0x00000000');
  const empty = coder.encode([MESSAGE], [['0x' + '00'.repeat(32), 0, '0x' + '00'.repeat(32), f.user, f.user, 1, 0, 0, 0]]);
  const packet = ['0x' + '44'.repeat(32), 222, coder.encode(['address'], [f.l1.addresses[7]]), coder.encode(['address','bytes'], [f.pool.target, empty]), []];
  await reject(gateway.ccipReceive(packet));
  await reject(router.deliver(gateway.target, [packet[0], 999, ...packet.slice(2)]));
  await reject(router.deliver(gateway.target, [packet[0], 222, coder.encode(['address'], [f.l1.addresses[5]]), packet[3], []]));
  await reject(gateway.send(222, f.pool.target, empty, { value: 10n ** 12n }));
  // A correctly routed payload still must pass the protocol domain check.
  await reject(router.deliver(gateway.target, packet));
  const valid = Array.from(coder.decode([MESSAGE], empty)[0]); valid[0] = keccak256(toUtf8Bytes('OMNICHAIN_LENDING_V1'));
  valid[2] = '0x' + '55'.repeat(32);
  const validPacket = [...packet]; validPacket[3] = coder.encode(['address','bytes'], [f.pool.target, coder.encode([MESSAGE], [valid])]);
  await tx(router.deliver(gateway.target, validPacket)); assert.equal(await local.outboxCount(), 1n);
  const quote = await gateway.quote(await local.outbox(1)); await tx(local.dispatch(1, { value: quote })); assert.equal(await router.count(), 1n);
});

test('contract address equality, including a constructor with no code yet, is not borrowing authority', async t => {
  const f = await run(t); const proxy = await deploy(f.l2, 'MockBorrowProxy'); const deadline = await clock(f.l2.provider) + 3600;
  await reject(proxy.connect(f.l2.signers[1]).request(f.pool.target, usd(1000), f.user, deadline));
  await assert.rejects(() => deploy(f.l2, 'MockConstructorBorrower', [f.pool.target, usd(1000), f.user, deadline], f.l2.signers[1]));
  assert.equal(await f.pool.reservedCash(), 0n);
});

test('sustained utilization changes future rates without retroactively repricing the accrued interval', async t => {
  const f = await run(t); await collateral(f, eth(100)); await f.borrow(usd(50000)); await f.advance(3600);
  const oldRate = await f.hub.annualRate(); const expectedIndex = await f.hub.currentIndex();
  await tx(f.pool.publishUtilization()); await f.relay(f.pool);
  assert.equal(await f.hub.debtIndex(), expectedIndex); assert.ok(await f.hub.annualRate() > oldRate);
  assert.ok(await f.hub.annualRate() <= oldRate + await f.hub.RATE_STEP_PER_SECOND() * 3600n);
});

test('stale EigenPod checkpoints block valuation until a new verified checkpoint is available', async t => {
  const f = await run(t); const { position } = await f.native(); await f.advance(3601);
  await assert.rejects(() => position.backingAssets()); await tx(f.hub.startPositionCheckpoint(f.user, false)); assert.equal(await position.backingAssets(), eth(32));
});

test('checkpoint initiation follows receipt custody; former holder and unrelated callers cannot freeze valuation', async t => {
  const f = await run(t); const { position } = await f.native();
  await reject(position.startCheckpoint(false));
  await reject(position.connect(f.l1.signers[5]).startCheckpoint(false));
  await reject(f.hub.connect(f.l1.signers[1]).startPositionCheckpoint(f.user, false));
  await tx(f.hub.startPositionCheckpoint(f.user, false));
  assert.equal(await position.backingAssets(), eth(32));
  await tx(f.hub.connect(f.l1.signers[1]).withdrawCollateral(WAD, f.user));
  await reject(f.hub.startPositionCheckpoint(f.user, false));
  await tx(position.startCheckpoint(false));
});

test('canonical accounting rejects tokens with incompatible USDC or wrapped ETH decimals', async t => {
  const f = await run(t);
  const config = [f.owner, f.m1.target, 111, f.u1.target, f.weth.target, f.model.target, usd(100000)];
  const wrongUsdc = [...config]; wrongUsdc[3] = f.weth.target;
  const wrongWeth = [...config]; wrongWeth[4] = f.u1.target;
  await assert.rejects(() => deploy(f.l1, 'CreditHub', wrongUsdc));
  await assert.rejects(() => deploy(f.l1, 'CreditHub', wrongWeth));
});
