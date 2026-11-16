// Headless check of the viewer's state engine (the <script id="engine"> block
// of ntt_player.html, run unchanged). For every run and every position, in
// sequential and in shuffled (scrub) order, stateAt / writtenAt are hashed and
// compared with the hashes from the independent Python replay.
// usage: node check_engine.mjs ntt_player.html check_expected.json
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import vm from "node:vm";

const [htmlPath, expPath] = process.argv.slice(2);
const html = readFileSync(htmlPath, "utf8");
const exp = JSON.parse(readFileSync(expPath, "utf8"));
const data = html.match(/<script type="application\/json" id="trace-data">([\s\S]*?)<\/script>/)[1];
const engine = html.match(/<script id="engine">([\s\S]*?)<\/script>/)[1];
const ui = html.match(/<script id="ui">([\s\S]*?)<\/script>/)[1];

// The UI script must at least parse.
new vm.Script(ui, { filename: "ui.js" });

const ctx = { globalThis: null };
ctx.globalThis = ctx;
vm.createContext(ctx);
vm.runInContext(engine, ctx, { filename: "engine.js" });
const E = ctx.NttEngine;
const D = JSON.parse(data);

const h = (u) => {
  const b = Buffer.alloc(u.length * 2);
  for (let i = 0; i < u.length; i++) b.writeUInt16LE(u[i], 2 * i);
  return createHash("sha256").update(b).digest("hex").slice(0, 16);
};

let checks = 0, bad = 0;
function cmp(ok, msg) {
  checks++;
  if (!ok) { bad++; if (bad < 20) console.log("FAIL " + msg); }
}
// deterministic shuffle (LCG), no Math.random
function shuffled(n, seed) {
  const a = Array.from({ length: n }, (_, i) => i);
  let s = seed >>> 0;
  for (let i = n - 1; i > 0; i--) {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    const j = s % (i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

for (const key of Object.keys(exp)) {
  const [inp, op, algo] = key.split("/");
  const run = E.makeRun(D, op, algo, inp);
  const want = exp[key];
  cmp(want.state.length === run.N + 1, `${key} N = ${run.N}, expected ${want.state.length - 1}`);
  for (const pos of [...Array(run.N + 1).keys(), ...shuffled(run.N + 1, 12345)]) {
    const st = E.stateAt(run, pos);
    cmp(h(st) === want.state[pos], `${key} pos ${pos} bank state`);
    const wm = E.writtenAt(run, pos);
    const w16 = new Uint16Array(512);
    for (let i = 0; i < 512; i++) w16[i] = wm[i];
    cmp(h(w16) === want.written[pos], `${key} pos ${pos} written mask`);
  }
  // boundaries: 0, group starts, N
  const bs = E.boundaries(run);
  cmp(bs[0] === 0 && bs[bs.length - 1] === run.N && bs.length === run.nGroups + 1, `${key} boundaries`);
}
console.log(`ENGINE runs ${Object.keys(exp).length}`);
console.log(`ENGINE checks ${checks} mismatches ${bad}`);
process.exit(bad ? 1 : 0);
