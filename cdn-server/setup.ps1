# CDN Server Setup — run as Administrator on the VPS
# Right-click PowerShell -> "Run as Administrator", then paste this path:
#   powershell -ExecutionPolicy Bypass -File C:\setup-cdn.ps1

$ErrorActionPreference = "Stop"
$CDN_DIR    = "C:\cdn-server"
$UPLOAD_DIR = "C:\cdn\uploads"
$CADDY_DIR  = "C:\caddy"
$PORT       = 3000

# ── Banner ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  CDN SETUP" -ForegroundColor Cyan
Write-Host "  cdn.haywood.ltd" -ForegroundColor Cyan
Write-Host ""

# ── 1. Directories ────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $CDN_DIR    | Out-Null
New-Item -ItemType Directory -Force -Path $UPLOAD_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $CADDY_DIR  | Out-Null
Write-Host "[1/6] Directories created" -ForegroundColor Green

# ── 2. Generate API key ───────────────────────────────────────────
$chars   = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.ToCharArray()
$API_KEY = -join (1..40 | ForEach-Object { $chars | Get-Random })
Write-Host "[2/6] API key: $API_KEY" -ForegroundColor Green
Write-Host "      -> Copy this into cdn-watcher\.env on your local machine" -ForegroundColor Yellow

# ── 3. Write .env ─────────────────────────────────────────────────
@"
PORT=$PORT
API_KEY=$API_KEY
UPLOAD_DIR=$UPLOAD_DIR
CDN_BASE_URL=https://cdn.haywood.ltd
"@ | Set-Content -Path "$CDN_DIR\.env" -Encoding utf8
Write-Host "[3/6] .env written" -ForegroundColor Green

# ── 4. Write package.json ─────────────────────────────────────────
@'
{
  "name": "cdn-server",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "multer": "^1.4.5-lts.1"
  }
}
'@ | Set-Content -Path "$CDN_DIR\package.json" -Encoding utf8

# ── 5. Write server.js ────────────────────────────────────────────
@'
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

app.use(cors({ origin: '*' }));

// Serve files — express.static handles Range requests for video seeking
app.use(express.static(UPLOAD_DIR, {
  setHeaders(res) {
    res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
    res.setHeader('Access-Control-Allow-Origin', '*');
  },
}));

function auth(req, res, next) {
  if (req.headers['x-api-key'] !== API_KEY) return res.status(401).json({ error: 'Unauthorized' });
  next();
}

const ALLOWED = /^(image\/(jpeg|png|gif|webp|svg\+xml|avif|bmp|tiff)|video\/(mp4|webm|quicktime|x-msvideo|x-matroska))$/;

const storage = multer.diskStorage({
  destination(req, file, cb) {
    const sub  = (req.headers['x-upload-path'] || '').replace(/\.\./g, '');
    const dest = path.join(UPLOAD_DIR, sub);
    fs.mkdirSync(dest, { recursive: true });
    cb(null, dest);
  },
  filename(req, file, cb) {
    cb(null, file.originalname.replace(/[^a-zA-Z0-9.\-_]/g, '_'));
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 4 * 1024 * 1024 * 1024 },
  fileFilter(req, file, cb) {
    ALLOWED.test(file.mimetype) ? cb(null, true) : cb(new Error('Blocked: ' + file.mimetype));
  },
});

app.post('/upload', auth, upload.single('file'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file' });
  const sub    = (req.headers['x-upload-path'] || '').replace(/\.\./g, '');
  const rel    = sub ? sub + '/' + req.file.filename : req.file.filename;
  const url    = (process.env.CDN_BASE_URL || 'https://cdn.haywood.ltd') + '/' + rel;
  console.log('[upload] ' + rel + ' (' + (req.file.size / 1024 / 1024).toFixed(2) + ' MB)');
  res.json({ ok: true, url, path: rel, size: req.file.size });
});

app.delete('/files/*', auth, (req, res) => {
  const filePath = path.resolve(UPLOAD_DIR, req.params[0]);
  if (!filePath.startsWith(UPLOAD_DIR)) return res.status(400).json({ error: 'Bad path' });
  if (!fs.existsSync(filePath))         return res.status(404).json({ error: 'Not found' });
  fs.unlinkSync(filePath);
  console.log('[delete] ' + req.params[0]);
  res.json({ ok: true });
});

app.get('/files', auth, (req, res) => {
  const BASE = process.env.CDN_BASE_URL || 'https://cdn.haywood.ltd';
  function walk(dir, base) {
    base = base || '';
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap(function(e) {
      var rel  = base ? base + '/' + e.name : e.name;
      var full = path.join(dir, e.name);
      if (e.isDirectory()) return walk(full, rel);
      var stat = fs.statSync(full);
      return [{ path: rel, url: BASE + '/' + rel, size: stat.size, modified: stat.mtime }];
    });
  }
  res.json(walk(UPLOAD_DIR));
});

app.get('/health', function(req, res) { res.json({ ok: true, uptime: process.uptime() }); });

app.use(function(err, req, res, _next) {
  console.error('[error] ' + err.message);
  res.status(err.status || 500).json({ error: err.message });
});

app.listen(PORT, function() { console.log('CDN server on :' + PORT + '  uploads: ' + UPLOAD_DIR); });
'@ | Set-Content -Path "$CDN_DIR\server.js" -Encoding utf8

# ── 6. Write Caddyfile ────────────────────────────────────────────
@'
cdn.haywood.ltd {
    reverse_proxy localhost:3000
}
'@ | Set-Content -Path "$CDN_DIR\Caddyfile" -Encoding utf8

Write-Host "[4/6] Server files written" -ForegroundColor Green

# ── 7. npm install ────────────────────────────────────────────────
Set-Location $CDN_DIR
Write-Host "[5/6] Installing npm packages..." -ForegroundColor Yellow
npm install --silent
Write-Host "[5/6] npm packages installed" -ForegroundColor Green

# ── 8. Download Caddy ─────────────────────────────────────────────
Write-Host "[6/6] Downloading Caddy..." -ForegroundColor Yellow
$caddyExe = "$CADDY_DIR\caddy.exe"
Invoke-WebRequest `
  -Uri "https://caddyserver.com/api/download?os=windows&arch=amd64" `
  -OutFile $caddyExe `
  -UseBasicParsing
Write-Host "[6/6] Caddy downloaded" -ForegroundColor Green

# Add Caddy to system PATH permanently
$syspath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
if ($syspath -notlike "*$CADDY_DIR*") {
  [Environment]::SetEnvironmentVariable("PATH", "$syspath;$CADDY_DIR", "Machine")
  $env:PATH += ";$CADDY_DIR"
}

# ── 9. Start Node server with PM2 ─────────────────────────────────
Write-Host ""
Write-Host "Starting PM2..." -ForegroundColor Yellow
pm2 start "$CDN_DIR\server.js" --name cdn
pm2 save

# Auto-start PM2 on boot via Task Scheduler (reliable on Windows)
$pm2cmd = (Get-Command pm2 -ErrorAction SilentlyContinue)
$pm2path = if ($pm2cmd) { $pm2cmd.Source } else { "$env:APPDATA\npm\pm2.cmd" }

$action    = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$pm2path`" resurrect"
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "CDN-PM2-Startup" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
Write-Host "PM2 startup task registered" -ForegroundColor Green

# ── 10. Start Caddy ───────────────────────────────────────────────
Write-Host "Starting Caddy..." -ForegroundColor Yellow
Start-Process -FilePath $caddyExe `
  -ArgumentList "start --config `"$CDN_DIR\Caddyfile`"" `
  -WorkingDirectory $CADDY_DIR `
  -NoNewWindow
Write-Host "Caddy started" -ForegroundColor Green

# ── Also register Caddy as a startup task ────────────────────────
$caddyAction    = New-ScheduledTaskAction -Execute $caddyExe `
  -Argument "start --config `"$CDN_DIR\Caddyfile`"" `
  -WorkingDirectory $CADDY_DIR
$caddyTrigger   = New-ScheduledTaskTrigger -AtStartup
$caddyPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "CDN-Caddy-Startup" -Action $caddyAction -Trigger $caddyTrigger -Principal $caddyPrincipal -Force | Out-Null

# ── Done ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  Setup complete!" -ForegroundColor Cyan
Write-Host ""
Write-Host "  API key : $API_KEY" -ForegroundColor Yellow
Write-Host "  Uploads : $UPLOAD_DIR" -ForegroundColor White
Write-Host "  Health  : http://localhost:$PORT/health" -ForegroundColor White
Write-Host ""
Write-Host "  Next: add an A record in GoDaddy:" -ForegroundColor White
Write-Host "    cdn.haywood.ltd -> $((Invoke-WebRequest -Uri 'https://api.ipify.org' -UseBasicParsing).Content)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Then on your local machine fill in cdn-watcher\.env:" -ForegroundColor White
Write-Host "    API_KEY=$API_KEY" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
