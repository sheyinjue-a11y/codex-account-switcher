'use strict';
// Writable local copy only. Never change Electron integrity fuses or store files.
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const hash = b => crypto.createHash('sha256').update(b).digest('hex');

function patchLauncher(input, oldHeaderHash, newHeaderHash) {
  if (![oldHeaderHash, newHeaderHash].every(h => /^[a-f0-9]{64}$/.test(h))) throw Error('Invalid header hash');
  if (input.toString('ascii', 0, 2) !== 'MZ') throw Error('Expected Windows PE executable');
  const source = input.toString('latin1');
  const integrity = [...source.matchAll(/\[\{"file":"resources\\\\app\.asar","alg":"SHA256","value":"([a-f0-9]{64})"\}\]/g)];
  if (integrity.length !== 1 || integrity[0][1] !== oldHeaderHash) throw Error('Unexpected embedded ASAR integrity resource');
  // Store activation resolves the versioned private assembly. An unpackaged copy
  // instead loads the identical chrome_elf.dll beside its executable.
  const assemblies = [...source.matchAll(/<dependency>\s*<dependentAssembly>\s*<assemblyIdentity\s+type="win32"\s+name="(\d+\.\d+\.\d+\.\d+)"\s+version="\1"\s+language="\*"\s*\/>\s*<\/dependentAssembly>\s*<\/dependency>/g)];
  if (assemblies.length !== 1) throw Error('Unexpected private assembly manifest');
  const result = Buffer.from(input);
  const offset = integrity[0].index + integrity[0][0].indexOf(oldHeaderHash);
  result.write(newHeaderHash, offset, 64, 'ascii');
  result.fill(32, assemblies[0].index, assemblies[0].index + assemblies[0][0].length);
  return {buffer: result, sourceSha256: hash(input), sha256: hash(result), privateAssembly: assemblies[0][1], oldHeaderHash, newHeaderHash};
}

module.exports = {patchLauncher};
if (require.main === module) {
  try {
    const [source, output, before, after, ...extra] = process.argv.slice(2);
    if (extra.length || !after || path.resolve(source).toLowerCase() === path.resolve(output).toLowerCase()) throw Error('Usage: node local-client-core.cjs source.exe new.exe old-header-hash new-header-hash');
    const {buffer, ...report} = patchLauncher(fs.readFileSync(source), before, after);
    fs.writeFileSync(output, buffer, {flag:'wx'});
    console.log(JSON.stringify(report));
  } catch (error) { console.error(error.message); process.exitCode=1; }
}
