// Headless Chrome check of the rendered viewer (Chrome DevTools Protocol over
// the WebSocket built into Node >= 22). Drives the real page via file://:
//   * for sampled positions of all 24 runs, the 512 rendered memory cells
//     (text parsed as hex) are hashed and compared with the Python replay hashes
//   * R / W highlight counts per step
//   * keyboard (arrow, shift + arrow, space) and play
//   * no page errors, no horizontal overflow at phone width, light and dark
//   * screenshots to OUTDIR
// usage: node check_render.mjs ntt_player.html check_expected.json OUTDIR [chrome]
import { readFileSync, writeFileSync, mkdtempSync, existsSync, rmSync } from "node:fs";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import path from "node:path";

const [htmlPath, expPath, outDir, chromeBin = "google-chrome"] = process.argv.slice(2);
const exp = JSON.parse(readFileSync(expPath, "utf8"));
const profile = mkdtempSync(path.join(outDir, "chrome-profile-"));
const chrome = spawn(chromeBin, ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
  "--remote-debugging-port=0", "--user-data-dir=" + profile, "--window-size=1400,1000", "about:blank"], { stdio: "ignore" });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let checks = 0, bad = 0;
const cmp = (ok, msg) => { checks++; if (!ok) { bad++; if (bad < 25) console.log("FAIL " + msg); } };

async function main() {
  const portFile = path.join(profile, "DevToolsActivePort");
  for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
  const port = readFileSync(portFile, "utf8").split("\n")[0];
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((t) => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener("open", r));
  let id = 0;
  const pending = new Map();
  const errors = [];
  ws.addEventListener("message", (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    if (m.method === "Runtime.exceptionThrown") errors.push(m.params.exceptionDetails.text + " " + JSON.stringify(m.params.exceptionDetails.exception?.description || ""));
    if (m.method === "Runtime.consoleAPICalled" && m.params.type === "error") errors.push("console.error " + JSON.stringify(m.params.args));
    if (m.method === "Log.entryAdded" && m.params.entry.level === "error") errors.push("log " + m.params.entry.text + " " + (m.params.entry.url || ""));
  });
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  const ev = async (expr) => {
    const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.result?.exceptionDetails) throw new Error("eval: " + JSON.stringify(r.result.exceptionDetails));
    return r.result.result.value;
  };
  await send("Runtime.enable"); await send("Log.enable"); await send("Page.enable");
  const url = "file://" + path.resolve(htmlPath);
  await send("Page.navigate", { url });
  await sleep(1500);

  // helpers inside the page
  await ev(`window.__t = {
    sel(id, v) { const s = document.getElementById(id); s.value = v; s.dispatchEvent(new Event('change')); },
    pos(p) { const s = document.getElementById('scrub'); s.value = p; s.dispatchEvent(new Event('input')); },
    cells() { return Array.from(document.querySelectorAll('.c[data-i]')).map(c => parseInt(c.textContent, 16)); },
    cls(name) { return document.querySelectorAll('.c[data-i].' + name).length; },
    shown() { return +document.getElementById('pos').textContent; },
    key(k, shift) { document.dispatchEvent(new KeyboardEvent('keydown', { key: k, code: k === ' ' ? 'Space' : k, shiftKey: !!shift, bubbles: true })); },
  }; true`);

  const hashOf = (vals) => {
    const b = Buffer.alloc(1024);
    vals.forEach((v, i) => b.writeUInt16LE(v, 2 * i));
    return createHash("sha256").update(b).digest("hex").slice(0, 16);
  };
  cmp((await ev(`document.title`)) === "NTT Schedule Player", "title");
  cmp((await ev(`document.querySelectorAll('.c[data-i]').length`)) === 512, "512 cells");

  for (const key of Object.keys(exp)) {
    const [inp, op, algo] = key.split("/");
    await ev(`__t.sel('sel-op','${op}'); __t.sel('sel-algo','${algo}'); __t.sel('sel-input','${inp}'); true`);
    const N = exp[key].state.length - 1;
    cmp((await ev(`+document.getElementById('total').textContent`)) === N, `${key} total`);
    const sample = new Set([0, 1, 2, N - 1, N]);
    for (let p = 0; p <= N; p += op === "basemul" ? 37 : 61) sample.add(p);
    for (let b = 0; b <= N; b += op === "basemul" ? (N / 128) : 128) { sample.add(b); sample.add(Math.min(N, b + 1)); }
    for (const p of sample) {
      const r = await ev(`__t.pos(${p}); ({ v: __t.cells(), rd: __t.cls('rd'), wr: __t.cls('wr'), shown: __t.shown() })`);
      cmp(hashOf(r.v) === exp[key].state[p], `${key} pos ${p} rendered cells`);
      cmp(r.shown === p, `${key} pos ${p} counter`);
      if (op !== "basemul") {
        cmp(p === 0 ? r.rd === 0 && r.wr === 0 : r.rd === 2 && r.wr === 2, `${key} pos ${p} highlight rd ${r.rd} wr ${r.wr}`);
      } else {
        const nops = N / 128, o = (p - 1) % nops;
        const wantRd = p > 0 && o === 0 ? 4 : 0;
        cmp(r.rd === wantRd, `${key} pos ${p} basemul read highlight ${r.rd}`);
      }
    }
    // stepping forward cell by cell from a mid position must match too (incremental DOM path)
    const start = Math.floor(N / 3);
    await ev(`__t.pos(${start}); true`);
    for (let p = start + 1; p <= start + 20; p++) {
      const v = await ev(`__t.key('ArrowRight'); __t.cells()`);
      cmp(hashOf(v) === exp[key].state[p], `${key} ArrowRight to ${p}`);
    }
  }

  // keyboard and play on NTT barrett random
  await ev(`__t.sel('sel-op','ntt'); __t.sel('sel-algo','barrett'); __t.sel('sel-input','random'); __t.pos(5); true`);
  cmp((await ev(`__t.key('ArrowRight', true); __t.shown()`)) === 128, "shift+right to layer end");
  cmp((await ev(`__t.key('ArrowRight', true); __t.shown()`)) === 256, "shift+right next layer end");
  cmp((await ev(`__t.key('ArrowLeft', true); __t.shown()`)) === 128, "shift+left");
  cmp((await ev(`__t.key('ArrowLeft'); __t.shown()`)) === 127, "left");
  await ev(`__t.sel('sel-speed','100'); document.getElementById('sel-speed').dispatchEvent(new Event('change')); __t.pos(0); __t.key(' '); true`);
  await sleep(1000);
  const played = await ev(`__t.key(' '); __t.shown()`);
  cmp(played > 20 && played < 400, `play 1 s at 100 step/s advanced ${played}`);
  await ev(`__t.sel('sel-op','basemul'); __t.sel('sel-algo','mont12'); __t.pos(3); true`);
  cmp((await ev(`__t.key('ArrowRight', true); __t.shown()`)) === 7, "basemul shift+right to pair end");

  // layout: no horizontal overflow, both themes, desktop and phone
  const shots = [["desktop-light", 1400, "light"], ["desktop-dark", 1400, "dark"], ["phone-light", 390, "light"], ["phone-dark", 390, "dark"]];
  for (const [name, w, theme] of shots) {
    await send("Emulation.setDeviceMetricsOverride", { width: w, height: 900, deviceScaleFactor: 1, mobile: w < 600 });
    await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: theme }] });
    for (const [op, algo, p] of [["ntt", "mont12", 300], ["basemul", "k2red", 23]]) {
      await ev(`__t.sel('sel-op','${op}'); __t.sel('sel-algo','${algo}'); __t.sel('sel-input','random'); __t.pos(${p}); true`);
      await sleep(150);
      const ov = await ev(`({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth, bg: getComputedStyle(document.body).backgroundColor })`);
      cmp(ov.sw <= ov.cw, `${name} ${op} horizontal overflow ${ov.sw} > ${ov.cw}`);
      const shot = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
      writeFileSync(path.join(outDir, `shot-${name}-${op}.png`), Buffer.from(shot.result.data, "base64"));
      console.log(`screenshot ${name} ${op}: body bg ${ov.bg}`);
    }
  }
  cmp(errors.length === 0, "page errors: " + errors.join(" | "));
  console.log(`RENDER checks ${checks} mismatches ${bad}`);
  ws.close();
}

main().catch((e) => { console.log("ERROR " + e.stack); bad++; }).finally(async () => {
  chrome.kill("SIGTERM");
  await sleep(500);
  try { rmSync(profile, { recursive: true, force: true }); } catch (e) { /* profile cleanup is best effort */ }
  process.exit(bad ? 1 : 0);
});
