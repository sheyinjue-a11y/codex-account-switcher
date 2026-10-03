'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const acorn = require('acorn');

const ENGINE_VERSION = 1;
const MAX_HEADER = 32 * 1024 * 1024;
const MAX_SCRIPT = 32 * 1024 * 1024;
const AUTH_TYPES = ['chatgpt', 'personalAccessToken'];
const patchedAuthTypes = [...AUTH_TYPES, 'apikey'];
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
  const expected = types.length === 2 ? AUTH_TYPES : types.length === 3 ? patchedAuthTypes : [];
  if (types.length !== expected.length || new Set(types).size !== types.length || expected.some(type => !types.includes(type))) return null;
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

function findGates(source) {
  const ast = acorn.parse(source, { ecmaVersion: 'latest', sourceType: 'module', allowHashBang: true });
  const allNodes = nodesWithin(ast);
  const gates = [];
  for (const fn of allNodes.filter(isFunction)) {
    const ownNodes = nodesWithin(fn, true);
    const restrictions = ownNodes.filter(featureRestriction);
    if (restrictions.length === 0) continue;
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
  return gates;
}

function transformScripts(scripts) {
  const entries = scripts.map(script => ({ ...script, gates: findGates(script.source) }));
  return transformEntries(entries);
}

function transformEntries(entries) {
  const gates = entries.flatMap(entry => entry.gates);
  if (gates.length !== 2 || gates.filter(gate => gate.role === 'ui').length !== 1 || gates.filter(gate => gate.role === 'request').length !== 1) fail(`Expected exactly one UI and one request Fast gate; found ${gates.length}`);
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
      if (!source.includes('fast_mode') || !source.includes('personalAccessToken') || !source.includes('chatgpt')) continue;
      const gates = findGates(source);
      if (!gates.length) continue;
      if (!Buffer.from(source, 'utf8').equals(buffer)) fail('Patch target is not valid UTF-8');
      verifyIntegrity(buffer, record.path, record.entry.integrity);
      scripts.push({ path: record.path, source, record, gates, originalSha256: sha256(buffer) });
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
    targetEntries: archive.entries.filter(entry => entry.gates).map(entry => ({
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
      for (const entry of archive.entries.filter(entry => entry.gates)) {
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
