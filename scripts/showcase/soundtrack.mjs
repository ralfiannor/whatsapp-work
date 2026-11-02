// Synthesized soundtrack for the showcase: a soft four-chord bed with bass,
// plucks and light drums, plus UI sound effects on the cues the page emits
// (typing, clicks, whooshes). Pure math, no samples, so the audio carries no
// third-party rights. Returns a 16-bit stereo WAV buffer.
const SR = 44100;
const BEAT = 0.6; // 100 BPM
const CHORDS = [ // [bass, ...pad] as MIDI notes, two bars each
  [43, 55, 59, 62, 66, 69], // Gmaj9
  [40, 52, 55, 59, 62, 66], // Em9
  [36, 48, 52, 55, 59, 62], // Cmaj9
  [38, 50, 57, 62, 64, 66], // D6/9
];
const CHORD_LEN = 8 * BEAT;
const DRUMS = [8.4, 52.4];   // kick + bass section
const HATS = [14.6, 52.4];
const FINAL = 57.0;          // last chord under the end card

const hz = (m) => 440 * Math.pow(2, (m - 69) / 12);
const hash = (n) => { const s = Math.sin(n * 127.1 + 311.7) * 43758.5453; return s - Math.floor(s); };

export function synthesize({ duration, cues }) {
  const n = Math.ceil(duration * SR);
  const L = new Float32Array(n), R = new Float32Array(n);
  const pad = new Float32Array(n);
  let seed = 22222;
  const noise = () => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return ((seed >>> 0) / 4294967296) * 2 - 1; };
  const idx = (t) => Math.round(t * SR);

  // voice(t0, len, fn(t) → sample, pan -1..1)
  function voice(t0, len, fn, pan = 0, gain = 1) {
    const a = Math.max(0, idx(t0)), b = Math.min(n, idx(t0 + len));
    const gl = gain * Math.sqrt((1 - pan) / 2), gr = gain * Math.sqrt((1 + pan) / 2);
    for (let i = a; i < b; i++) { const v = fn(i / SR - t0); L[i] += v * gl; R[i] += v * gr; }
  }
  const soft = (ph) => Math.sin(ph) + 0.25 * Math.sin(2 * ph) + 0.1 * Math.sin(3 * ph);

  // ---- pad (mono bus, low-passed and ducked by the kick later) ----
  const chordAt = (t) => (t >= FINAL ? CHORDS[0] : CHORDS[Math.floor(t / CHORD_LEN) % CHORDS.length]);
  const segs = [];
  for (let t = 0; t < FINAL; t += CHORD_LEN) segs.push([t, Math.min(t + CHORD_LEN, FINAL), chordAt(t)]);
  segs.push([FINAL, duration, CHORDS[0]]);
  for (const [t0, t1, ch] of segs) {
    const a = idx(Math.max(0, t0 - 0.05)), b = Math.min(n, idx(t1 + 0.9));
    for (const m of ch.slice(1)) {
      const f = hz(m);
      for (let i = a; i < b; i++) {
        const t = i / SR;
        const env = Math.min(1, (t - t0 + 0.05) / 0.6) * (t > t1 ? Math.max(0, 1 - (t - t1) / 0.9) : 1);
        const lfo = 1 + 0.15 * Math.sin(2 * Math.PI * 0.21 * t + m);
        pad[i] += 0.03 * env * lfo * (soft(2 * Math.PI * f * 0.9983 * t) + soft(2 * Math.PI * f * 1.0017 * t)) * 0.5;
      }
    }
  }

  // ---- bass ----
  for (let t = DRUMS[0] - 1.8; t < DRUMS[1] + 0.6; t += 4 * BEAT) {
    for (const off of [0, 1.5 * BEAT, 2.5 * BEAT]) {
      const f = hz(chordAt(t + off)[0]);
      voice(t + off, 1.0, (u) => Math.min(1, u / 0.008) * Math.exp(-u / 0.45) * (Math.sin(2 * Math.PI * f * u) + 0.15 * Math.sin(4 * Math.PI * f * u)), 0, off ? 0.11 : 0.15);
    }
  }
  voice(FINAL, duration - FINAL, (u) => Math.min(1, u / 0.02) * Math.exp(-u / 1.6) * Math.sin(2 * Math.PI * hz(43) * u), 0, 0.15);

  // ---- plucks: quarters in the intro, eighths once the film gets going ----
  const PAT = [0, 2, 4, 1, 3, 2, 4, 3];
  for (let k = 0, t = 2 * BEAT; t < 52.4; k++, t += BEAT / 2) {
    const intro = t < 6.6;
    if (intro && k % 2) continue;
    if (!intro && hash(k) < 0.12) continue;
    const ch = chordAt(t).slice(1), m = ch[PAT[k % PAT.length] % ch.length] + 12;
    const f = hz(m), vel = 0.75 + 0.25 * hash(k + 9);
    voice(t, 1.0, (u) => Math.min(1, u / 0.004) * Math.exp(-u / 0.28) * soft(2 * Math.PI * f * u), k % 2 ? 0.3 : -0.3, (intro ? 0.035 : 0.045) * vel);
  }

  // ---- drums ----
  const duck = new Float32Array(n).fill(1);
  for (let t = DRUMS[0]; t < DRUMS[1]; t += 2 * BEAT) {
    let ph = 0;
    voice(t, 0.5, (u) => { ph += 2 * Math.PI * (48 + 70 * Math.exp(-u / 0.035)) / SR; return Math.exp(-u / 0.22) * (1 - Math.exp(-u / 0.002)) * Math.sin(ph); }, 0, 0.3);
    for (let i = idx(t); i < Math.min(n, idx(t + 0.4)); i++) duck[i] = Math.min(duck[i], 1 - 0.35 * Math.exp(-(i / SR - t) / 0.12));
  }
  for (let t = HATS[0] + BEAT / 2; t < HATS[1]; t += BEAT) {
    let prev = 0;
    voice(t, 0.12, (u) => { const x = noise(); const y = (x - prev) * Math.exp(-u / 0.025); prev = x; return y; }, 0.2, 0.025);
  }

  // ---- UI sound effects ----
  function swept(t0, len, f0, f1, f2, gain, panFrom = 0, panTo = 0) {
    let y = 0;
    const a = idx(t0), b = Math.min(n, idx(t0 + len));
    for (let i = a; i < b; i++) {
      const u = (i / SR - t0) / len;
      const fc = u < 0.5 ? f0 + (f1 - f0) * (u * 2) : f1 + (f2 - f1) * ((u - 0.5) * 2);
      y += (1 - Math.exp(-2 * Math.PI * fc / SR)) * (noise() - y);
      const amp = gain * Math.pow(Math.sin(Math.PI * u), 2);
      const pan = panFrom + (panTo - panFrom) * u;
      L[i] += y * amp * Math.sqrt((1 - pan) / 2) * 1.4; R[i] += y * amp * Math.sqrt((1 + pan) / 2) * 1.4;
    }
  }
  const bell = (t, f, len, gain, pan = 0) => voice(t, len, (u) => Math.min(1, u / 0.003) * (Math.exp(-u / (len / 3)) * Math.sin(2 * Math.PI * f * u) + 0.3 * Math.exp(-u / (len / 6)) * Math.sin(2 * Math.PI * f * 2.76 * u) + 0.12 * Math.exp(-u / (len / 10)) * Math.sin(2 * Math.PI * f * 5.4 * u)), pan, gain);
  let keyN = 0;
  for (const { t, k, v } of cues) {
    switch (k) {
      case 'key': {
        const f = 1900 + 500 * hash(++keyN), pan = (hash(keyN + 3) - 0.5) * 0.4;
        voice(t, 0.04, (u) => Math.exp(-u / 0.005) * noise() * 0.6 + Math.exp(-u / 0.01) * Math.sin(2 * Math.PI * f * u) * 0.35, pan, 0.14 * v);
        break;
      }
      case 'press':
        voice(t, 0.25, (u) => Math.exp(-u / 0.07) * Math.sin(2 * Math.PI * (120 + 100 * Math.exp(-u / 0.02)) * u) + Math.exp(-u / 0.012) * noise() * 0.3, 0, 0.3 * v);
        break;
      case 'click':
        voice(t, 0.03, (u) => Math.exp(-u / 0.004) * noise() * 0.5 + Math.exp(-u / 0.008) * Math.sin(2 * Math.PI * 3000 * u), 0.1, 0.12);
        voice(t + 0.07, 0.03, (u) => Math.exp(-u / 0.003) * noise() * 0.5 + Math.exp(-u / 0.006) * Math.sin(2 * Math.PI * 3400 * u), 0.1, 0.06);
        break;
      case 'tick':
        voice(t, 0.08, (u) => Math.exp(-u / 0.02) * Math.sin(2 * Math.PI * 1250 * u), 0.15, 0.06 * v);
        break;
      case 'pop': {
        let ph = 0;
        voice(t, 0.15, (u) => { ph += 2 * Math.PI * (500 + 450 * Math.min(1, u / 0.05)) / SR; return Math.exp(-u / 0.05) * Math.sin(ph); }, 0, 0.12 * v);
        break;
      }
      case 'ding':
        bell(t, 1318.5, 0.9, 0.06 * v, 0.1); bell(t + 0.06, 1975.5, 0.7, 0.035 * v, -0.1);
        break;
      case 'whoosh':
        swept(t, 0.75, 300, 4200, 400, 0.2 * v, -0.6, 0.6);
        break;
      case 'send': case 'swipe':
        swept(t, 0.3, 700, 5000, 3000, 0.12 * v, 0, 0.4);
        break;
      case 'riser': {
        swept(t, 0.85, 200, 2500, 7000, 0.18 * v, -0.2, 0.2);
        let ph = 0;
        voice(t, 0.8, (u) => { ph += 2 * Math.PI * (220 * Math.pow(5, u / 0.8)) / SR; return (u / 0.8) * Math.sin(ph); }, 0, 0.04 * v);
        break;
      }
      case 'chime':
        [hz(79), hz(83), hz(86), hz(90)].forEach((f, i) => bell(t + i * 0.045, f, 2.4, 0.055, (i - 1.5) * 0.25));
        break;
    }
  }

  // ---- mix ----
  let y = 0;
  const a = 1 - Math.exp(-2 * Math.PI * 1900 / SR);
  for (let i = 0; i < n; i++) {
    y += a * (pad[i] - y);
    const t = i / SR, d = t > DRUMS[0] && t < DRUMS[1] ? duck[i] : 1;
    L[i] += y * d; R[i] += y * d;
  }
  let peak = 0;
  for (let i = 0; i < n; i++) peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i]));
  const g = 0.89 / (peak || 1);
  const buf = Buffer.alloc(44 + n * 4);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * 4, 4); buf.write('WAVE', 8);
  buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(2, 22);
  buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 4, 28); buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34);
  buf.write('data', 36); buf.writeUInt32LE(n * 4, 40);
  for (let i = 0; i < n; i++) {
    const t = i / SR, fade = Math.min(1, t / 0.05, (duration - t) / 2.2);
    buf.writeInt16LE(Math.round(Math.tanh(L[i] * g * 1.1) * fade * 32767), 44 + i * 4);
    buf.writeInt16LE(Math.round(Math.tanh(R[i] * g * 1.1) * fade * 32767), 46 + i * 4);
  }
  return buf;
}
