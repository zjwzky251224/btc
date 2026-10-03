import fs from 'node:fs';
import { JsonRpcProvider, Wallet, ContractFactory, isAddress, ZeroAddress, parseUnits } from 'ethers';
import { compile, root } from './compile.mjs';
import path from 'node:path';

// Deliberately restricted to testnets. Never invoked by compile, tests or demo.
async function main() {
  const configPath = process.argv[2];
  if (!configPath) throw new Error('Usage: node scripts/deploy-ccip.mjs config/testnet.local.json');
  const cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const key = process.env.DEPLOYER_PRIVATE_KEY;
  if (!key || !/^0x[0-9a-fA-F]{64}$/.test(key)) throw new Error('Missing DEPLOYER_PRIVATE_KEY');
  const selectors = [BigInt(cfg.ethereumSelector), BigInt(cfg.arbitrumSelector)];
  if (selectors.some(x => x <= 0n || x > (1n << 64n) - 1n) || selectors[0] === selectors[1]) throw new Error('Configure real CCIP selectors');
  const rpc = [new JsonRpcProvider(cfg.ethereumRpc), new JsonRpcProvider(cfg.arbitrumRpc)];
  const networks = await Promise.all(rpc.map(p => p.getNetwork()));
  if (networks[0].chainId !== 11155111n || networks[1].chainId !== 421614n) throw new Error('Sepolia testnets only');
  const required = [[cfg.ethereumRouter, cfg.ethereumUsdc, cfg.ethereumWeth, cfg.ethUsdFeed, cfg.usdcUsdFeed, cfg.ethereumGovernance],
    [cfg.arbitrumRouter, cfg.arbitrumUsdc, cfg.sequencerFeed, cfg.arbitrumGovernance]];
  for (let i = 0; i < 2; i++) for (const address of required[i]) {
    if (!isAddress(address) || address === ZeroAddress || await rpc[i].getCode(address) === '0x') throw new Error('Missing deployed contract');
  }
  const r = cfg.risk;
  if (!(r.ltvBps > 0 && r.ltvBps < r.liquidationBps && r.liquidationBps < 10000 && r.bonusBps <= 2500)) throw new Error('Invalid risk parameters');
  const artifacts = compile(); const wallets = rpc.map(p => new Wallet(key, p)); const owner = await wallets[0].getAddress();
  const deployed = {};
  // Persist progress after each deployment; failed partial deployments must not be mistaken for completion.
  const output = path.join(root, 'artifacts', 'testnet-deployment.json');
  async function save() { fs.writeFileSync(output, JSON.stringify({ completed: false, ...deployed }, null, 2)); }
  async function deploy(name, chain, args, label = name) {
    const a = artifacts[name]; const c = await new ContractFactory(a.abi, a.bytecode, wallets[chain]).deploy(...args);
    await c.waitForDeployment(); deployed[label] = c.target; await save(); console.log(label, c.target); return c;
  }
  async function send(promise) { await (await promise).wait(); }
  const model = await deploy('InterestModel', 0, [parseUnits('0.02',18), parseUnits('0.08',18), parseUnits('0.9',18), parseUnits('0.8',18), parseUnits('1',18)]);
  const ethGateway = await deploy('CCIPGateway', 0, [owner, cfg.ethereumRouter, 800000], 'EthereumGateway');
  const arbGateway = await deploy('CCIPGateway', 1, [owner, cfg.arbitrumRouter, 800000], 'ArbitrumGateway');
  const hub = await deploy('CreditHub', 0, [owner, ethGateway.target, selectors[0], cfg.ethereumUsdc, cfg.ethereumWeth, model.target, parseUnits(r.globalCapUsdc,6)]);
  const guard = await deploy('SequencerGuard', 1, [cfg.sequencerFeed, r.sequencerGraceSeconds]);
  const pool = await deploy('ArbitrumPool', 1, [owner, arbGateway.target, selectors[1], cfg.arbitrumUsdc, guard.target, parseUnits(r.cashFloorUsdc,6)]);
  await send(hub.configurePeer(selectors[1], pool.target)); await send(pool.configurePeer(selectors[0], hub.target));
  await send(ethGateway.bind(hub.target, selectors[1], arbGateway.target, pool.target, cfg.ethereumRequiredCCVs));
  await send(arbGateway.bind(pool.target, selectors[0], ethGateway.target, hub.target, cfg.arbitrumRequiredCCVs));
  const oracle = await deploy('CollateralOracle', 0, [cfg.ethUsdFeed, cfg.usdcUsdFeed, 18, r.priceMaxAgeSeconds, 10000, 0, ZeroAddress]);
  await oracle.value(parseUnits('1',18));
  await send(hub.registerMarket(cfg.ethereumWeth, oracle.target, r.ltvBps, r.liquidationBps, r.bonusBps, parseUnits(r.marketCapUsdc,6), false));
  if (cfg.eigenPodManager !== ZeroAddress || cfg.delegationManager !== ZeroAddress) {
    for (const address of [cfg.eigenPodManager,cfg.delegationManager]) if (!isAddress(address) || await rpc[0].getCode(address) === '0x') throw new Error('EigenLayer addresses unavailable');
    const factory = await deploy('EigenPodPositionFactory', 0, [owner, cfg.eigenPodManager, cfg.delegationManager]);
    await send(factory.transferOwnership(cfg.ethereumGovernance)); // Still disabled; no operator admitted.
  }
  await send(hub.transferOwnership(cfg.ethereumGovernance)); await send(ethGateway.transferOwnership(cfg.ethereumGovernance));
  await send(pool.transferOwnership(cfg.arbitrumGovernance)); await send(arbGateway.transferOwnership(cfg.arbitrumGovernance));
  fs.writeFileSync(output, JSON.stringify({ completed: true, ...deployed }, null, 2));
  console.log('Testnet contracts deployed. Native restaking remains disabled; fund the pool and run actual lane integration checks separately.');
}
main().catch(() => { console.error('Deployment incomplete. Check configuration, testnet funding and artifacts/testnet-deployment.json. No private keys are logged.'); process.exitCode = 1; });
