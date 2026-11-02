#!/usr/bin/env node
// Renders showcase.html into docs/media/showcase.mp4 (with a synthesized
// soundtrack) and docs/media/showcase.webp (silent README preview).
//
//   node scripts/showcase/render.mjs                  # full render
//   node scripts/showcase/render.mjs --still 12.2 …   # PNG stills → $TMPDIR
//
// Needs Node 22+, ffmpeg (libx264 + libwebp) and any Chromium-based browser
// (CHROME=/path/to/binary, else common macOS install paths are tried).
// No npm dependencies: the browser is driven over the DevTools protocol.
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { synthesize } from './soundtrack.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const outDir = join(root, 'docs/media');
const FPS = 30, W = 1280, H = 720, SCALE = 1.5; // 1920×1080 output

const stills = [];
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === '--still') stills.push(Number(process.argv[++i]));
}

function findChrome() {
  const candidates = [
    process.env.CHROME,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  ].filter(Boolean);
  const hit = candidates.find((c) => existsSync(c));
  if (!hit) throw new Error('no Chromium-based browser found; set CHROME=/path/to/binary');
  return hit;
}

function run(cmd, args, opts = {}) {
  const child = spawn(cmd, args, { stdio: ['pipe', 'inherit', 'inherit'], ...opts });
  const done = once(child, 'exit').then(([code]) => { if (code !== 0) throw new Error(`${cmd} exited ${code}`); });
  return { child, done };
}

async function launch() {
  const profile = mkdtempSync(join(tmpdir(), 'showcase-chrome-'));
  const port = 9300 + Math.floor(Math.random() * 500);
  const browser = spawn(findChrome(), [
    '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--hide-scrollbars', '--mute-audio',
    '--force-color-profile=srgb', '--allow-file-access-from-files', 'about:blank',
  ], { stdio: 'ignore' });
  const base = `http://127.0.0.1:${port}`;
  for (let i = 0; ; i++) {
    try { await fetch(`${base}/json/version`); break; } catch {
      if (i > 100) throw new Error('browser did not start');
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  const page = pathToFileURL(join(here, 'showcase.html')).href + '?render';
  const tab = await (await fetch(`${base}/json/new?${page}`, { method: 'PUT' })).json();
  const ws = new WebSocket(tab.webSocketDebuggerUrl);
  await once(ws, 'open');
  let id = 0; const pending = new Map();
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    const p = pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result);
  };
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    pending.set(++id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
    return r.result.value;
  };
  const close = async () => {
    ws.close(); browser.kill(); await once(browser, 'exit');
    rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  };
  await send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: SCALE, mobile: false });
  // the tab may still be loading when it is handed over
  for (let i = 0; !(await evaluate('document.readyState === "complete" && !!window.SHOWCASE_READY')); i++) {
    if (i > 100) throw new Error('showcase page did not load');
    await new Promise((r) => setTimeout(r, 100));
  }
  await evaluate('window.SHOWCASE_READY');
  const frame = async (t) => {
    await evaluate(`seek(${t})`);
    const shot = await send('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: W, height: H, scale: 1 } });
    return Buffer.from(shot.data, 'base64');
  };
  return { evaluate, frame, close };
}

const page = await launch();
try {
  if (stills.length) {
    const dir = mkdtempSync(join(tmpdir(), 'showcase-stills-'));
    for (const t of stills) writeFileSync(join(dir, `t${t.toFixed(2)}.png`), await page.frame(t));
    console.log(dir);
  } else {
    const duration = await page.evaluate('DURATION');
    const cues = await page.evaluate('SFX');
    const work = mkdtempSync(join(tmpdir(), 'showcase-'));
    const wav = join(work, 'soundtrack.wav');
    writeFileSync(wav, synthesize({ duration, cues }));
    mkdirSync(outDir, { recursive: true });
    const mp4 = join(outDir, 'showcase.mp4');
    const enc = run('ffmpeg', [
      '-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'png', '-i', '-',
      '-i', wav, '-map', '0:v', '-map', '1:a',
      '-c:v', 'libx264', '-preset', 'slow', '-crf', '20', '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
      '-c:a', 'aac', '-b:a', '160k', '-shortest', mp4,
    ]);
    const frames = Math.round(duration * FPS);
    for (let i = 0; i < frames; i++) {
      if (!enc.child.stdin.write(await page.frame(i / FPS))) await once(enc.child.stdin, 'drain');
      if (i % FPS === 0) process.stdout.write(`\r${(i / FPS).toFixed(0)}s / ${duration}s`);
    }
    enc.child.stdin.end();
    await enc.done;
    process.stdout.write('\n');
    // README preview: GitHub only plays committed media through <img>, so the
    // inline version is an animated WebP; the MP4 carries the sound.
    await run('ffmpeg', [
      '-y', '-loglevel', 'error', '-i', mp4, '-vf', 'fps=15,scale=960:-1:flags=lanczos',
      '-c:v', 'libwebp_anim', '-loop', '0', '-quality', '72', '-compression_level', '6', '-an',
      join(outDir, 'showcase.webp'),
    ], { stdio: ['ignore', 'inherit', 'inherit'] }).done;
    rmSync(work, { recursive: true, force: true });
    console.log(`wrote ${mp4} and showcase.webp`);
  }
} finally {
  await page.close();
}
