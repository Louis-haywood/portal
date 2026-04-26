require('dotenv').config();
const chokidar = require('chokidar');
const FormData = require('form-data');
const fs       = require('fs');
const path     = require('path');
const fetch    = require('node-fetch');
const mime     = require('mime-types');

const WATCH_DIR = path.resolve(process.env.WATCH_DIR || path.join(require('os').homedir(), 'CDN'));
const CDN_URL   = (process.env.CDN_URL || 'https://cdn.haywood.ltd').replace(/\/$/, '');
const API_KEY   = process.env.API_KEY;
const DELETE_ON_REMOVE = process.env.DELETE_ON_REMOVE === 'true';

if (!API_KEY) { console.error('FATAL: API_KEY not set in .env'); process.exit(1); }
if (!fs.existsSync(WATCH_DIR)) fs.mkdirSync(WATCH_DIR, { recursive: true });

console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
console.log('  CDN Watcher');
console.log(`  Folder : ${WATCH_DIR}`);
console.log(`  CDN    : ${CDN_URL}`);
console.log(`  Delete sync: ${DELETE_ON_REMOVE}`);
console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

// ── Upload a file ─────────────────────────────────────────────────
async function upload(filePath) {
  const rel      = path.relative(WATCH_DIR, filePath).replace(/\\/g, '/');
  const subdir   = path.dirname(rel).replace(/\\/g, '/');
  const filename = path.basename(filePath);
  const mimeType = mime.lookup(filePath) || 'application/octet-stream';

  // Wait briefly so the file is fully written before we read it
  await new Promise(r => setTimeout(r, 500));

  if (!fs.existsSync(filePath)) return; // deleted before we could upload

  const stats = fs.statSync(filePath);
  const sizeMB = (stats.size / 1024 / 1024).toFixed(2);

  const form = new FormData();
  form.append('file', fs.createReadStream(filePath), { filename, contentType: mimeType });

  process.stdout.write(`↑ ${rel} (${sizeMB} MB) ... `);

  try {
    const res = await fetch(`${CDN_URL}/upload`, {
      method: 'POST',
      headers: {
        'x-api-key': API_KEY,
        'x-upload-path': subdir === '.' ? '' : subdir,
        ...form.getHeaders(),
      },
      body: form,
    });

    const data = await res.json();
    if (data.ok) {
      console.log(`done\n  → ${data.url}`);
    } else {
      console.log(`FAILED\n  Server: ${data.error}`);
    }
  } catch (err) {
    console.log(`ERROR\n  ${err.message}`);
  }
}

// ── Delete a file from CDN ────────────────────────────────────────
async function remove(filePath) {
  if (!DELETE_ON_REMOVE) return;

  const rel = path.relative(WATCH_DIR, filePath).replace(/\\/g, '/');
  process.stdout.write(`✕ ${rel} ... `);

  try {
    const res  = await fetch(`${CDN_URL}/files/${rel}`, {
      method: 'DELETE',
      headers: { 'x-api-key': API_KEY },
    });
    const data = await res.json();
    console.log(data.ok ? 'deleted' : `FAILED: ${data.error}`);
  } catch (err) {
    console.log(`ERROR: ${err.message}`);
  }
}

// ── Watch ─────────────────────────────────────────────────────────
chokidar.watch(WATCH_DIR, {
  ignoreInitial: true,
  ignored: /(^|[/\\])\../, // ignore dotfiles
  awaitWriteFinish: {
    stabilityThreshold: 2000, // wait 2s after last write before triggering
    pollInterval: 200,
  },
})
  .on('add',    filePath => upload(filePath))
  .on('change', filePath => upload(filePath))
  .on('unlink', filePath => remove(filePath));
