'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const vm = require('node:vm');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { transformScripts, readArchive, readExact, integrityFor, encodeHeader, inspectArchive, buildArchive } = require('./patch-core.cjs');

const uiFixture = 'function ui(auth,requirements){let allowed=auth?.authMethod===`chatgpt`||auth?.authMethod===`personalAccessToken`;let data={requirements};let loading=false;let eligible=allowed&&!loading&&data!=null&&data?.requirements?.featureRequirements?.fast_mode!==!1;return{isServiceTierAllowed:eligible,isLoading:loading}}';
const requestFixture = 'async function request(auth,requirements){let method=await Promise.resolve(auth);if(method!==`chatgpt`&&method!==`personalAccessToken`)return!1;let result=await Promise.resolve({requirements});return Object.assign({},result),result.requirements?.featureRequirements?.fast_mode!==!1}';
const fixture = `${uiFixture};${requestFixture}`;
const transform = source => transformScripts([{ path: 'webview/random-bundle.js', source }]).entries[0].patchedSource;
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const patchedFunctions = () => vm.runInNewContext(`${transform(fixture)};({ui,request})`);

test('regression: API key login must be eligible for Fast', () => {
  const original = vm.runInNewContext(`(${uiFixture})`);
  assert.equal(original({ authMethod: 'apikey' }, {}).isServiceTierAllowed, false);
  const { ui } = patchedFunctions();
  assert.equal(ui({ authMethod: 'apikey' }, {}).isServiceTierAllowed, true);
});

test('request gate permits API while preserving all other authentication outcomes', async () => {
  const { ui, request } = patchedFunctions();
  for (const auth of ['apikey', 'chatgpt', 'personalAccessToken', null, undefined, 'copilot', 'amazonBedrock', 'bedrockApiKey', 'bedrockAccessKeys', 'somethingNew']) {
    const expected = ['apikey', 'chatgpt', 'personalAccessToken'].includes(auth);
    assert.equal(ui(auth == null ? auth : { authMethod: auth }, {}).isServiceTierAllowed, expected, String(auth));
    assert.equal(await request(auth, {}), expected, String(auth));
  }
});

test('explicit fast_mode=false remains authoritative for every permitted auth type', async () => {
  const { ui, request } = patchedFunctions();
  for (const auth of ['apikey', 'chatgpt', 'personalAccessToken']) {
    const requirements = { featureRequirements: { fast_mode: false } };
    assert.equal(ui({ authMethod: auth }, requirements).isServiceTierAllowed, false);
    assert.equal(await request(auth, requirements), false);
  }
});

test('semantic matching survives renamed variables, strings, and split bundle filenames', () => {
  const renamed = fixture.replaceAll('auth', 'a77').replaceAll('allowed', 'b88').replaceAll('eligible', 'c99').replaceAll('method', 'd00').replaceAll('ui(', 'newUI(').replaceAll('request(', 'newRequest(').replaceAll('`chatgpt`', '"chatgpt"');
  // The stable authMethod field must not be renamed with its local variable.
  const source = renamed.replaceAll('a77Method', 'authMethod');
  const result = transformScripts([
    { path: 'webview/no-hash-name.js', source: source.slice(0, source.indexOf(';async')) },
    { path: 'webview/other-name.js', source: source.slice(source.indexOf(';async') + 1) }
  ]);
  assert.equal(result.entries.length, 2);
  assert.equal(result.entries.flatMap(entry => entry.gates).length, 2);
  assert.ok(result.entries.every(entry => entry.patchedSource.includes('apikey')));
});

test('patch is idempotent and rejects missing, extra, mixed, and unknown gate structures', () => {
  const patched = transform(fixture);
  assert.equal(transform(patched), patched);
  assert.equal(transformScripts([{ path: 'webview/a.js', source: patched }]).alreadyPatched, true);
  for (const source of [
    uiFixture,
    fixture + ';' + uiFixture.replace('ui(', 'duplicate('),
    fixture.replace('||auth?.authMethod===`personalAccessToken`', '||auth?.authMethod===`personalAccessToken`||auth?.authMethod===`copilot`'),
    fixture.replace('data?.requirements?.featureRequirements?.fast_mode!==!1', 'true'),
    transformScripts([{ path: 'webview/a.js', source: fixture }]).entries[0].patchedSource.split(';async')[0] + ';' + requestFixture,
    fixture.replace('return!1', 'return!0'),
    fixture.replace('result.requirements?.featureRequirements?.fast_mode!==!1', 'true')
  ]) assert.throws(() => transform(source));
});

function makeArchive(targetPath, source = fixture, options = {}) {
  const script = Buffer.from(source);
  const untouched = Buffer.from([0, 1, 2, 255, 42]);
  const scriptEntry = { size: script.length, offset: '0', integrity: integrityFor(script, 64) };
  if (options.badHash) scriptEntry.integrity.hash = '0'.repeat(64);
  if (options.outside) scriptEntry.offset = '99999999';
  const unchangedEntry = { size: untouched.length, offset: options.overlap ? '1' : String(script.length), integrity: integrityFor(untouched, 64) };
  const header = { files: { webview: { files: { assets: { files: { 'some-new-name.js': scriptEntry } } } }, 'untouched.bin': unchangedEntry, 'deduplicated.bin': { ...unchangedEntry } } };
  fs.writeFileSync(targetPath, Buffer.concat([encodeHeader(header), script, untouched]));
  return { script, untouched };
}

function archiveFile(archivePath, entryPath) {
  const archive = readArchive(archivePath);
  try {
    const entry = archive.entries.find(entry => entry.path === entryPath);
    assert.ok(entry);
    return readExact(archive.fd, entry.size, archive.dataStart + entry.offset);
  } finally { fs.closeSync(archive.fd); }
}

test('ASAR build roundtrip, preserved non-target bytes, source immutability, and idempotence', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-fast-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const original = path.join(directory, 'original.asar');
  const output = path.join(directory, 'patched.asar');
  const duplicate = path.join(directory, 'duplicate.asar');
  const { untouched } = makeArchive(original);
  const beforeHash = hash(fs.readFileSync(original));
  const inspected = inspectArchive(original);
  assert.equal(inspected.status, 'patchable');
  assert.equal(inspected.targetEntries.length, 1);
  assert.deepEqual(inspected.targetEntries[0].gates.map(gate => gate.role).sort(), ['request', 'ui']);
  const built = buildArchive(original, output);
  assert.equal(built.status, 'built');
  assert.equal(built.alreadyPatched, false);
  assert.equal(hash(fs.readFileSync(original)), beforeHash);
  assert.equal(inspectArchive(output).status, 'patched');
  assert.deepEqual(archiveFile(output, 'untouched.bin'), untouched);
  assert.deepEqual(archiveFile(output, 'deduplicated.bin'), untouched);
  assert.match(archiveFile(output, 'webview/assets/some-new-name.js').toString(), /apikey/);
  assert.equal(buildArchive(output, duplicate).alreadyPatched, true);
  assert.equal(hash(fs.readFileSync(output)), hash(fs.readFileSync(duplicate)));
  assert.throws(() => buildArchive(original, original), /Output must not/);
  assert.throws(() => buildArchive(original, output), /EEXIST/);
});

test('ASAR refuses corrupted target hashes and unsafe bounds without leaving output', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-fast-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const original = path.join(directory, 'original.asar');
  const output = path.join(directory, 'output.asar');
  for (const options of [{ badHash: true }, { outside: true }, { overlap: true }]) {
    makeArchive(original, fixture, options);
    assert.throws(() => buildArchive(original, output), /integrity mismatch|outside archive|overlapping/);
    assert.equal(fs.existsSync(output), false);
  }
});
