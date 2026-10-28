#!/usr/bin/node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const net = require('net');
const { execFile } = require('child_process');

const ROOT = '/var/lib/webosbrew/camera-overlay';
const WEBHOOK = '/api/v1/reolink/webhook';
const MAX_BODY = 4096;
const recent = new Map();
const pending = new Set();

function readPrivateFile(name) {
  const path = ROOT + '/' + name;
  const stat = fs.statSync(path);
  if (stat.uid !== 0 || (stat.mode & 0o777) !== 0o600) {
    throw new Error(name + ' must be root-owned with mode 600');
  }
  return fs.readFileSync(path, 'utf8').trim();
}

function loadSettings() {
  const config = JSON.parse(readPrivateFile('api-config.json'));
  if (config.enabled !== true || !net.isIPv4(config.bindAddress) || config.bindAddress === '0.0.0.0') {
    throw new Error('Bind the enabled API to the TV LAN IPv4 address');
  }
  if (!Number.isInteger(config.port) || config.port < 1024 || config.port > 65535) throw new Error('Invalid port');
  if (!Array.isArray(config.allowedClients) || !config.allowedClients.length ||
      config.allowedClients.some((address) => !net.isIPv4(address))) throw new Error('Set exact camera IPv4 addresses');
  const key = readPrivateFile('api.key');
  if (!/^[a-f0-9]{64}$/i.test(key)) throw new Error('api.key must contain 32 random bytes as hex');
  if (!config.notifications || typeof config.notifications !== 'object' || Array.isArray(config.notifications)) {
    throw new Error('Missing notification rules');
  }
  for (const type of ['people', 'vehicle', 'visitor', 'motion', 'pet']) {
    const rule = config.notifications[type];
    if (rule == null) continue;
    if (typeof rule !== 'object' || Array.isArray(rule) ||
        !['motion-person', 'motion-car', 'doorbell'].includes(rule.event) ||
        !['none', 'motion-person', 'motion-car', 'doorbell'].includes(rule.sound) ||
        typeof rule.message !== 'string' || !rule.message.trim() || rule.message.length > 240 ||
        /[\u0000-\u001f\u007f-\u009f]/.test(rule.message) ||
        !Number.isInteger(rule.durationSeconds) || rule.durationSeconds < 1 || rule.durationSeconds > 86400) {
      throw new Error('Invalid notification rule for ' + type);
    }
  }
  return { address: config.bindAddress, port: config.port,
    clients: new Set(config.allowedClients), key: key.toLowerCase(), rules: config.notifications };
}

const settings = loadSettings();

function reply(res, code, status) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(JSON.stringify({ status }));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (part) => { size += part.length; if (size <= MAX_BODY) chunks.push(part); });
    req.on('end', () => size > MAX_BODY ? reject('too_large') : resolve(Buffer.concat(chunks)));
    req.on('error', () => reject('bad_body'));
  });
}

function isToken(value) {
  if (!value || !/^[a-f0-9]{64}$/i.test(value)) return false;
  return crypto.timingSafeEqual(Buffer.from(value.toLowerCase(), 'ascii'), Buffer.from(settings.key, 'ascii'));
}

function field(object, name) {
  if (!object || typeof object !== 'object' || Array.isArray(object)) return undefined;
  const key = Object.keys(object).find((candidate) => candidate.toLowerCase() === name);
  return key === undefined ? undefined : object[key];
}

function eventType(payload) {
  const alarm = field(payload, 'alarm');
  if (!alarm || typeof alarm !== 'object') return null;
  const rawType = field(alarm, 'type');
  const type = typeof rawType === 'string' ? rawType.toLowerCase() : '';
  return ['people', 'vehicle', 'visitor', 'motion', 'pet'].includes(type) ? type : null;
}

function identity(payload, raw) {
  const alarm = field(payload, 'alarm');
  const rawStart = field(alarm, 'start');
  const start = typeof rawStart === 'string' ? rawStart.trim() : '';
  const rawType = field(alarm, 'type');
  const alarmType = typeof rawType === 'string' ? rawType.toLowerCase() : '';
  const seed = start ? ['stable', field(alarm, 'channel'), alarmType, start].join('\n') :
    ['fallback', raw.toString('utf8')].join('\n');
  return { hash: crypto.createHash('sha256').update(seed).digest('hex'), ttl: start ? 120000 : 30000 };
}

function show(rule) {
  return new Promise((resolve) => {
    execFile(ROOT + '/control', ['notify', rule.event, '--sound', rule.sound,
      '--duration', String(rule.durationSeconds), rule.message], {
      cwd: ROOT, env: { PATH: '/usr/bin:/bin', HOME: '/root' }, timeout: 8000, maxBuffer: 1024
    }, (error) => resolve(!error));
  });
}

async function handle(req, res) {
  if (req.method !== 'POST' || !req.url.startsWith(WEBHOOK + '?')) return reply(res, 404, 'not_found');
  const remote = req.socket.remoteAddress.replace(/^::ffff:/, '');
  if (!settings.clients.has(remote)) return reply(res, 403, 'client_not_allowed');
  let url;
  try { url = new URL(req.url, 'http://localhost'); } catch (_) { return reply(res, 400, 'bad_url'); }
  if (url.pathname !== WEBHOOK || Array.from(url.searchParams).length !== 1 || !isToken(url.searchParams.get('token'))) {
    return reply(res, 401, 'unauthorized');
  }
  if ((req.headers['content-type'] || '').split(';')[0].trim().toLowerCase() !== 'application/json') {
    return reply(res, 415, 'application_json_required');
  }
  let raw;
  try { raw = await readBody(req); } catch (error) { return reply(res, error === 'too_large' ? 413 : 400, error); }
  let payload;
  try { payload = JSON.parse(raw.toString('utf8')); } catch (_) { return reply(res, 400, 'invalid_json'); }
  const type = eventType(payload);
  if (!type || !settings.rules[type]) return reply(res, 200, 'ignored'); // The camera Test can omit alarm.
  const id = identity(payload, raw);
  const now = Date.now();
  for (const [hash, expiry] of recent) if (expiry <= now) recent.delete(hash);
  if (recent.has(id.hash) || pending.has(id.hash)) return reply(res, 200, 'duplicate');
  if (pending.size >= 10) return reply(res, 429, 'busy');
  pending.add(id.hash);
  try {
    if (!(await show(settings.rules[type]))) return reply(res, 503, 'unavailable');
    recent.set(id.hash, now + id.ttl);
    console.info('Accepted Reolink event', type);
    return reply(res, 200, 'accepted');
  } finally { pending.delete(id.hash); }
}

const server = http.createServer((req, res) => {
  handle(req, res).catch(() => reply(res, 500, 'unavailable'));
});
server.timeout = 10000;
server.requestTimeout = 10000;
server.listen(settings.port, settings.address, () => console.info('Camera webhook receiver ready'));
server.on('error', (error) => { console.error('Camera webhook listener failed:', error.code || 'unknown'); process.exitCode = 1; });
process.on('SIGTERM', () => server.close(() => process.exit(0)));
