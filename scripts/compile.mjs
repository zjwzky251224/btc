import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';
import { fileURLToPath } from 'node:url';

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export function compile() {
  const sources = {};
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const name = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(name);
      else if (name.endsWith('.sol')) sources[path.relative(root, name).replaceAll('\\', '/')] = { content: fs.readFileSync(name, 'utf8') };
    }
  }
  walk(path.join(root, 'contracts'));
  const output = JSON.parse(solc.compile(JSON.stringify({
    language: 'Solidity', sources,
    settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: 'shanghai',
      outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object'] } } }
  }), { import: name => {
    const resolved = name.replace(/(@openzeppelin\/contracts(?:-upgradeable)?)@([\d.]+)\//, '$1-$2/');
    const target = path.join(root, 'node_modules', resolved);
    return fs.existsSync(target) ? { contents: fs.readFileSync(target, 'utf8') } : { error: `Missing import: ${name}` };
  }}));
  const errors = (output.errors ?? []).filter(x => x.severity === 'error');
  if (errors.length) throw new Error(errors.map(x => x.formattedMessage).join('\n'));
  for (const warning of output.errors ?? []) console.warn(warning.formattedMessage);
  fs.mkdirSync(path.join(root, 'artifacts'), { recursive: true });
  const artifacts = {};
  for (const [source, contracts] of Object.entries(output.contracts)) {
    if (!source.startsWith('contracts/')) continue;
    for (const [name, artifact] of Object.entries(contracts)) {
      artifacts[name] = { source, abi: artifact.abi, bytecode: `0x${artifact.evm.bytecode.object}`, deployedBytecode: `0x${artifact.evm.deployedBytecode.object}` };
      if (artifact.evm.deployedBytecode.object.length / 2 > 24576) throw new Error(`${name} exceeds EIP-170`);
    }
  }
  fs.writeFileSync(path.join(root, 'artifacts', 'contracts.json'), JSON.stringify(artifacts, null, 2));
  console.log(`Compiled ${Object.keys(artifacts).length} contracts with solc ${solc.version()}`);
  return artifacts;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) compile();
