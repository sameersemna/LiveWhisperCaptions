// Vermittlung — local host + proxy for the live call console.
//
// Two translation strategies:
//   'whisper' (default) — two full Whisper passes per chunk (transcribe + translate).
//                          Simple, but doubles GPU decode work per chunk.
//   'llm'               — one Whisper pass (transcribe only) + a local Ollama model
//                          translates the resulting short text. Usually meaningfully
//                          faster since text translation is cheap next to audio decode.
//
// Set OLLAMA_MODEL in .env to opt into 'llm' mode automatically, or force either mode
// explicitly with TRANSLATE_MODE=llm|whisper.
//
// Usage:
//   node server.js
//
// No npm install needed — uses only Node's built-ins (requires Node 18+ for global fetch).

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
    return env;
  }
  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    let val = trimmed.slice(eq + 1).trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    env[key] = val;
  }
  return env;
}

const fileEnv = loadEnvFile(path.join(__dirname, '.env'));
const cfg = { ...fileEnv, ...process.env };

const PORT = parseInt(cfg.PORT || '3000', 10);
const WHISPER_HOST = cfg.WHISPER_HOST || '192.168.178.55:8768';
const WHISPER_URL = cfg.WHISPER_URL || (/^https?:\/\//.test(WHISPER_HOST) ? WHISPER_HOST : `http://${WHISPER_HOST}`);
const BT_ADDRESS = cfg.BT_ADDRESS || '';
const BT_SOURCE = cfg.BT_SOURCE || '';

const whisperHostname = WHISPER_HOST.replace(/^https?:\/\//, '').split(':')[0];
const OLLAMA_URL = cfg.OLLAMA_URL || `http://${whisperHostname}:11434`;
const OLLAMA_MODEL = cfg.OLLAMA_MODEL || '';
// Priority: explicit TRANSLATE_MODE > llm (if a model is configured) > whisper (double pass).
// 'google' uses Google's free unofficial translate endpoint — a real NMT model, no chat-model
// refusals/commentary. Recommended over 'llm' for translation quality.
const TRANSLATE_MODE = cfg.TRANSLATE_MODE || (OLLAMA_MODEL ? 'llm' : 'whisper');

const HTML_FILE = path.join(__dirname, 'call-console.html');
const FAVICON_FILE = path.join(__dirname, 'favicon.ico');

function log(label, ms) {
  console.log(`[${new Date().toISOString().slice(11, 19)}] ${label} — ${ms}ms`);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function proxyRequest(targetUrlStr, req, res, { label = 'proxy', timeoutMs = 60000 } = {}) {
  const t0 = Date.now();
  const target = new URL(targetUrlStr);
  const lib = target.protocol === 'https:' ? https : http;

  const headers = { ...req.headers };
  delete headers.host;

  const proxyReq = lib.request(
    {
      hostname: target.hostname,
      port: target.port || (target.protocol === 'https:' ? 443 : 80),
      path: target.pathname + target.search,
      method: req.method,
      headers,
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
      proxyRes.on('end', () => log(label, Date.now() - t0));
    }
  );

  proxyReq.setTimeout(timeoutMs, () => proxyReq.destroy(new Error('upstream timeout')));
  proxyReq.on('error', (err) => {
    log(label + ' [error]', Date.now() - t0);
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end('proxy error: ' + err.message);
  });

  req.pipe(proxyReq);
}

async function callOllamaTranslate(sourceText, sourceLangName) {
  const prompt =
    `Translate the following ${sourceLangName} text to natural, fluent English. ` +
    `Respond with only the English translation — no notes, no quotation marks, no preamble.\n\n` +
    `${sourceLangName}: ${sourceText}\nEnglish:`;

  const res = await fetch(`${OLLAMA_URL.replace(/\/$/, '')}/api/generate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: OLLAMA_MODEL,
      prompt,
      stream: false,
      options: { temperature: 0.2 },
    }),
  });
  if (!res.ok) throw new Error('ollama HTTP ' + res.status);
  const data = await res.json();
  return (data.response || '').trim();
}

async function callGoogleTranslate(sourceText, sourceLangCode) {
  const url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=${encodeURIComponent(sourceLangCode)}&tl=en&dt=t&q=${encodeURIComponent(sourceText)}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error('google translate HTTP ' + res.status);
  const data = await res.json();
  // Response shape: [[[translatedChunk, originalChunk, ...], ...], ...]
  const translated = (data[0] || []).map(seg => seg[0]).join('');
  return translated.trim();
}

const LANGUAGE_NAMES = {
  de:'German', en:'English', fr:'French', es:'Spanish', it:'Italian',
  pt:'Portuguese', nl:'Dutch', pl:'Polish', tr:'Turkish', ru:'Russian',
  ar:'Arabic', hi:'Hindi', ja:'Japanese', ko:'Korean', zh:'Chinese'
};

const server = http.createServer(async (req, res) => {
  const url = req.url.split('?')[0];

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

  if (req.method === 'GET' && url === '/favicon.ico') {
    fs.readFile(FAVICON_FILE, (err, data) => {
      if (err) {
        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('favicon.ico not found next to server.js');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'image/x-icon', 'Cache-Control': 'public, max-age=86400' });
      res.end(data);
    });
    return;
  }

  if (req.method === 'GET' && url === '/config') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      whisperUrl: WHISPER_URL,
      btAddress: BT_ADDRESS,
      btSource: BT_SOURCE,
      translateMode: TRANSLATE_MODE,
      ollamaModel: OLLAMA_MODEL,
    }));
    return;
  }

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

  // Always a single Whisper pass: transcribe German audio to German text.
  if (req.method === 'POST' && url === '/transcribe') {
    proxyRequest(WHISPER_URL.replace(/\/$/, '') + '/inference', req, res, { label: 'transcribe (whisper)' });
    return;
  }

  // Translate: 'google' (recommended — real NMT, no chat-model refusals/commentary),
  // 'llm' (Ollama text-translation), or 'whisper' (second full audio pass).
  if (req.method === 'POST' && url === '/translate') {
    if (TRANSLATE_MODE === 'google' || TRANSLATE_MODE === 'llm') {
      const t0 = Date.now();
      try {
        const bodyBuf = await readBody(req);
        const { text, sourceLang } = JSON.parse(bodyBuf.toString('utf8') || '{}');
        if (!text) {
          res.writeHead(400, { 'Content-Type': 'text/plain' });
          res.end('missing text');
          return;
        }
        const langCode = sourceLang || 'de';
        const langName = LANGUAGE_NAMES[langCode] || langCode;
        const translated = TRANSLATE_MODE === 'google'
          ? await callGoogleTranslate(text, langCode)
          : await callOllamaTranslate(text, langName);
        log(`translate (${TRANSLATE_MODE === 'google' ? 'google' : 'ollama/' + OLLAMA_MODEL})`, Date.now() - t0);
        res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end(translated);
      } catch (err) {
        log(`translate (${TRANSLATE_MODE}) [error]`, Date.now() - t0);
        res.writeHead(502, { 'Content-Type': 'text/plain' });
        res.end(`${TRANSLATE_MODE} error: ` + err.message);
      }
    } else {
      proxyRequest(WHISPER_URL.replace(/\/$/, '') + '/inference', req, res, { label: 'translate (whisper)' });
    }
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('not found');
});

server.listen(PORT, () => {
  console.log(`Vermittlung console:  http://localhost:${PORT}`);
  console.log(`Whisper backend:      ${WHISPER_URL}`);
  const modeDesc = TRANSLATE_MODE === 'google' ? 'Google Translate (unofficial endpoint)'
    : TRANSLATE_MODE === 'llm' ? `Ollama (${OLLAMA_URL}, model=${OLLAMA_MODEL})`
    : 'double whisper pass';
  console.log(`Translate mode:       ${TRANSLATE_MODE} — ${modeDesc}`);
  if (BT_SOURCE) console.log(`Expected BT source:   ${BT_SOURCE}`);
});