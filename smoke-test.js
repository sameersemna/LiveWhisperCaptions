// Lightweight smoke test — no npm deps, no GPU box, no phone call needed.
//
// Runs `node --check` on server.js, then spins up a fake whisper-server (plain node:http,
// answers /inference with canned text and / with 200 for the health check) and a real
// server.js pointed at it via env vars, and exercises /config, /health, /transcribe and
// /translate end to end. Verifies the response text round-trips correctly through the proxy.
//
// Usage: node smoke-test.js

const http = require('http');
const https = require('https');
const fs = require('fs');
const { spawn, execFileSync } = require('child_process');
const path = require('path');

// server.js serves HTTPS automatically when cert.pem/key.pem sit next to it (see CLAUDE.md,
// "Accessing from other LAN machines") — mirror that same detection here so this test talks
// whichever protocol the spawned server will actually use.
const USE_HTTPS = fs.existsSync(path.join(__dirname, 'cert.pem')) && fs.existsSync(path.join(__dirname, 'key.pem'));
const httpLib = USE_HTTPS ? https : http;

const ROOT = __dirname;
let failures = 0;

function check(label, cond, detail){
  if (cond){
    console.log(`  ok — ${label}`);
  } else {
    failures++;
    console.log(`  FAIL — ${label}${detail ? ` (${detail})` : ''}`);
  }
}

function buildMultipart(fields){
  const boundary = '----smoketest' + Date.now();
  let body = '';
  for (const [name, value] of Object.entries(fields)){
    body += `--${boundary}\r\nContent-Disposition: form-data; name="${name}"`;
    if (name === 'file') body += `; filename="chunk.wav"\r\nContent-Type: audio/wav`;
    body += `\r\n\r\n${value}\r\n`;
  }
  body += `--${boundary}--\r\n`;
  return { boundary, body: Buffer.from(body, 'utf8') };
}

function request(opts, body){
  return new Promise((resolve, reject) => {
    // rejectUnauthorized:false — this hits our own self-signed cert.pem, not a real CA.
    const req = httpLib.request({ ...opts, rejectUnauthorized: false }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function waitForPort(port, timeoutMs){
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const req = httpLib.get({ hostname: '127.0.0.1', port, path: '/config', timeout: 500, rejectUnauthorized: false }, (res) => {
        res.resume();
        resolve();
      });
      req.on('error', () => {
        if (Date.now() > deadline) reject(new Error(`nothing listening on :${port} after ${timeoutMs}ms`));
        else setTimeout(attempt, 100);
      });
      req.on('timeout', () => req.destroy());
    };
    attempt();
  });
}

async function main(){
  console.log('1. Syntax check');
  execFileSync(process.execPath, ['--check', path.join(ROOT, 'server.js')], { stdio: 'inherit' });
  check('server.js --check', true);

  console.log('\n2. Starting fake whisper-server');
  const FAKE_TRANSCRIPT = 'Das ist ein Testsatz.';
  const fakeWhisper = http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/'){
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('whisper.cpp fake server');
      return;
    }
    if (req.method === 'POST' && req.url === '/inference'){
      // Real whisper-server would parse the multipart body; the fake just returns canned
      // text regardless of content, since this test is about the proxy plumbing, not ASR.
      req.resume();
      req.on('end', () => {
        res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end(FAKE_TRANSCRIPT);
      });
      return;
    }
    res.writeHead(404).end();
  });
  await new Promise((resolve) => fakeWhisper.listen(0, '127.0.0.1', resolve));
  const fakePort = fakeWhisper.address().port;
  check(`fake whisper-server listening on :${fakePort}`, true);

  console.log('\n3. Starting server.js against the fake backend');
  const serverPort = 0; // request an ephemeral port below via a probe, then pass it explicitly
  const net = require('net');
  const probe = net.createServer();
  await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
  const chosenPort = probe.address().port;
  await new Promise((resolve) => probe.close(resolve));

  const child = spawn(process.execPath, [path.join(ROOT, 'server.js')], {
    cwd: ROOT,
    env: {
      ...process.env,
      PORT: String(chosenPort),
      WHISPER_HOST: `127.0.0.1:${fakePort}`,
      TRANSLATE_MODE: 'whisper', // avoids needing Ollama/Google reachable for this test
      OLLAMA_MODEL: '',
      BT_SOURCE: '',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let serverOutput = '';
  child.stdout.on('data', (d) => { serverOutput += d; });
  child.stderr.on('data', (d) => { serverOutput += d; });

  try {
    await waitForPort(chosenPort, 5000);
    check(`server.js listening on :${chosenPort}`, true);

    console.log('\n4. Exercising endpoints');
    const cfgRes = await request({ hostname: '127.0.0.1', port: chosenPort, path: '/config', method: 'GET' });
    let cfg = {};
    try { cfg = JSON.parse(cfgRes.body); } catch (e) {}
    check('/config returns 200', cfgRes.status === 200);
    check('/config reports the fake whisper backend', cfg.whisperUrl === `http://127.0.0.1:${fakePort}`, cfg.whisperUrl);
    check('/config reports translateMode=whisper', cfg.translateMode === 'whisper', cfg.translateMode);

    const healthRes = await request({ hostname: '127.0.0.1', port: chosenPort, path: '/health', method: 'GET' });
    check('/health returns 200 when whisper backend is reachable', healthRes.status === 200, healthRes.status);

    const { boundary, body } = buildMultipart({
      file: 'RIFF....WAVEfmt ....data....', // content is irrelevant — fake backend ignores it
      language: 'de',
      translate: 'false',
      response_format: 'text',
      temperature: '0',
      temperature_inc: '0.2',
    });
    const transcribeRes = await request({
      hostname: '127.0.0.1', port: chosenPort, path: '/transcribe', method: 'POST',
      headers: { 'Content-Type': `multipart/form-data; boundary=${boundary}`, 'Content-Length': body.length },
    }, body);
    check('/transcribe proxies through to whisper-server and back', transcribeRes.status === 200 && transcribeRes.body.trim() === FAKE_TRANSCRIPT,
      `status=${transcribeRes.status} body=${JSON.stringify(transcribeRes.body)}`);

    const translateRes = await request({
      hostname: '127.0.0.1', port: chosenPort, path: '/translate', method: 'POST',
      headers: { 'Content-Type': `multipart/form-data; boundary=${boundary}`, 'Content-Length': body.length },
    }, body);
    check('/translate (whisper mode) proxies through too', translateRes.status === 200 && translateRes.body.trim() === FAKE_TRANSCRIPT,
      `status=${translateRes.status} body=${JSON.stringify(translateRes.body)}`);

  } catch (err) {
    failures++;
    console.log(`  FAIL — ${err.message}`);
  } finally {
    child.kill();
    fakeWhisper.close();
    if (failures > 0){
      console.log('\n--- server.js output (for debugging) ---');
      console.log(serverOutput);
    }
  }

  console.log(`\n${failures === 0 ? 'All checks passed.' : failures + ' check(s) failed.'}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error('smoke test crashed:', err);
  process.exit(1);
});
