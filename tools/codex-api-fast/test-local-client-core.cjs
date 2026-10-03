'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {patchLauncher} = require('./local-client-core.cjs');
const oldHash = 'a'.repeat(64), newHash = 'b'.repeat(64);
const integrity = JSON.stringify([{file:'resources\\app.asar',alg:'SHA256',value:oldHash}]);
const dependency = '<dependency><dependentAssembly><assemblyIdentity type="win32" name="154.0.8037.57" version="154.0.8037.57" language="*"/></dependentAssembly></dependency>';
const fixture = Buffer.from('MZ\0unchanged-data\0'+integrity+'\0'+dependency+'\0unchanged-tail');
test('local launcher binds the new archive without altering source, length, or other bytes', () => {
  const before = Buffer.from(fixture);
  const actual = patchLauncher(fixture, oldHash, newHash);
  const expected = Buffer.from(fixture.toString().replace(oldHash,newHash).replace(dependency,' '.repeat(dependency.length)));
  assert.deepEqual(actual.buffer, expected);
  assert.deepEqual(fixture,before);
  assert.equal(actual.buffer.length,fixture.length);
  assert.equal(actual.privateAssembly,'154.0.8037.57');
});
test('refuses stale hashes, ambiguous resources and unsupported manifest layouts', () => {
  for (const value of [Buffer.from('bad'),Buffer.concat([fixture,Buffer.from(integrity)]),Buffer.concat([fixture,Buffer.from(dependency)]),Buffer.from(fixture.toString().replace(dependency,''))]) {
    assert.throws(()=>patchLauncher(value,oldHash,newHash));
  }
  assert.throws(()=>patchLauncher(fixture,newHash,oldHash));
  assert.throws(()=>patchLauncher(fixture,'invalid',newHash));
});
