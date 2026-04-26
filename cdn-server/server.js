require('dotenv').config();
const express  = require('express');
const multer   = require('multer');
const path     = require('path');
const fs       = require('fs');
const cors     = require('cors');

const app        = express();
const PORT       = process.env.PORT || 3000;
const API_KEY    = process.env.API_KEY;
const UPLOAD_DIR = path.resolve(process.env.UPLOAD_DIR || path.join(__dirname, 'uploads'));

if (!API_KEY) { console.error('FATAL: API_KEY not set in .env'); process.exit(1); }

fs.mkdirSync(UPLOAD_DIR, { recursive: true });

// ── CORS ─────────────────────────────────────────────────────────
app.use(cors({ origin: '*' }));

// ── Serve uploaded files ──────────────────────────────────────────
// express.static handles Range requests for video seeking automatically
app.use(express.static(UPLOAD_DIR, {
  setHeaders(res) {
    res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
    res.setHeader('Access-Control-Allow-Origin', '*');
  },
}));

// ── Auth middleware ───────────────────────────────────────────────
function auth(req, res, next) {
  if (req.headers['x-api-key'] !== API_KEY) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
}

// ── Multer: disk storage, preserves subfolder structure ───────────
const ALLOWED_MIME = /^(image\/(jpeg|png|gif|webp|svg\+xml|avif|bmp|tiff)|video\/(mp4|webm|quicktime|x-msvideo|x-matroska))$/;

const storage = multer.diskStorage({
  destination(req, file, cb) {
    const sub  = (req.headers['x-upload-path'] || '').replace(/\.\./g, '');
    const dest = path.join(UPLOAD_DIR, sub);
    fs.mkdirSync(dest, { recursive: true });
    cb(null, dest);
  },
  filename(req, file, cb) {
    // Sanitise filename: strip anything that isn't alphanumeric, dot, dash, underscore
    const safe = file.originalname.replace(/[^a-zA-Z0-9.\-_]/g, '_');
    cb(null, safe);
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 4 * 1024 * 1024 * 1024 }, // 4 GB max
  fileFilter(req, file, cb) {
    ALLOWED_MIME.test(file.mimetype)
      ? cb(null, true)
      : cb(new Error(`Blocked file type: ${file.mimetype}`));
  },
});

// ── POST /upload ─────────────────────────────────────────────────
app.post('/upload', auth, upload.single('file'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file received' });

  const sub     = (req.headers['x-upload-path'] || '').replace(/\.\./g, '');
  const urlPath = sub ? `${sub}/${req.file.filename}` : req.file.filename;
  const cdnUrl  = `${process.env.CDN_BASE_URL || 'https://cdn.haywood.ltd'}/${urlPath}`;

  console.log(`[upload] ${urlPath} (${(req.file.size / 1024 / 1024).toFixed(2)} MB)`);

  res.json({ ok: true, url: cdnUrl, path: urlPath, size: req.file.size });
});

// ── DELETE /files/* ───────────────────────────────────────────────
app.delete('/files/*', auth, (req, res) => {
  const rel      = req.params[0];
  const filePath = path.resolve(UPLOAD_DIR, rel);

  // Prevent path traversal
  if (!filePath.startsWith(UPLOAD_DIR + path.sep) && filePath !== UPLOAD_DIR) {
    return res.status(400).json({ error: 'Invalid path' });
  }
  if (!fs.existsSync(filePath)) return res.status(404).json({ error: 'Not found' });

  fs.unlinkSync(filePath);
  console.log(`[delete] ${rel}`);
  res.json({ ok: true, deleted: rel });
});

// ── GET /files ────────────────────────────────────────────────────
app.get('/files', auth, (req, res) => {
  const CDN_BASE = process.env.CDN_BASE_URL || 'https://cdn.haywood.ltd';

  function walk(dir, base = '') {
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => {
      const rel  = base ? `${base}/${e.name}` : e.name;
      const full = path.join(dir, e.name);
      if (e.isDirectory()) return walk(full, rel);
      const { size, mtime } = fs.statSync(full);
      return [{ path: rel, url: `${CDN_BASE}/${rel}`, size, modified: mtime }];
    });
  }

  res.json(walk(UPLOAD_DIR));
});

// ── GET /health ───────────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ ok: true, uptime: process.uptime() }));

// ── Error handler ─────────────────────────────────────────────────
app.use((err, req, res, _next) => {
  console.error(`[error] ${err.message}`);
  res.status(err.status || 500).json({ error: err.message });
});

app.listen(PORT, () => console.log(`CDN server on :${PORT}  uploads → ${UPLOAD_DIR}`));
