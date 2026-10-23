'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const acorn = require('acorn');

const ENGINE_VERSION = 3;
const MAX_HEADER = 32 * 1024 * 1024;
const MAX_SCRIPT = 32 * 1024 * 1024;
const AUTH_TYPES = ['chatgpt', 'personalAccessToken'];
// Official 26.1016 also permits Bedrock. Recognize only these observed lists;
// unknown authentication variants still require a reviewed compatibility update.
const AUTH_TYPE_SETS = [AUTH_TYPES, [...AUTH_TYPES, 'amazonBedrock']];
const sha256 = buffer => crypto.createHash('sha256').update(buffer).digest('hex');
const fail = message => { throw new Error(message); };
const isFunction = node => /^(FunctionDeclaration|FunctionExpression|ArrowFunctionExpression)$/.test(node.type);

function children(node) {
  const result = [];
  for (const value of Object.values(node)) {
    if (value && typeof value === 'object') {
      if (Array.isArray(value)) {
        for (const item of value) if (item && typeof item.type === 'string') result.push(item);
      } else if (typeof value.type === 'string') result.push(value);
    }
  }
  return result;
}

function nodesWithin(root, skipNestedFunctions = false) {
  const result = [];
  const stack = [root];
  while (stack.length) {
    const node = stack.pop();
    if (skipNestedFunctions && node !== root && isFunction(node)) continue;
    result.push(node);
    stack.push(...children(node));
  }
  return result;
}

function unwrap(node) { return node?.type === 'ChainExpression' ? node.expression : node; }
function literal(node) {
  if (node?.type === 'Literal') return node.value;
  if (node?.type === 'TemplateLiteral' && node.expressions.length === 0) return node.quasis[0].value.cooked;
}
function propertyName(node) {
  if (!node) return undefined;
  if (!node.computed && node.property?.type === 'Identifier') return node.property.name;
  return literal(node.property);
}
function keyName(node) { return node.key?.type === 'Identifier' && !node.computed ? node.key.name : literal(node.key); }
function isFalse(node) { return literal(node) === false || (node?.type === 'UnaryExpression' && node.operator === '!' && literal(node.argument) === 1); }
function reference(node) {
  node = unwrap(node);
  if (node?.type === 'Identifier') return `id:${node.name}`;
  if (node?.type === 'MemberExpression') {
    const object = reference(node.object);
    const key = propertyName(node);
    return object && key ? `${object}.${node.optional ? '?' : ''}${key}` : undefined;
  }
}

function allowList(node, negative) {
  const operator = negative ? '&&' : '||';
  if (node.type !== 'LogicalExpression' || node.operator !== operator) return null;
  const leaves = [];
  const stack = [node];
  while (stack.length) {
    const part = stack.pop();
    if (part.type === 'LogicalExpression' && part.operator === operator) stack.push(part.right, part.left);
    else leaves.push(part);
  }
  const types = [];
  let authReference;
  for (const part of leaves) {
    if (part.type !== 'BinaryExpression' || part.operator !== (negative ? '!==' : '===')) return null;
    const type = literal(part.right);
    const ref = reference(part.left);
    if (typeof type !== 'string' || !ref || (authReference && authReference !== ref)) return null;
    authReference = ref;
    types.push(type);
  }
  const officialTypes = types.filter(type => type !== 'apikey');
  if (new Set(types).size !== types.length || !AUTH_TYPE_SETS.some(expected => officialTypes.length === expected.length && expected.every(type => officialTypes.includes(type)))) return null;
  return { node, negative, authNode: leaves[0].left, authReference, alreadyPatched: types.includes('apikey') };
}

function maximalAllowLists(nodes, negative) {
  const candidates = nodes.map(node => allowList(node, negative)).filter(Boolean);
  return candidates.filter(candidate => !candidates.some(other => other !== candidate && other.node.start <= candidate.node.start && other.node.end >= candidate.node.end));
}

function featureRestriction(node) {
  if (node.type !== 'BinaryExpression' || node.operator !== '!==' || !isFalse(node.right)) return false;
  const member = unwrap(node.left);
  if (member?.type !== 'MemberExpression' || propertyName(member) !== 'fast_mode') return false;
  return propertyName(unwrap(member.object)) === 'featureRequirements';
}

const isNull = node => node?.type === 'Literal' && node.value === null;
const lastExpression = node => node?.type === 'SequenceExpression' ? node.expressions.at(-1) : node;
function singleCall(node) { return node?.type === 'CallExpression' && node.callee.type === 'Identifier' && node.arguments.length === 1; }

// Newer clients compute both speed permissions in an imported helper. Resolve
// that helper before accepting gates; never match generic login allow-lists.
function serviceTierHelper(fn, nodes) {
  if (fn.async || fn.id?.type !== 'Identifier' || fn.params.length !== 1 || fn.params[0].type !== 'Identifier') return false;
  const bindings = nodes.filter(n => n.type === 'VariableDeclarator' && n.id.type === 'Identifier');
  const features = bindings.find(n => propertyName(unwrap(n.init)) === 'featureRequirements' && reference(unwrap(n.init)?.object) === `id:${fn.params[0].name}.requirements`);
  if (!features) return false;
  const fast = bindings.find(n => n.init?.type === 'BinaryExpression' && n.init.operator === '!==' && isFalse(n.init.right) && reference(n.init.left) === `id:${features.id.name}.?fast_mode`);
  const returned = nodes.filter(n => n.type === 'ReturnStatement');
  if (!fast || returned.length !== 1 || returned[0].argument?.type !== 'ObjectExpression') return false;
  const props = returned[0].argument.properties;
  return props.length === 2 && props.some(n => keyName(n) === 'fast' && reference(n.value) === `id:${fast.id.name}`) && props.some(n => keyName(n) === 'ultrafast' && nodesWithin(n.value).some(part => part.type === 'BinaryExpression' && part.operator === '!==' && isFalse(part.right) && reference(part.left) === `id:${features.id.name}.?ultrafast_mode`));
}

function modernGates(fn, nodes) {
  const access = nodes.filter(n => n.type === 'Property' && keyName(n) === 'serviceTierAccess');
  if (!fn.async && access.length) {
    const lists = maximalAllowLists(nodes, false).filter(g => propertyName(unwrap(g.authNode)) === 'authMethod');
    if (lists.length !== 1 || access.length !== 1) return [];
    const gate = lists[0];
    const binding = nodes.find(n => n.type === 'VariableDeclarator' && n.init === gate.node && n.id.type === 'Identifier');
    const loading = nodes.find(n => n.type === 'Property' && keyName(n) === 'isLoading');
    if (!binding || loading?.value.type !== 'Identifier') fail('Unsupported speed access UI bindings');
    const conditions = nodes.filter(n => n.type === 'ConditionalExpression' && isNull(n.alternate) && singleCall(n.consequent));
    const condition = conditions.find(n => {
      // Flatten only conjunctions: an OR must never turn into an auth bypass.
      const parts = [];
      const visit = part => part.type === 'LogicalExpression' && part.operator === '&&' ? (visit(part.left), visit(part.right)) : parts.push(part);
      visit(n.test);
      return parts.length === 3 && parts.some(p => reference(p) === `id:${binding.id.name}`) && parts.some(p => p.type === 'UnaryExpression' && p.operator === '!' && reference(p.argument) === reference(loading.value)) && parts.some(p => p.type === 'BinaryExpression' && p.operator === '!=' && isNull(p.right) && reference(p.left) === reference(n.consequent.arguments[0]));
    });
    if (!condition) fail('Speed access UI restrictions changed');
    // Follow the assignment and aliases used by React Compiler's memo cache.
    const output = nodes.find(n => (n.type === 'AssignmentExpression' && n.operator === '=' && n.right === condition && n.left.type === 'Identifier') || (n.type === 'VariableDeclarator' && n.init === condition && n.id.type === 'Identifier'));
    const names = new Set(output ? [(output.left ?? output.id).name] : []);
    for (let changed = true; changed;) {
      changed = false;
      for (const n of nodes) if (n.type === 'VariableDeclarator' && n.id.type === 'Identifier' && n.init?.type === 'Identifier' && names.has(n.init.name) && !names.has(n.id.name)) { names.add(n.id.name); changed = true; }
    }
    if (!names.has(access[0].value.name)) fail('Speed access UI output changed');
    return [{...gate,role:'ui',helperName:condition.consequent.callee.name}];
  }
  if (!fn.async) return [];
  const lists = maximalAllowLists(nodes, true).filter(g => unwrap(g.authNode)?.type === 'Identifier');
  if (lists.length !== 1) return [];
  const gate = lists[0];
  const statement = nodes.find(n => n.type === 'IfStatement' && n.test === gate.node && !n.alternate);
  const returned = statement?.consequent?.type === 'BlockStatement' && statement.consequent.body.length === 1 ? statement.consequent.body[0] : statement?.consequent;
  if (returned?.type !== 'ReturnStatement' || !isNull(returned.argument)) return [];
  const result = nodes.find(n => n.type === 'ReturnStatement' && n.start > statement.end && singleCall(lastExpression(n.argument)));
  const call = lastExpression(result?.argument);
  if (!call || !nodes.some(n => n.type === 'Property' && keyName(n) === 'authMethod' && reference(n.value) === gate.authReference)) return [];
  if (!nodes.some(n => n.type === 'VariableDeclarator' && reference(n.id) === gate.authReference && n.init?.type === 'AwaitExpression' && n.end < statement.start) || !nodes.some(n => n.type === 'VariableDeclarator' && reference(n.id) === reference(call.arguments[0]) && n.init?.type === 'AwaitExpression' && n.start > statement.end && n.end < result.start)) fail('Speed access request data flow changed');
  return [{...gate,role:'request',helperName:call.callee.name}];
}

function analyzeScript(source) {
  const ast = acorn.parse(source, { ecmaVersion: 'latest', sourceType: 'module', allowHashBang: true });
  const allNodes = nodesWithin(ast);
  const gates = [];
  const helpers = new Set();
  for (const fn of allNodes.filter(isFunction)) {
    const ownNodes = nodesWithin(fn, true);
    if (serviceTierHelper(fn, ownNodes)) helpers.add(fn.id.name);
    const restrictions = ownNodes.filter(featureRestriction);
    if (restrictions.length === 0) { gates.push(...modernGates(fn, ownNodes)); continue; }
    const eligibility = ownNodes.filter(node => node.type === 'Property' && keyName(node) === 'isServiceTierAllowed');
    if (eligibility.length) {
      const lists = maximalAllowLists(ownNodes, false).filter(gate => {
        const member = unwrap(gate.authNode);
        return member?.type === 'MemberExpression' && propertyName(member) === 'authMethod';
      });
      if (fn.async || restrictions.length !== 1 || lists.length !== 1 || eligibility.length !== 1) fail('Unsupported Fast UI gate structure');
      const gate = lists[0];
      const authBinding = ownNodes.find(node => node.type === 'VariableDeclarator' && node.init === gate.node && node.id.type === 'Identifier');
      if (!authBinding) fail('Fast UI authentication binding is not explicit');
      const bindings = new Map(ownNodes.filter(node => node.type === 'VariableDeclarator' && node.id.type === 'Identifier').map(node => [node.id.name, node.init]));
      const value = eligibility[0].value;
      const eligibilityNode = value.type === 'Identifier' ? bindings.get(value.name) : value;
      if (!eligibilityNode || eligibilityNode.type !== 'LogicalExpression' || eligibilityNode.operator !== '&&') fail('Fast UI eligibility no longer uses its restrictions');
      const eligibilityNodes = nodesWithin(eligibilityNode);
      if (!eligibilityNodes.includes(restrictions[0]) || !eligibilityNodes.some(node => node.type === 'Identifier' && node.name === authBinding.id.name)) fail('Fast UI eligibility dependencies changed');
      gates.push({ ...gate, role: 'ui' });
    }
    if (fn.async) {
      const lists = maximalAllowLists(ownNodes, true).filter(gate => unwrap(gate.authNode)?.type === 'Identifier');
      if (lists.length === 0) continue;
      if (restrictions.length !== 1 || lists.length !== 1) fail('Unsupported Fast request gate structure');
      const gate = lists[0];
      const statement = ownNodes.find(node => node.type === 'IfStatement' && node.test === gate.node && !node.alternate);
      const consequence = statement?.consequent;
      const returned = consequence?.type === 'BlockStatement' && consequence.body.length === 1 ? consequence.body[0] : consequence;
      if (returned?.type !== 'ReturnStatement' || !isFalse(returned.argument)) fail('Fast request gate is no longer an early rejection');
      const authName = unwrap(gate.authNode).name;
      if (!ownNodes.some(node => node.type === 'VariableDeclarator' && node.id.type === 'Identifier' && node.id.name === authName && node.init?.type === 'AwaitExpression' && node.end < statement.start)) fail('Fast request authentication source changed');
      if (!ownNodes.some(node => node.type === 'ReturnStatement' && (node.argument?.type === 'SequenceExpression' ? node.argument.expressions.at(-1) : node.argument) === restrictions[0] && node.start > statement.end)) fail('Fast request feature requirements changed');
      gates.push({ ...gate, role: 'request' });
    }
  }
  return {gates, helpers, imports:ast.body.filter(n => n.type === 'ImportDeclaration'), exports:ast.body.filter(n => n.type === 'ExportNamedDeclaration')};
}

function findGates(source) { return analyzeScript(source).gates; }

function transformScripts(scripts) {
  const entries = scripts.map(script => ({ ...script, ...analyzeScript(script.source) }));
  return transformEntries(entries);
}

function transformEntries(entries) {
  const gates = entries.flatMap(entry => entry.gates);
  if (gates.length !== 2 || gates.filter(gate => gate.role === 'ui').length !== 1 || gates.filter(gate => gate.role === 'request').length !== 1) fail(`Expected exactly one UI and one request Fast gate; found ${gates.length}`);
  const modern = gates.filter(g => g.helperName);
  if (modern.length) {
    if (modern.length !== 2) fail('Mixed legacy and speed access gate structures');
    const identities = [];
    for (const entry of entries) for (const gate of entry.gates) {
      let target = entry, name = gate.helperName;
      if (!entry.helpers.has(name)) {
        const imp = entry.imports.find(n => n.specifiers.some(s => s.local.name === name));
        const spec = imp?.specifiers.find(s => s.local.name === name);
        if (spec?.type !== 'ImportSpecifier' || !imp.source.value.startsWith('.')) fail('Unresolved speed access helper');
        const targetPath = path.posix.normalize(path.posix.join(path.posix.dirname(entry.path), imp.source.value));
        target = entries.find(e => e.path === targetPath);
        const exported = target?.exports.flatMap(n => n.specifiers).find(s => (s.exported.name ?? s.exported.value) === (spec.imported.name ?? spec.imported.value));
        name = exported?.local.name;
      }
      if (!target?.helpers.has(name)) fail('Unverified speed access restrictions');
      identities.push(`${target.path}:${name}`);
    }
    if (new Set(identities).size !== 1) fail('UI and request speed access helpers differ');
  }
  if (new Set(gates.map(gate => gate.alreadyPatched)).size !== 1) fail('Mixed patched/unpatched Fast gates require recovery');
  const alreadyPatched = gates.every(gate => gate.alreadyPatched);
  for (const entry of entries) {
    let source = entry.source;
    if (!alreadyPatched) {
      for (const gate of [...entry.gates].sort((a, b) => b.node.start - a.node.start)) {
        const original = source.slice(gate.node.start, gate.node.end);
        const auth = source.slice(gate.authNode.start, gate.authNode.end);
        const replacement = `(${original}${gate.negative ? '&&' : '||'}${auth}${gate.negative ? '!==' : '==='}\`apikey\`)`;
        source = source.slice(0, gate.node.start) + replacement + source.slice(gate.node.end);
      }
      const after = findGates(source);
      if (after.length !== entry.gates.length || after.some(gate => !gate.alreadyPatched)) fail('Post-patch gate verification failed');
    }
    entry.patchedSource = source;
  }
  return { alreadyPatched, entries };
}

function readExact(fd, size, position) {
  const buffer = Buffer.alloc(size);
  let consumed = 0;
  while (consumed < size) {
    const count = fs.readSync(fd, buffer, consumed, size - consumed, position + consumed);
    if (!count) fail('Truncated ASAR archive');
    consumed += count;
  }
  return buffer;
}

function readArchive(archivePath) {
  const fd = fs.openSync(archivePath, 'r');
  try {
    const size = fs.fstatSync(fd).size;
    const prefix = readExact(fd, 16, 0);
    const headerLength = prefix.readUInt32LE(4);
    const jsonLength = prefix.readUInt32LE(12);
    if (prefix.readUInt32LE(0) !== 4 || headerLength < 8 || headerLength > MAX_HEADER || headerLength % 4 !== 0 || prefix.readUInt32LE(8) !== headerLength - 4 || jsonLength > headerLength - 8 || jsonLength < 2) fail('Invalid ASAR pickle header');
    const dataStart = 8 + headerLength;
    if (dataStart > size) fail('ASAR header exceeds archive');
    const json = readExact(fd, jsonLength, 16);
    const header = JSON.parse(json.toString('utf8'));
    if (!header?.files || Array.isArray(header.files)) fail('Invalid ASAR file tree');
    const entries = [];
    const stack = [{ directory: header, prefix: '' }];
    while (stack.length) {
      const { directory, prefix: entryPrefix } = stack.pop();
      if (!directory.files || typeof directory.files !== 'object' || Array.isArray(directory.files)) fail('Invalid ASAR directory');
      for (const [name, entry] of Object.entries(directory.files)) {
        if (!name || name === '.' || name === '..' || /[\\/\0]/.test(name) || !entry || typeof entry !== 'object') fail('Unsafe ASAR entry');
        const entryPath = entryPrefix + name;
        if (entry.files) stack.push({ directory: entry, prefix: entryPath + '/' });
        else if (!entry.unpacked && !entry.link) {
          const offset = typeof entry.offset === 'string' && /^\d+$/.test(entry.offset) ? Number(entry.offset) : NaN;
          if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(entry.size) || offset < 0 || entry.size < 0 || offset > size - dataStart - entry.size) fail(`ASAR entry outside archive: ${entryPath}`);
          entries.push({ path: entryPath, entry, offset, size: entry.size });
          if (entries.length > 100000) fail('ASAR has too many entries');
        }
      }
    }
    const ranges = entries.filter(entry => entry.size > 0).sort((a, b) => a.offset - b.offset);
    // ASAR packers may deduplicate identical files into an exactly shared range.
    for (let index = 1; index < ranges.length; index++) {
      const current = ranges[index];
      const previous = ranges[index - 1];
      if (current.offset < previous.offset + previous.size && (current.offset !== previous.offset || current.size !== previous.size)) fail('Partially overlapping ASAR entry ranges');
    }
    return { fd, size, dataStart, header, entries, headerSha256: sha256(json) };
  } catch (error) { fs.closeSync(fd); throw error; }
}

function integrityFor(buffer, blockSize) {
  if (!Number.isSafeInteger(blockSize) || blockSize < 1 || blockSize > 16 * 1024 * 1024) fail('Unsupported ASAR integrity block size');
  const blocks = [];
  for (let offset = 0; offset < buffer.length; offset += blockSize) blocks.push(sha256(buffer.subarray(offset, offset + blockSize)));
  return { algorithm: 'SHA256', hash: sha256(buffer), blockSize, blocks };
}

function verifyIntegrity(buffer, entryPath, integrity) {
  if (!integrity || integrity.algorithm !== 'SHA256' || !Array.isArray(integrity.blocks)) fail(`Missing SHA256 integrity for patch target: ${entryPath}`);
  const expected = integrityFor(buffer, integrity.blockSize);
  if (expected.hash !== integrity.hash || expected.blocks.length !== integrity.blocks.length || expected.blocks.some((hash, index) => hash !== integrity.blocks[index])) fail(`ASAR target integrity mismatch: ${entryPath}`);
}

function prepareArchive(archivePath) {
  const archive = readArchive(archivePath);
  try {
    const scripts = [];
    for (const record of archive.entries) {
      if (!record.path.startsWith('webview/') || !record.path.endsWith('.js') || record.size > MAX_SCRIPT) continue;
      const buffer = readExact(archive.fd, record.size, archive.dataStart + record.offset);
      const source = buffer.toString('utf8');
      if (!(source.includes('fast_mode') && source.includes('ultrafast_mode')) && !(source.includes('personalAccessToken') && source.includes('chatgpt') && (source.includes('fast_mode') || source.includes('serviceTierAccess')))) continue;
      const analysis = analyzeScript(source);
      if (!analysis.gates.length && !analysis.helpers.size) continue;
      if (!Buffer.from(source, 'utf8').equals(buffer)) fail('Patch target is not valid UTF-8');
      verifyIntegrity(buffer, record.path, record.entry.integrity);
      scripts.push({ path: record.path, source, record, ...analysis, originalSha256: sha256(buffer) });
    }
    const transformed = transformEntries(scripts);
    return { ...archive, ...transformed };
  } catch (error) { fs.closeSync(archive.fd); throw error; }
}

function fileSha256(fd, size) {
  const hash = crypto.createHash('sha256');
  const chunkSize = 4 * 1024 * 1024;
  for (let position = 0; position < size; position += chunkSize) hash.update(readExact(fd, Math.min(chunkSize, size - position), position));
  return hash.digest('hex');
}

function describe(archivePath, archive) {
  return {
    engineVersion: ENGINE_VERSION,
    status: archive.alreadyPatched ? 'patched' : 'patchable',
    archivePath: path.resolve(archivePath),
    archiveSize: archive.size,
    archiveSha256: fileSha256(archive.fd, archive.size),
    headerSha256: archive.headerSha256,
    targetEntries: archive.entries.filter(entry => entry.gates.length).map(entry => ({
      path: entry.path,
      originalSha256: entry.originalSha256,
      patchedSha256: sha256(Buffer.from(entry.patchedSource, 'utf8')),
      gates: entry.gates.map(gate => ({ role: gate.role, alreadyPatched: gate.alreadyPatched }))
    }))
  };
}

function inspectArchive(archivePath) {
  const archive = prepareArchive(archivePath);
  try { return describe(archivePath, archive); }
  finally { fs.closeSync(archive.fd); }
}

function encodeHeader(header) {
  const json = Buffer.from(JSON.stringify(header), 'utf8');
  const length = Math.ceil((8 + json.length) / 4) * 4;
  if (length > MAX_HEADER) fail('Patched ASAR header is too large');
  const result = Buffer.alloc(8 + length);
  result.writeUInt32LE(4, 0);
  result.writeUInt32LE(length, 4);
  result.writeUInt32LE(length - 4, 8);
  result.writeUInt32LE(json.length, 12);
  json.copy(result, 16);
  return result;
}

function writeAll(fd, buffer) {
  let offset = 0;
  while (offset < buffer.length) {
    const written = fs.writeSync(fd, buffer, offset, buffer.length - offset);
    if (!written) fail('Failed to write ASAR output');
    offset += written;
  }
}

function buildArchive(archivePath, outputPath) {
  if (path.resolve(archivePath).toLowerCase() === path.resolve(outputPath).toLowerCase()) fail('Output must not be the installed/source archive');
  const archive = prepareArchive(archivePath);
  let outputFd;
  let created = false;
  try {
    const input = describe(archivePath, archive);
    outputFd = fs.openSync(outputPath, 'wx');
    created = true;
    let chunks = [];
    if (!archive.alreadyPatched) {
      let nextOffset = archive.size - archive.dataStart;
      for (const entry of archive.entries.filter(entry => entry.gates.length)) {
        const buffer = Buffer.from(entry.patchedSource, 'utf8');
        entry.record.entry.offset = String(nextOffset);
        entry.record.entry.size = buffer.length;
        entry.record.entry.integrity = integrityFor(buffer, entry.record.entry.integrity.blockSize);
        chunks.push(buffer);
        nextOffset += buffer.length;
      }
      writeAll(outputFd, encodeHeader(archive.header));
    }
    const start = archive.alreadyPatched ? 0 : archive.dataStart;
    for (let position = start; position < archive.size; position += 4 * 1024 * 1024) {
      writeAll(outputFd, readExact(archive.fd, Math.min(4 * 1024 * 1024, archive.size - position), position));
    }
    for (const buffer of chunks) writeAll(outputFd, buffer);
    fs.fsyncSync(outputFd);
    fs.closeSync(outputFd);
    outputFd = undefined;
    const output = inspectArchive(outputPath);
    if (output.status !== 'patched' || output.targetEntries.length !== input.targetEntries.length) fail('Built ASAR validation failed');
    return { ...output, status: 'built', alreadyPatched: archive.alreadyPatched, sourceSha256: input.archiveSha256, outputPath: path.resolve(outputPath) };
  } catch (error) {
    if (outputFd !== undefined) fs.closeSync(outputFd);
    if (created) fs.unlinkSync(outputPath);
    throw error;
  } finally { fs.closeSync(archive.fd); }
}

module.exports = { ENGINE_VERSION, findGates, transformScripts, readArchive, integrityFor, inspectArchive, buildArchive, encodeHeader, readExact };

if (require.main === module) {
  try {
    const [command, archivePath, outputPath, ...extra] = process.argv.slice(2);
    if (extra.length || !archivePath || !['inspect', 'build'].includes(command) || (command === 'build' ? !outputPath : outputPath !== undefined)) fail('Usage: node patch-core.cjs inspect <archive> | build <archive> <new-output>');
    const result = command === 'inspect' ? inspectArchive(archivePath) : buildArchive(archivePath, outputPath);
    process.stdout.write(JSON.stringify(result) + '\n');
  } catch (error) {
    process.stderr.write(`Fast patch refused: ${error.message}\n`);
    process.exitCode = 1;
  }
}
