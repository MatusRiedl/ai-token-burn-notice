// Aggregates Claude Code token usage from ~/.claude/projects/**/*.jsonl into
// rolling windows (1h, 6h, 24h, 7d, 30d), per model, with estimated API-price cost,
// plus the current plan week split into 7 day slots. The weekly % is an estimate:
// calibration.json holds one % reading from Settings > Usage, which converts API-price cost to %.
// Incremental: logs are append-only, so each run only parses bytes added since last run.
// Usage: node aggregate.js [outFile]
// State (cache, prices, calibration, output) lives in %LOCALAPPDATA%\AIBurnNotice, or $BURN_NOTICE_DATA.
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');
const https = require('https');

const DATA_DIR = process.env.BURN_NOTICE_DATA || path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), '.local', 'share'), 'AIBurnNotice');
fs.mkdirSync(DATA_DIR, { recursive: true });
const PROJECTS = path.join(os.homedir(), '.claude', 'projects');
const CACHE_FILE = path.join(DATA_DIR, 'cache.json');
const PRICES_FILE = path.join(DATA_DIR, 'prices.json');
const CALIB_FILE = path.join(DATA_DIR, 'calibration.json');
const OUT_FILE = process.argv[2] || path.join(DATA_DIR, 'usage.json');
const PRICES_URL = 'https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json';
const DAY = 86400000;
const KEEP_MS = 31 * DAY;
const WINDOWS = [
  { key: '1h', label: 'Past hour', ms: 3600000 },
  { key: '6h', label: 'Past 6 hours', ms: 6 * 3600000 },
  { key: '24h', label: 'Past 24 hours', ms: DAY },
  { key: '7d', label: 'Past 7 days', ms: 7 * DAY },
  { key: '30d', label: 'Past 30 days', ms: 30 * DAY },
];
// Weekly plan limit resets Sunday 05:00 local time.
const RESET_DAY = 0;
const RESET_HOUR = 5;
const DAY_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function readJson(file, fallback) {
  // Strip a BOM (PowerShell 5.1 writes one with -Encoding UTF8)
  try { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, '')); } catch { return fallback; }
}

// Start of the plan week containing t, in local time.
function weekStart(t) {
  const d = new Date(t);
  d.setHours(RESET_HOUR, 0, 0, 0);
  d.setDate(d.getDate() - ((d.getDay() - RESET_DAY + 7) % 7));
  if (d.getTime() > t) d.setDate(d.getDate() - 7);
  return d;
}

// 8 boundaries: start of each day slot, then the reset. Local-date arithmetic keeps 05:00 across DST.
function weekBounds(t) {
  const ws = weekStart(t);
  return Array.from({ length: 8 }, (_, i) => { const d = new Date(ws); d.setDate(d.getDate() + i); return d.getTime(); });
}

// One % reading converts API-price cost to % of the weekly limit: budget = cost so far that week / pct.
// The cost is computed once and written back, because old records get pruned from the cache.
function loadCalibration(recs, now) {
  const c = readJson(CALIB_FILE, null);
  if (!c || !(c.pct > 0) || !(c.at > 0)) return null;
  if (typeof c.cost !== 'number') {
    const from = weekStart(c.at).getTime();
    if (now - from > KEEP_MS) return null;
    c.cost = 0;
    for (const x of recs) if (x.ts >= from && x.ts <= c.at && x.cost !== null) c.cost += x.cost;
    fs.writeFileSync(CALIB_FILE, JSON.stringify(c));
  }
  return { pct: c.pct, at: c.at, cost: c.cost, budget: c.cost > 0 ? c.cost / (c.pct / 100) : null };
}

function fetchText(url) {
  return new Promise((resolve, reject) => {
    https.get(url, { timeout: 15000 }, (res) => {
      if (res.statusCode !== 200) { res.resume(); return reject(new Error('HTTP ' + res.statusCode)); }
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (c) => (data += c));
      res.on('end', () => resolve(data));
    }).on('error', reject).on('timeout', function () { this.destroy(new Error('timeout')); });
  });
}

// LiteLLM price table (same source ccusage uses), refreshed once a day; keeps only Claude entries.
async function loadPrices() {
  const cached = readJson(PRICES_FILE, null);
  if (cached && Date.now() - cached.fetchedAt < DAY) return cached.models;
  try {
    const all = JSON.parse(await fetchText(PRICES_URL));
    const models = {};
    for (const [k, v] of Object.entries(all)) {
      if (!/claude/i.test(k) || typeof v.input_cost_per_token !== 'number') continue;
      models[k] = {
        in: v.input_cost_per_token,
        out: v.output_cost_per_token || 0,
        cw5: v.cache_creation_input_token_cost ?? v.input_cost_per_token * 1.25,
        cw1h: v.cache_creation_input_token_cost_above_1hr ?? v.input_cost_per_token * 2,
        cr: v.cache_read_input_token_cost ?? v.input_cost_per_token * 0.1,
      };
    }
    fs.writeFileSync(PRICES_FILE, JSON.stringify({ fetchedAt: Date.now(), models }));
    return models;
  } catch {
    return cached ? cached.models : {};
  }
}

function priceFor(prices, model) {
  const base = model.replace(/-\d{8}$/, '');
  return prices[model] || prices[base] || prices['anthropic/' + model] || prices['anthropic/' + base] || null;
}

function listJsonl(dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) listJsonl(p, out);
    else if (e.name.endsWith('.jsonl')) out.push(p);
  }
  return out;
}

// Record: [timestampMs, model, input, output, cacheWrite5m, cacheWrite1h, cacheRead, dedupeKey]
function parseLine(line) {
  if (!line.includes('"usage"')) return null;
  let j;
  try { j = JSON.parse(line); } catch { return null; }
  const m = j.message;
  if (!m || !m.usage || !m.model || m.model === '<synthetic>') return null;
  const u = m.usage;
  const ts = Date.parse(j.timestamp);
  if (!ts) return null;
  const cwTotal = u.cache_creation_input_tokens || 0;
  let cw1h = 0, cw5 = cwTotal;
  if (u.cache_creation) {
    cw1h = u.cache_creation.ephemeral_1h_input_tokens || 0;
    cw5 = Math.max(0, cwTotal - cw1h);
  }
  const key = m.id && j.requestId ? m.id + ':' + j.requestId : (m.id || null);
  return [ts, m.model, u.input_tokens || 0, u.output_tokens || 0, cw5, cw1h, u.cache_read_input_tokens || 0, key];
}

function updateFile(file, entry, stat) {
  // Truncated/rewritten file: start over.
  if (!entry || stat.size < entry.offset) entry = { offset: 0, records: [] };
  if (stat.size === entry.offset) return entry;
  // Read in chunks (some session logs exceed V8's max string length); carry partial lines over.
  const CHUNK = 32 * 1024 * 1024;
  const fd = fs.openSync(file, 'r');
  try {
    let pos = entry.offset;
    let carry = Buffer.alloc(0);
    while (pos < stat.size) {
      const buf = Buffer.allocUnsafe(Math.min(CHUNK, stat.size - pos));
      const n = fs.readSync(fd, buf, 0, buf.length, pos);
      if (n <= 0) break;
      pos += n;
      const data = carry.length ? Buffer.concat([carry, buf.subarray(0, n)]) : buf.subarray(0, n);
      let start = 0, nl;
      while ((nl = data.indexOf(10, start)) >= 0) {
        // Only usage lines matter; skip decoding giant tool-result lines that can't contain them.
        const slice = data.subarray(start, nl);
        if (slice.indexOf('"usage"') >= 0) {
          const r = parseLine(slice.toString('utf8'));
          if (r) entry.records.push(r);
        }
        start = nl + 1;
      }
      carry = Buffer.from(data.subarray(start));
    }
    entry.offset = pos - carry.length; // leave any incomplete last line for next run
  } finally { fs.closeSync(fd); }
  return entry;
}

function emptyTotals() { return { tokens: 0, input: 0, output: 0, cacheWrite: 0, cacheRead: 0, cost: 0, unpriced: false }; }

function add(t, r, cost) {
  const [, , i, o, cw5, cw1h, cr] = r;
  t.input += i; t.output += o; t.cacheWrite += cw5 + cw1h; t.cacheRead += cr;
  t.tokens += i + o + cw5 + cw1h + cr;
  if (cost === null) t.unpriced = true; else t.cost += cost;
}

async function main() {
  const now = Date.now();
  const cache = readJson(CACHE_FILE, { files: {} });
  const files = {};
  for (const f of listJsonl(PROJECTS)) {
    let stat;
    try { stat = fs.statSync(f); } catch { continue; }
    if (now - stat.mtimeMs > KEEP_MS) continue; // nothing in it can fall inside 30 days
    const entry = updateFile(f, cache.files[f], stat);
    entry.records = entry.records.filter((r) => now - r[0] <= KEEP_MS);
    files[f] = entry;
  }
  fs.writeFileSync(CACHE_FILE, JSON.stringify({ files }));

  const prices = await loadPrices();
  // Deduped, priced records shared by the windows, the week and the calibration.
  const seen = new Set();
  const recs = [];
  for (const entry of Object.values(files)) {
    for (const r of entry.records) {
      const key = r[7];
      if (key) { if (seen.has(key)) continue; seen.add(key); }
      const p = priceFor(prices, r[1]);
      const cost = p ? r[2] * p.in + r[3] * p.out + r[4] * p.cw5 + r[5] * p.cw1h + r[6] * p.cr : null;
      recs.push({ ts: r[0], r, cost });
    }
  }

  const windows = WINDOWS.map((w) => ({ ...w, totals: emptyTotals(), models: {} }));
  for (const { ts, r, cost } of recs) {
    const age = now - ts;
    const model = r[1].replace(/^claude-/, '').replace(/-\d{8}$/, '');
    for (const w of windows) {
      if (age > w.ms || age < -60000) continue;
      add(w.totals, r, cost);
      add((w.models[model] ||= emptyTotals()), r, cost);
    }
  }

  const bounds = weekBounds(now);
  const weekTotals = emptyTotals();
  const days = bounds.slice(0, 7).map((start) => ({ label: DAY_NAMES[new Date(start).getDay()], start, totals: emptyTotals() }));
  for (const { ts, r, cost } of recs) {
    if (ts < bounds[0] || ts >= bounds[7]) continue;
    let i = 6;
    while (ts < bounds[i]) i--;
    add(days[i].totals, r, cost);
    add(weekTotals, r, cost);
  }
  const cal = loadCalibration(recs, now);
  const pctOf = (cost) => (cal && cal.budget ? (100 * cost) / cal.budget : null);

  const out = {
    generatedAt: new Date(now).toISOString(),
    pricesKnown: Object.keys(prices).length > 0,
    windows: windows.map((w) => ({
      key: w.key,
      label: w.label,
      totals: w.totals,
      models: Object.entries(w.models)
        .map(([model, t]) => ({ model, ...t }))
        .sort((a, b) => b.cost - a.cost || b.tokens - a.tokens),
    })),
    week: {
      start: bounds[0],
      end: bounds[7],
      totals: weekTotals,
      pct: pctOf(weekTotals.cost),
      calibration: cal,
      days: days.map((d) => ({ label: d.label, start: d.start, tokens: d.totals.tokens, cost: d.totals.cost, pct: pctOf(d.totals.cost) })),
    },
  };
  fs.writeFileSync(OUT_FILE + '.tmp', JSON.stringify(out, null, 1));
  fs.renameSync(OUT_FILE + '.tmp', OUT_FILE);
}

main().catch((e) => { console.error(e && e.stack || e); process.exit(1); });
