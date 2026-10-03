import { JsonRpcProvider, Wallet, Contract } from 'ethers';
import { compile } from './compile.mjs';

async function main() {
  const [appAddress, indexText] = process.argv.slice(2);
  if (!appAddress || !indexText || !process.env.DISPATCH_RPC || !process.env.DISPATCHER_PRIVATE_KEY) throw new Error('Missing dispatcher configuration');
  const provider = new JsonRpcProvider(process.env.DISPATCH_RPC);
  const chainId = (await provider.getNetwork()).chainId;
  if (chainId !== 11155111n && chainId !== 421614n) throw new Error('Sepolia testnets only');
  const wallet = new Wallet(process.env.DISPATCHER_PRIVATE_KEY, provider);
  const { MessageApp, CCIPGateway } = compile();
  const app = new Contract(appAddress, MessageApp.abi, wallet);
  const gateway = new Contract(await app.messenger(), CCIPGateway.abi, wallet);
  const payload = await app.outbox(BigInt(indexText)); const fee = await gateway.quote(payload);
  const transaction = await app.dispatch(BigInt(indexText), { value: fee }); console.log('Dispatch transaction:', transaction.hash);
  await transaction.wait(); console.log('Submitted. Destination execution and acknowledgement are separate steps.');
}
main().catch(() => { console.error('Dispatch failed. Check app address, index, RPC, lane configuration and fee funding.'); process.exitCode = 1; });
