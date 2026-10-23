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

const accessHelper = 'function access(response){let features=response.requirements?.featureRequirements,fast=features?.fast_mode!==!1;return{fast,ultrafast:(`supportsIndependentSpeedModes`in response&&response.supportsIndependentSpeedModes===!0||fast)&&features?.ultrafast_mode!==!1}}';
const modernUI = 'function ui(auth,response,pending=false){let allowed=auth?.authMethod===`chatgpt`||auth?.authMethod===`personalAccessToken`,loading=!!auth?.isLoading||allowed&&pending,result;result=allowed&&!loading&&response!=null?readAccess(response):null;let value=result;return{serviceTierAccess:value,isLoading:loading}}';
const modernRequest = 'async function request(auth,response){let method=await Promise.resolve(auth);if(method!==`chatgpt`&&method!==`personalAccessToken`)return null;let data=await Promise.resolve(response);return cache.setData(query,{authMethod:method,hostId:"local"},data),readAccess(data)}';
const modernScripts = () => [
  {path:'webview/assets/shared.js',source:accessHelper+';export {access as speedAccess}'},
  {path:'webview/assets/initial.js',source:'import {speedAccess as readAccess} from "./shared.js";'+modernUI+';'+modernRequest}
];

test('26.1013 split speed access permits API and preserves loading and speed restrictions', async () => {
  const scripts=modernScripts();
  const run=source=>vm.runInNewContext(accessHelper+';const readAccess=access;'+source+';({ui,request})',{cache:{setData(){}},query:{}});
  assert.equal(run(modernUI+';'+modernRequest).ui({authMethod:'apikey'},{requirements:{}}).serviceTierAccess,null);
  const transformed=transformScripts(scripts);
  const {ui,request}=run(transformed.entries[1].patchedSource.replace(/^import[^;]+;/,''));
  for(const auth of ['apikey','chatgpt','personalAccessToken','copilot',null]) {
    for(const fast of [undefined,false,true]) for(const ultrafast of [undefined,false,true]) {
      const response={requirements:{featureRequirements:{fast_mode:fast,ultrafast_mode:ultrafast}}};
      const expected=['apikey','chatgpt','personalAccessToken'].includes(auth)?{fast:fast!==false,ultrafast:fast!==false&&ultrafast!==false}:null;
      assert.equal(JSON.stringify(ui({authMethod:auth},response).serviceTierAccess),JSON.stringify(expected));
      assert.equal(JSON.stringify(await request(auth,response)),JSON.stringify(expected));
    }
  }
  assert.equal(ui({authMethod:'apikey'},{requirements:{}},true).serviceTierAccess,null);
  assert.equal(ui({authMethod:'apikey',isLoading:true},{requirements:{}}).serviceTierAccess,null);
  assert.equal(ui({authMethod:'apikey'},null).serviceTierAccess,null);
  const independent={requirements:{featureRequirements:{fast_mode:false}},supportsIndependentSpeedModes:true};
  assert.equal(JSON.stringify(await request('apikey',independent)),JSON.stringify({fast:false,ultrafast:true}));
  assert.equal(transformScripts(transformed.entries.map(e=>({path:e.path,source:e.patchedSource}))).alreadyPatched,true);
  assert.equal(transformed.entries[0].patchedSource,scripts[0].source);
});

test('split speed access rejects unresolved helpers and changed authorization structure', () => {
  for(const change of [
    s=>s.slice(1),
    s=>s.map(e=>({...e,source:e.source.replace('features?.fast_mode!==!1','true')})),
    s=>s.map(e=>({...e,source:e.source.replace('allowed&&!loading&&response!=null','!loading&&response!=null')})),
    s=>s.map(e=>({...e,source:e.source.replace('allowed&&!loading&&response!=null','allowed||!loading&&response!=null')})),
    s=>s.map(e=>({...e,source:e.source.replace('return null;let data','return true;let data')})),
    s=>s.map(e=>({...e,source:e.source.replace('readAccess(data)','otherAccess(data)')}))
  ]) assert.throws(()=>transformScripts(change(modernScripts())));
});

test('split speed access survives renamed helpers and React memo assignments', () => {
  const scripts=modernScripts().map(e=>({...e,source:e.source.replaceAll('readAccess','renamedHelper').replaceAll('speedAccess','renamedExport')}));
  scripts[1].source=scripts[1].source.replace('result=allowed&&!loading&&response!=null?renamedHelper(response):null;', 'let memo=[];memo[0]!==response?(result=allowed&&!loading&&response!=null?renamedHelper(response):null,memo[0]=response,memo[1]=result):result=memo[1];');
  assert.equal(transformScripts(scripts).entries.flatMap(e=>e.gates).length,2);
});

const bedrockScripts = () => modernScripts().map(entry => ({
  ...entry,
  source: entry.source
    .replace('auth?.authMethod===`personalAccessToken`', 'auth?.authMethod===`personalAccessToken`||auth?.authMethod===`amazonBedrock`')
    .replace('method!==`personalAccessToken`', 'method!==`personalAccessToken`&&method!==`amazonBedrock`')
}));

test('26.1016 Bedrock allow-list adds only API eligibility and preserves speed restrictions', async () => {
  const scripts = bedrockScripts();
  const run = source => vm.runInNewContext(accessHelper+';const readAccess=access;'+source.replace(/^import[^;]+;/,'')+';({ui,request})', {cache:{setData(){}},query:{}});
  const original = run(scripts[1].source);
  const transformed = transformScripts(scripts);
  const patched = run(transformed.entries[1].patchedSource);
  assert.equal(transformed.entries.flatMap(entry => entry.gates).length, 2);
  assert.equal(transformed.entries[0].patchedSource, scripts[0].source);
  for (const authMethod of ['apikey','chatgpt','personalAccessToken','amazonBedrock','bedrockApiKey','bedrockAccessKeys','copilot','futureAuth',null,undefined]) {
    for (const fast of [undefined,false,true]) for (const ultrafast of [undefined,false,true]) {
      for (const supportsIndependentSpeedModes of [false,true]) {
        const response = {requirements:{featureRequirements:{fast_mode:fast,ultrafast_mode:ultrafast}},supportsIndependentSpeedModes};
        const expected = ['apikey','chatgpt','personalAccessToken','amazonBedrock'].includes(authMethod)
          ? {fast:fast!==false,ultrafast:(supportsIndependentSpeedModes||fast!==false)&&ultrafast!==false} : null;
        assert.equal(JSON.stringify(patched.ui({authMethod},response).serviceTierAccess), JSON.stringify(expected));
        assert.equal(JSON.stringify(await patched.request(authMethod,response)), JSON.stringify(expected));
        if (authMethod !== 'apikey') {
          assert.equal(JSON.stringify(patched.ui({authMethod},response)), JSON.stringify(original.ui({authMethod},response)));
          assert.equal(JSON.stringify(await patched.request(authMethod,response)), JSON.stringify(await original.request(authMethod,response)));
        } else assert.equal(original.ui({authMethod},response).serviceTierAccess, null);
      }
    }
  }
  for (const authMethod of ['apikey','amazonBedrock']) {
    assert.equal(patched.ui({authMethod},{requirements:{}},true).serviceTierAccess,null);
    assert.equal(patched.ui({authMethod,isLoading:true},{requirements:{}}).serviceTierAccess,null);
    assert.equal(patched.ui({authMethod},null).serviceTierAccess,null);
  }
  assert.equal(transformScripts(transformed.entries.map(entry => ({path:entry.path,source:entry.patchedSource}))).alreadyPatched,true);
});

test('known Bedrock variant still refuses unknown, duplicate, and partially patched allow-lists', () => {
  for (const replacement of ['copilot','bedrockApiKey','bedrockAccessKeys','futureAuth','personalAccessToken']) {
    assert.throws(() => transformScripts(bedrockScripts().map(entry => ({...entry,source:entry.source.replaceAll('amazonBedrock',replacement)}))));
  }
  assert.throws(() => transformScripts(bedrockScripts().map(entry => ({...entry,source:entry.source.replace('||auth?.authMethod===`amazonBedrock`','||auth?.authMethod===`amazonBedrock`||auth?.authMethod===`futureAuth`')}))));
  assert.throws(() => transformScripts(bedrockScripts().map(entry => ({...entry,source:entry.source.replace('||auth?.authMethod===`amazonBedrock`','||auth?.authMethod===`amazonBedrock`||auth?.authMethod===`apikey`')}))));
});

test('split ASAR build resolves helper imports and preserves the helper bytes', t => {
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'codex-fast-split-test-'));
  t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));
  const original=path.join(directory,'original.asar'),output=path.join(directory,'patched.asar');
  const scripts=modernScripts(),files={},buffers=[];
  let offset=0;
  for(const script of scripts) {
    const buffer=Buffer.from(script.source);
    files[path.posix.basename(script.path)]={size:buffer.length,offset:String(offset),integrity:integrityFor(buffer,64)};
    buffers.push(buffer);offset+=buffer.length;
  }
  fs.writeFileSync(original,Buffer.concat([encodeHeader({files:{webview:{files:{assets:{files}}}}}),...buffers]));
  assert.equal(inspectArchive(original).status,'patchable');
  assert.equal(buildArchive(original,output).targetEntries.length,1);
  assert.deepEqual(archiveFile(output,scripts[0].path),buffers[0]);
  assert.equal(inspectArchive(output).status,'patched');
});

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
