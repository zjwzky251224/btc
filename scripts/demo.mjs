import { compile } from './compile.mjs';
import { formatEther, formatUnits } from 'ethers';
compile();
const { fixture, tx, usd, eth, event } = await import('../test/helpers.mjs');
const f = await fixture();
try {
  const { position, pubkey } = await f.native();
  await f.borrow(usd(20000));
  console.log('1. Ethereum EigenPod receipt locked; borrower receives', formatUnits(await f.u2.balanceOf(f.user), 6), 'mock USDC on independent Arbitrum EVM.');
  await tx(f.dm.slash(position.target, 7000));
  console.log('2. Simulated 70% slash: recoverable backing', formatEther(await position.backingAssets()), 'ETH; health factor', formatUnits(await f.hub.healthFactor(f.user), 18));
  await tx(f.hub.connect(f.l1.signers[3]).buyFullPosition(f.user, usd(30000))); await f.relay(f.hub);
  console.log('3. Buyer acquires full Pod control after paying L1 USDC; Arb recovery receivable', formatUnits(await f.pool.remoteRecovery(), 6));
  const recovery = await f.pool.remoteRecovery(); await tx(f.u2.mint(f.l2.addresses[4], recovery));
  await tx(f.u2.connect(f.l2.signers[4]).approve(f.pool.target, recovery));
  await tx(f.pool.connect(f.l2.signers[4]).rebalance(recovery, f.l1.addresses[4])); await f.relay(f.pool);
  console.log('4. Solver supplies real local mock USDC before L1 reimbursement; remote recovery is', String(await f.pool.remoteRecovery()));
  const buyer = position.connect(f.l1.signers[3]); await tx(buyer.requestExits([pubkey]));
  const root = event(buyer, await tx(buyer.queueWithdrawal(eth(32))), 'WithdrawalQueued').root;
  await tx(f.dm.slash(position.target, 1500)); await f.advance(86401); await tx(buyer.startCheckpoint(false)); await tx(buyer.completeWithdrawal(root));
  console.log('5. Further simulated slash during the withdrawal queue; buyer ultimately receives', formatEther(await f.l1.provider.getBalance(position.target)), 'ETH in the controlled vault.');
  console.log('LOCAL MOCK DEMO ONLY: no live chains, validator signatures, beacon proofs or real CCIP verification were used.');
} finally { await f.close(); }
