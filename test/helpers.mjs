import fs from 'node:fs';
import path from 'node:path';
import ganache from 'ganache';
import { BrowserProvider, ContractFactory, Contract, parseEther, parseUnits } from 'ethers';
import { root } from '../scripts/compile.mjs';

export const eth = n => parseEther(String(n));
export const usd = n => parseUnits(String(n), 6);
export const WAD = 10n ** 18n;
export const artifacts = JSON.parse(fs.readFileSync(path.join(root, 'artifacts/contracts.json'), 'utf8'));
export async function tx(promise) { return (await promise).wait(); }
export function event(contract, receipt, name) {
  for (const log of receipt.logs) {
    try { const parsed = contract.interface.parseLog(log); if (parsed?.name === name) return parsed.args; } catch {}
  }
  throw new Error(`Missing ${name}`);
}
export async function clock(provider) { return Number((await provider.send('eth_getBlockByNumber', ['latest', false])).timestamp); }
export async function deploy(chain, name, args = [], signer = chain.signers[0]) {
  const a = artifacts[name]; const c = await new ContractFactory(a.abi, a.bytecode, signer).deploy(...args); await c.waitForDeployment(); return c;
}
async function chain() {
  const engine = ganache.provider({ chain: { chainId: 31337, hardfork: 'shanghai', time: new Date('2026-10-03T00:00:00Z') },
    miner: { timestampIncrement: 0 }, wallet: { deterministic: true, defaultBalance: 10000 }, logging: { quiet: true } });
  const provider = new BrowserProvider(engine, undefined, { cacheTimeout: -1 }); provider.pollingInterval = 10;
  const signers = await Promise.all(Array.from({ length: 8 }, (_, i) => provider.getSigner(i)));
  return { engine, provider, signers, addresses: await Promise.all(signers.map(s => s.getAddress())) };
}
export async function fixture({ guard = false, globalCap = usd(1000000) } = {}) {
  const l1 = await chain(); const l2 = await chain();
  const owner = l1.addresses[0], user = l1.addresses[1];
  const m1 = await deploy(l1, 'MockMessenger', [owner, 111]); const m2 = await deploy(l2, 'MockMessenger', [owner, 222]);
  const u1 = await deploy(l1, 'MockUSDC', [owner]); const u2 = await deploy(l2, 'MockUSDC', [owner]);
  const weth = await deploy(l1, 'MockWETH');
  const ethFeed = await deploy(l1, 'MockFeed', [owner, 8, 3000n * 10n ** 8n]);
  const usdcFeed = await deploy(l1, 'MockFeed', [owner, 8, 10n ** 8n]);
  const oracle = await deploy(l1, 'CollateralOracle', [ethFeed.target, usdcFeed.target, 18, 3600, 10000, 0, '0x0000000000000000000000000000000000000000']);
  const model = await deploy(l1, 'InterestModel', [2n * WAD / 100n, 8n * WAD / 100n, 90n * WAD / 100n, 8n * WAD / 10n, WAD]);
  const hub = await deploy(l1, 'CreditHub', [owner, m1.target, 111, u1.target, weth.target, model.target, globalCap]);
  let uptime, sequencer;
  if (guard) {
    uptime = await deploy(l2, 'MockFeed', [owner, 0, 0]);
    const now = await clock(l2.provider); await tx(uptime.set(0, now - 3601, now));
    sequencer = await deploy(l2, 'SequencerGuard', [uptime.target, 3600]);
  }
  const pool = await deploy(l2, 'ArbitrumPool', [owner, m2.target, 222, u2.target, sequencer?.target ?? '0x0000000000000000000000000000000000000000', usd(100)]);
  await tx(hub.configurePeer(222, pool.target)); await tx(pool.configurePeer(111, hub.target));
  await tx(hub.registerMarket(weth.target, oracle.target, 5500, 7500, 500, usd(1000000), false));
  await tx(u2.mint(l2.addresses[2], usd(100000))); await tx(u2.connect(l2.signers[2]).approve(pool.target, usd(100000)));
  await tx(pool.connect(l2.signers[2]).deposit(usd(100000), l2.addresses[2]));
  await tx(u1.mint(l1.addresses[3], usd(1000000))); await tx(u1.connect(l1.signers[3]).approve(hub.target, usd(1000000)));
  const f = { l1, l2, owner, user, m1, m2, u1, u2, weth, ethFeed, usdcFeed, oracle, model, hub, pool, uptime, sequencer };
  f.close = async () => { await l1.engine.disconnect(); await l2.engine.disconnect(); };
  f.advance = async seconds => {
    const now = Math.max(await clock(l1.provider), await clock(l2.provider)) + seconds;
    for (const c of [l1, l2]) { await c.provider.send('evm_setTime', [now * 1000]); await c.provider.send('evm_mine', []); }
  };
  f.refresh = async (price = 3000, usdcPrice = 1) => {
    const now = await clock(l1.provider);
    await tx(ethFeed.set(parseUnits(String(price), 8), now, now)); await tx(usdcFeed.set(parseUnits(String(usdcPrice), 8), now, now));
  };
  f.deliver = async (packet, fromHub) => tx((fromHub ? m2 : m1).deliver(packet.source, packet.sender, packet.receiver, packet.payload));
  f.relay = async (app, index) => {
    const fromHub = app === hub; const messenger = fromHub ? m1 : m2;
    await tx(app.dispatch(index ?? await app.outboxCount()));
    const packet = await messenger.packet(await messenger.count()); await f.deliver(packet, fromHub); return packet;
  };
  f.prepare = async (amount = usd(1000), actor = 1) => {
    const deadline = await clock(l2.provider) + 3600;
    const receipt = await tx(pool.connect(l2.signers[actor]).requestBorrow(amount, l2.addresses[actor], deadline));
    return event(pool, receipt, 'BorrowPrepared').id;
  };
  f.borrow = async (amount = usd(1000), actor = 1) => {
    const id = await f.prepare(amount, actor); await f.relay(pool); await f.relay(hub); await f.relay(pool); return id;
  };
  f.native = async (actor = 1, cap = usd(100000)) => {
    if (!f.factory) {
      f.dm = await deploy(l1, 'MockDelegationManager', [owner]); f.pm = await deploy(l1, 'MockEigenPodManager', [f.dm.target]);
      await tx(f.dm.setManager(f.pm.target)); f.factory = await deploy(l1, 'EigenPodPositionFactory', [owner, f.pm.target, f.dm.target]);
      await tx(f.factory.setOperator(l1.addresses[6], true)); await tx(f.factory.setEnabled(true));
    }
    const receipt = await tx(f.factory.connect(l1.signers[actor]).create(l1.addresses[6], 3600));
    const address = event(f.factory, receipt, 'PositionCreated').position;
    const position = new Contract(address, artifacts.EigenPodPosition.abi, l1.signers[actor]);
    const pubkey = '0x' + '11'.repeat(48); const signature = '0x' + '22'.repeat(96);
    await tx(position.stakeValidator(pubkey, signature, '0x' + '33'.repeat(32), { value: eth(32) }));
    await tx(position.delegate(['0x', 0], '0x' + '00'.repeat(32))); await tx(position.startCheckpoint(false));
    const nativeOracle = await deploy(l1, 'CollateralOracle', [ethFeed.target, usdcFeed.target, 18, 3600, 7500, 2, position.target]);
    await tx(hub.registerMarket(position.target, nativeOracle.target, 3000, 5000, 500, cap, true));
    await tx(position.approve(hub.target, WAD)); await tx(hub.connect(l1.signers[actor]).depositCollateral(position.target, WAD));
    return { position, nativeOracle, pubkey, actor };
  };
  return f;
}
