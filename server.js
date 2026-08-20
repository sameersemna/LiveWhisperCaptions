// Vermittlung — local host + proxy for the live call console.
// Serves call-console.html and reverse-proxies audio to whisper-server,
// so the browser only ever talks to localhost (no CORS involved).
//
// Usage:
//   node server.js
//   WHISPER_URL=http://192.168.178.55:8768 PORT=3000 node server.js
//
// No npm install needed — uses only Node's built-in http/https modules.

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

// ---------- tiny .env loader (no dependency) ----------
function loadEnvFile(filePath) {
  const env = {};
  let raw;
  try {
    raw = fs.readFileSync(filePath, 'utf8');
  } catch (e) {
    return env; // no .env file present — that's fine, fall back to process.env / defaults
  }
  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    let val = trimmed.slice(eq + 1).trim();
    // strip surrounding quotes ("..." or '...')
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    env[key] = val;
  }
  return env;
}

const fileEnv = loadEnvFile(path.join(__dirname, '.env'));
// process.env takes priority over .env, so real env vars can still override for one-off runs
const cfg = { ...fileEnv, ...process.env };

const PORT = parseInt(cfg.PORT || '3000', 10);
const WHISPER_HOST = cfg.WHISPER_HOST || '192.168.178.55:8768';
const WHISPER_URL = cfg.WHISPER_URL || (/^https?:\/\//.test(WHISPER_HOST) ? WHISPER_HOST : `http://${WHISPER_HOST}`);
const BT_ADDRESS = cfg.BT_ADDRESS || '';
const BT_SOURCE = cfg.BT_SOURCE || '';
const HTML_FILE = path.join(__dirname, 'call-console.html');

function proxyRequest(targetUrlStr, req, res, { method = req.method, timeoutMs = 30000 } = {}) {
  const target = new URL(targetUrlStr);
  const lib = target.protocol === 'https:' ? https : http;

  const headers = { ...req.headers };
  delete headers.host; // let Node set the correct Host for the target

  const proxyReq = lib.request(
    {
      hostname: target.hostname,
      port: target.port || (target.protocol === 'https:' ? 443 : 80),
      path: target.pathname + target.search,
      method,
      headers,
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    }
  );

  proxyReq.setTimeout(timeoutMs, () => proxyReq.destroy(new Error('upstream timeout')));
  proxyReq.on('error', (err) => {
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end('proxy error: ' + err.message);
  });

  if (method === 'GET' || method === 'HEAD') {
    proxyReq.end();
  } else {
    req.pipe(proxyReq);
  }
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  // Serve the console UI
  if (req.method === 'GET' && (url === '/' || url === '/index.html')) {
    fs.readFile(HTML_FILE, (err, data) => {
      if (err) {
        res.writeHead(500, { 'Content-Type': 'text/plain' });
        res.end('call-console.html not found next to server.js');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(data);
    });
    return;
  }

  // Tell the frontend what it's talking to (display only)
  if (req.method === 'GET' && url === '/config') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      whisperUrl: WHISPER_URL,
      btAddress: BT_ADDRESS,
      btSource: BT_SOURCE,
    }));
    return;
  }

  // Lightweight reachability check
  if (req.method === 'GET' && url === '/health') {
    const target = new URL('/', WHISPER_URL);
    const lib = target.protocol === 'https:' ? https : http;
    const check = lib.request(
      { hostname: target.hostname, port: target.port || 80, path: '/', method: 'GET', timeout: 4000 },
      (r) => { res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end('ok'); r.resume(); }
    );
    check.on('timeout', () => check.destroy(new Error('timeout')));
    check.on('error', () => { res.writeHead(503, { 'Content-Type': 'text/plain' }); res.end('unreachable'); });
    check.end();
    return;
  }

  // Proxy the actual transcription/translation requests
  if (req.method === 'POST' && url === '/inference') {
    proxyRequest(WHISPER_URL.replace(/\/$/, '') + '/inference', req, res, { timeoutMs: 60000 });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('not found');
});

server.listen(PORT, () => {
  console.log(`Vermittlung console:  http://localhost:${PORT}`);
  console.log(`Proxying audio to:    ${WHISPER_URL}`);
  if (BT_SOURCE) console.log(`Expected BT source:   ${BT_SOURCE}`);
});
