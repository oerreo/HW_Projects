// Checks of docs/viewer/sys_player.html (run from docs/viewer/tools, no arguments; Node >= 22).
//  1. static: no external reference (URL, <link>, src=, @import, fetch, XHR) in the HTML;
//     the embedded JSON equals build/data.json; the page script passes "node --check"
//     (written to build/page.js)
//  2. headless Chrome (CDP over Node's WebSocket, page loaded from file://; the Chrome profile
//     goes to the private TMPDIR): for every scene and every step, the rendered step counter,
//     the CYCLES / RD_STALL / WR_STALL text, the highlighted IP box, the highlighted HP boxes
//     (beats > 0) and the highlighted table row agree with the data; keyboard (arrows, Home,
//     End, space) and play; no page errors; no horizontal overflow at 400 px and 1300 px in
//     light and dark; screenshots to build/shots/.
// Chrome binary: environment CHROME (default google-chrome).
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, existsSync, rmSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
const htmlPath = path.join(here, "..", "sys_player.html");
const build = path.join(here, "build");
const shots = path.join(build, "shots");
mkdirSync(shots, { recursive: true });
let checks = 0, bad = 0;
const cmp = (ok, msg) => { checks++; if (!ok) { bad++; if (bad < 30) console.log("FAIL " + msg); } };

// ---------------- static ----------------
const html = readFileSync(htmlPath, "utf8");
const data = JSON.parse(readFileSync(path.join(build, "data.json"), "utf8"));
const ext = [/https?:\/\//i, /<link\b/i, /\bsrc\s*=/i, /@import/i, /\bfetch\s*\(/, /XMLHttpRequest/, /\burl\s*\(/i];
// the SVG namespace string of createElementNS is an identifier, not a request: it is the only URL allowed
const nsCount = html.split('"http://www.w3.org/2000/svg"').length - 1;
cmp(nsCount === 1, "SVG namespace string once: " + nsCount);
const html2 = html.split('"http://www.w3.org/2000/svg"').join('""');
for (const re of ext) cmp(!re.test(html2), "external reference " + re);
const m = html.match(/<script>\s*const DATA = ([\s\S]*?);\n\(function/);
cmp(!!m, "embedded DATA found");
if (m) cmp(JSON.stringify(JSON.parse(m[1].replace(/<\\\//g, "</"))) === JSON.stringify(data), "embedded JSON == build/data.json");
const script = html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>"));
writeFileSync(path.join(build, "page.js"), script);
const nc = spawnSync(process.execPath, ["--check", "page.js"], { cwd: build, encoding: "utf8" });
cmp(nc.status === 0, "node --check page.js: " + nc.stderr);
console.log(`STATIC checks ${checks} mismatches ${bad}`);

// ---------------- headless Chrome ----------------
const profile = mkdtempSync(path.join(tmpdir(), "p-"));
const chrome = spawn(process.env.CHROME || "google-chrome", ["--headless=new", "--disable-gpu", "--no-first-run",
  "--no-default-browser-check", "--remote-debugging-port=0", "--user-data-dir=" + profile,
  "--window-size=1300,1000", "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const fmt = (n) => n.toLocaleString("en-US");

async function main() {
  const portFile = path.join(profile, "DevToolsActivePort");
  for (let i = 0; i < 150 && !existsSync(portFile); i++) await sleep(100);
  const port = readFileSync(portFile, "utf8").split("\n")[0];
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const ws = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener("open", r));
  let id = 0;
  const pending = new Map(), errors = [];
  ws.addEventListener("message", (e) => {
    const q = JSON.parse(e.data);
    if (q.id && pending.has(q.id)) { pending.get(q.id)(q); pending.delete(q.id); }
    if (q.method === "Runtime.exceptionThrown") errors.push(q.params.exceptionDetails.text + " " + (q.params.exceptionDetails.exception?.description || ""));
    if (q.method === "Runtime.consoleAPICalled" && q.params.type === "error") errors.push("console.error " + JSON.stringify(q.params.args));
    if (q.method === "Log.entryAdded" && q.params.entry.level === "error") errors.push("log " + q.params.entry.text);
  });
  const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  const ev = async (expr) => {
    const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.result?.exceptionDetails) throw new Error("eval: " + JSON.stringify(r.result.exceptionDetails));
    return r.result.result.value;
  };
  await send("Runtime.enable"); await send("Log.enable"); await send("Page.enable");
  await send("Page.navigate", { url: "file://" + path.resolve(htmlPath) });
  await sleep(1500);
  await ev(`window.__t = {
    scene(k) { const s = document.getElementById('scene'); s.value = k; s.dispatchEvent(new Event('change')); },
    pos(p) { const s = document.getElementById('scrub'); s.value = p; s.dispatchEvent(new Event('input')); },
    key(k) { document.dispatchEvent(new KeyboardEvent('keydown', { key: k, code: k === ' ' ? 'Space' : k, bubbles: true })); },
    dd(name) { const dts = Array.from(document.querySelectorAll('#detail dt')); const d = dts.find(x => x.textContent === name); return d ? d.nextElementSibling.textContent : null; },
    state() {
      const svg = document.getElementById('blk');
      const rects = Array.from(svg.querySelectorAll('rect'));
      return {
        pos: document.getElementById('pos').textContent,
        cyc: this.dd('CYCLES'), rs: this.dd('RD_STALL'), ws: this.dd('WR_STALL'), ip: this.dd('IP'), run: this.dd('실행'),
        actText: rects.filter(r => (r.getAttribute('class') || '').includes('act')).map(r => r.nextSibling.textContent),
        row: Array.from(document.querySelectorAll('#tb tr.cur')).map(r => r.firstChild.textContent.trim()),
      };
    },
  }; true`);
  cmp((await ev(`document.title`)) === "System Op Player", "title");
  cmp((await ev(`document.getElementById('scene').options.length`)) === data.scenes.length, "scene options");
  const IPT = { ga: "gemv_acc", pi: "pim", at: "attn", ve: "vec" };
  for (let k = 0; k < data.scenes.length; k++) {
    const sc = data.scenes[k];
    await ev(`__t.scene(${k}); true`);
    const N = sc.steps.length;
    cmp((await ev(`+document.getElementById('scrub').max`)) === N - 1, `${sc.id} scrub max`);
    for (let i = 0; i < N; i++) {
      const st = sc.steps[i];
      const r = await ev(`__t.pos(${i}); __t.state()`);
      cmp(r.pos === `step ${i + 1} / ${N}`, `${sc.id} ${i} counter ${r.pos}`);
      if (st.t === "ip") {
        cmp(r.cyc === fmt(st.cyc) && r.rs === fmt(st.rs) && r.ws === fmt(st.ws), `${sc.id} ${i} cycles text ${r.cyc} ${r.rs} ${r.ws}`);
        const want = ["M_AXI_GP0 -> axil_xbar (AXI4-Lite, slot 4 KiB)", IPT[st.ip]];
        for (let h = 0; h < 4; h++) if (st.hp[2 * h] + st.hp[2 * h + 1] > 0) want.push("HP" + h);
        cmp(JSON.stringify(r.actText.slice().sort()) === JSON.stringify(want.slice().sort()), `${sc.id} ${i} highlight ${r.actText} want ${want}`);
        cmp(r.row.length === 1 && r.row[0].endsWith(" " + st.k), `${sc.id} ${i} table row ${r.row}`);
      } else {
        cmp(r.run === "ARM (PS)" && r.cyc === null, `${sc.id} ${i} ARM detail`);
        cmp(JSON.stringify(r.actText) === JSON.stringify(["PS: ARM Cortex-A9"]), `${sc.id} ${i} ARM highlight ${r.actText}`);
        cmp(r.row.length === 0, `${sc.id} ${i} ARM no table row`);
      }
    }
  }
  // keyboard and play (scene 1)
  await ev(`__t.scene(0); __t.pos(10); true`);
  const N0 = data.scenes[0].steps.length;
  cmp((await ev(`__t.key('ArrowRight'); document.getElementById('pos').textContent`)) === `step 12 / ${N0}`, "ArrowRight");
  cmp((await ev(`__t.key('ArrowLeft'); __t.key('ArrowLeft'); document.getElementById('pos').textContent`)) === `step 10 / ${N0}`, "ArrowLeft");
  cmp((await ev(`__t.key('End'); document.getElementById('pos').textContent`)) === `step ${N0} / ${N0}`, "End");
  cmp((await ev(`__t.key('Home'); document.getElementById('pos').textContent`)) === `step 1 / ${N0}`, "Home");
  await ev(`const s = document.getElementById('speed'); s.value = '30'; s.dispatchEvent(new Event('change')); __t.key(' '); true`);
  await sleep(1000);
  const played = await ev(`__t.key(' '); +document.getElementById('pos').textContent.split(' ')[1]`);
  cmp(played > 10 && played < 60, `play 1 s at 30 step/s reached step ${played}`);
  await ev(`document.getElementById('x-tick').click(); __t.pos(40); true`);
  cmp((await ev(`document.querySelectorAll('#ov rect').length`)) === N0, "tick mode bars");
  await ev(`document.getElementById('x-cyc').click(); true`);

  // layout and themes
  const views = [["wide-light", 1300, "light"], ["wide-dark", 1300, "dark"], ["w400-light", 400, "light"], ["w400-dark", 400, "dark"]];
  for (const [name, w, theme] of views) {
    await send("Emulation.setDeviceMetricsOverride", { width: w, height: 900, deviceScaleFactor: 1, mobile: w < 600 });
    await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: theme }] });
    for (const [k, p] of [[0, 20], [3, 60], [2, 100]]) {
      await ev(`__t.scene(${k}); __t.pos(${p}); true`);
      await sleep(150);
      const o = await ev(`({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth, bg: getComputedStyle(document.body).backgroundColor, fg: getComputedStyle(document.body).color })`);
      cmp(o.sw <= o.cw, `${name} scene ${k} horizontal overflow ${o.sw} > ${o.cw}`);
      const shot = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
      writeFileSync(path.join(shots, `${name}-s${k}.png`), Buffer.from(shot.result.data, "base64"));
      console.log(`screenshot ${name} scene ${k}: body bg ${o.bg} fg ${o.fg}`);
    }
  }
  cmp(errors.length === 0, "page errors: " + errors.join(" | "));
  console.log(`RENDER+STATIC checks ${checks} mismatches ${bad}`);
  ws.close();
}

main().catch((e) => { console.log("ERROR " + e.stack); bad++; }).finally(async () => {
  chrome.kill("SIGTERM");
  await sleep(500);
  try { rmSync(profile, { recursive: true, force: true }); } catch (e) { /* best effort */ }
  process.exit(bad ? 1 : 0);
});
