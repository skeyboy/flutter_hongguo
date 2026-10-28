#!/usr/bin/env node
// Offline register-protocol oracle. Executes the supplied local JS implementation
// only; it never opens a socket. Randomness, the clock and the transport are
// stubbed so one run yields deterministic vectors for the Dart port to replay.
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const realCrypto = require('node:crypto');
const zlib = require('node:zlib');

const sourceRoot = process.argv[2];
if (!sourceRoot) {
  throw new Error('Usage: node tool/generate_register_vector.cjs /path/to/hongguo-web');
}
const devicePath = path.resolve(sourceRoot, 'server/src/service/playback-device.js');
const source = fs.readFileSync(devicePath, 'utf8');

const NOW = 1700000000123;
const RESPONSE = {
  code: 0,
  device_id: 7661622467441478681,
  device_id_str: '7661622467441478681',
  install_id: 3912088544850522,
  install_id_str: '3912088544850522',
  cdid: 'cdid-from-response',
};

function seededGenerator(seed) {
  let state = seed >>> 0;
  return (n) => Buffer.from(Array.from({ length: n }, () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state >>> 24;
  }));
}

async function vectorFor(index) {
  const randomBytes = seededGenerator(1000 + index);
  let uuids = 0;
  const stubCrypto = {
    ...realCrypto,
    randomBytes,
    randomUUID: () => 'uuid-' + (++uuids),
  };
  let sent = null;
  const HttpStub = {
    send: async (opts) => {
      sent = opts;
      return { status: 200, text: () => JSON.stringify(RESPONSE) };
    },
  };
  const context = {
    Buffer,
    console,
    require: (id) => (id === 'crypto'
      ? stubCrypto
      : id === 'zlib'
        ? zlib
        : id === '../util/http'
          ? HttpStub
          : require(id)),
    module: { exports: {} },
    Date: class extends Date { static now() { return NOW; } },
  };
  vm.runInNewContext(source, context);
  const identity = await context.module.exports.getPlaybackDevice();
  const body = Buffer.from(sent.body);
  return {
    index,
    seed: 1000 + index,
    now: NOW,
    url: sent.url,
    method: sent.method,
    headers: sent.headers,
    // The register body is 6 fixed bytes, then the 32-byte session random, then
    // AES-128-CBC(sha512(gzip) || gzip); the vector keeps the whole body plus the
    // random so the Dart port can replay the same inputs.
    prefixHex: body.subarray(0, 6).toString('hex'),
    randomHex: body.subarray(6, 38).toString('hex'),
    bodyBase64: body.toString('base64'),
    bodyBytes: body.length,
    identity,
  };
}

(async () => {
  const vectors = [];
  for (let index = 0; index < 3; index++) vectors.push(await vectorFor(index));
  process.stdout.write(JSON.stringify({
    generator: 'tool/generate_register_vector.cjs',
    reference: 'server/src/service/playback-device.js',
    note: 'Produced offline from the pinned reference implementation.',
    response: RESPONSE,
    vectors,
  }, null, 2) + '\n');
})();
