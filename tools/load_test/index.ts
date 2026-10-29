// Load test (SPEC 7.4, 11.2): N tables, a fake camera and M fake viewers on each, for --duration; samples
// media-server's memory and CPU (its own process tree: Node, mediasoup workers, FFmpeg; the DVR's tmpfs is
// counted separately) and every bot's frames and losses. Passes with no packets lost on the server's side,
// no video freezes, every viewer decoding all along, and memory after the warm-up not growing past --max-growth.
// node load_test/index.ts --key K --tables 1 --viewers 1 --duration 60 [--sample 30] [--out DIR]
//   [--server-container pokercam-media-server-1 | --server-pid PID] [--dvr-dir DIR]
import { execFile } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import { toolArgs } from "../bots/args.ts";
import { clubTables } from "../bots/backend.ts";
import { BotFarm, type Bot, type BotState } from "../bots/farm.ts";

const run = promisify(execFile);
const args = toolArgs({
  tables: { type: "string", default: "1" },
  viewers: { type: "string", default: "1" },
  duration: { type: "string", default: "60" },
  sample: { type: "string", default: "30" },
  "warm-up": { type: "string", default: "" },
  "max-growth": { type: "string", default: "50" },
  out: { type: "string", default: `load_test/results/${new Date().toISOString().replace(/[:.]/g, "-")}` },
  "server-container": { type: "string", default: "" },
  "server-pid": { type: "string", default: "" },
  "dvr-dir": { type: "string", default: "/dvr" },
});
const tables = Number(args.tables);
const viewersPerTable = Number(args.viewers);
const durationMs = Number(args.duration) * 60_000;
const sampleMs = Number(args.sample) * 1000;
// Memory settles once the DVR window is full (10 min) and the first allocations are done.
const warmUpMs = args["warm-up"] ? Number(args["warm-up"]) * 60_000 : Math.min(durationMs / 4, 12 * 60_000);
const maxGrowthMb = Number(args["max-growth"]);

/**
 * Runs where media-server runs (in its container, or here for a host process) and prints the summed
 * RSS and CPU ticks of the server's processes, and the size of the files in the DVR directory.
 */
const SNAPSHOT = `
const fs = require("fs");
const root = Number(process.argv[1]) || 0;
const dvr = process.argv[2];
const stats = fs.readdirSync("/proc").filter((p) => /^\\d+$/.test(p)).flatMap((pid) => {
  try {
    const stat = fs.readFileSync("/proc/" + pid + "/stat", "utf8");
    const f = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    const rss = /VmRSS:\\s+(\\d+)/.exec(fs.readFileSync("/proc/" + pid + "/status", "utf8"));
    const comm = fs.readFileSync("/proc/" + pid + "/comm", "utf8").trim();
    const kind = comm === "ffmpeg" ? "ffmpeg" : comm.startsWith("mediasoup-work") ? "workers" : "node";
    return [{ pid: Number(pid), ppid: Number(f[1]), ticks: Number(f[11]) + Number(f[12]), rssKb: rss ? Number(rss[1]) : 0, kind }];
  } catch { return []; }
});
let mine = stats.filter((s) => s.pid !== process.pid);
if (root) {
  const tree = new Set([root]);
  for (let grew = true; grew; ) { grew = false; for (const s of stats) if (!tree.has(s.pid) && tree.has(s.ppid)) { tree.add(s.pid); grew = true; } }
  mine = stats.filter((s) => tree.has(s.pid));
}
let dvrBytes = 0;
const walk = (dir) => { for (const e of fs.readdirSync(dir, { withFileTypes: true })) { const p = dir + "/" + e.name; try { if (e.isDirectory()) walk(p); else dvrBytes += fs.statSync(p).size; } catch {} } };
try { walk(dvr); } catch {}
const dvrMb = dvrBytes / 1048576;
const byKind = (k) => mine.filter((s) => s.kind === k).reduce((a, s) => a + s.rssKb, 0);
console.log(JSON.stringify({ rssKb: mine.reduce((a, s) => a + s.rssKb, 0), nodeKb: byKind("node"), workersKb: byKind("workers"), ffmpegKb: byKind("ffmpeg"), ticks: mine.reduce((a, s) => a + s.ticks, 0), procs: mine.length, dvrMb }));
`;

interface Snapshot {
  rssKb: number;
  nodeKb: number;
  workersKb: number;
  ffmpegKb: number;
  ticks: number;
  procs: number;
  dvrMb: number;
}

async function snapshot(): Promise<Snapshot> {
  const container = args["server-container"] as string;
  const dvrDir = args["dvr-dir"] as string;
  const { stdout } = container
    ? await run("docker", ["exec", container, "node", "-e", SNAPSHOT, "0", dvrDir])
    : await run(process.execPath, ["-e", SNAPSHOT, args["server-pid"] as string, dvrDir]);
  return JSON.parse(stdout) as Snapshot;
}

interface Sample {
  minute: number;
  rssMb: number;
  /** The same split by process: media-server's Node, mediasoup workers, FFmpeg. */
  nodeMb: number;
  workersMb: number;
  ffmpegMb: number;
  cpuPercent: number;
  procs: number;
  dvrMb: number;
  /** Lowest decoded fps among viewers, and lowest sent fps among cameras: tells a server stall from a bot's. */
  minViewerFps: number;
  minCameraFps: number;
  /** Cameras whose encoder is held back (by CPU or bandwidth) in this sample. */
  camerasLimited: number;
  packetsLost: number;
  freezes: number;
  errors: number;
}

const tick = 100; // USER_HZ on Linux
const farm = await BotFarm.start();
const cameras: Bot[] = [];
const viewers: Bot[] = [];
const samples: Sample[] = [];
const out = args.out as string;
await mkdir(out, { recursive: true });
let failure: string | undefined;
try {
  const clubs = await clubTables(args.backend as string, args.key as string, Array.from({ length: tables }, (_, i) => i + 1));
  for (const [i, table] of clubs.entries()) {
    const base = { wsUrl: args.media as string, tableId: table.tableId };
    cameras.push(await farm.launch(`camera-${String(i + 1)}`, { ...base, role: "camera", token: await table.cameraToken() }));
    for (let v = 1; v <= viewersPerTable; v++) {
      viewers.push(await farm.launch(`viewer-${String(i + 1)}.${String(v)}`, { ...base, role: "viewer", token: await table.viewerToken() }));
    }
  }
  for (const viewer of viewers) await viewer.waitFor((s) => s.frames > 30 || s.error !== null, 60_000);
  console.log(`${String(tables)} tables × ${String(viewersPerTable)} viewers running for ${String(args.duration)} min; samples every ${String(args.sample)} s → ${out}`);

  const startedAt = Date.now();
  let previous = await snapshot();
  let previousAt = Date.now();
  while (Date.now() - startedAt < durationMs) {
    await new Promise((resolve) => setTimeout(resolve, sampleMs));
    const now = await snapshot();
    const at = Date.now();
    const states: BotState[] = await Promise.all([...cameras, ...viewers].map((b) => b.state()));
    const cameraStates = states.slice(0, cameras.length);
    const viewerStates = states.slice(cameras.length);
    const sample: Sample = {
      minute: Number(((at - startedAt) / 60_000).toFixed(2)),
      rssMb: Number((now.rssKb / 1024).toFixed(1)),
      nodeMb: Number((now.nodeKb / 1024).toFixed(1)),
      workersMb: Number((now.workersKb / 1024).toFixed(1)),
      ffmpegMb: Number((now.ffmpegKb / 1024).toFixed(1)),
      cpuPercent: Number((((now.ticks - previous.ticks) / tick / ((at - previousAt) / 1000)) * 100).toFixed(1)),
      procs: now.procs,
      dvrMb: Number(now.dvrMb.toFixed(1)),
      minViewerFps: Math.min(...viewerStates.map((s) => s.fps)),
      minCameraFps: Math.min(...cameraStates.map((s) => s.fps)),
      camerasLimited: cameraStates.filter((s) => s.qualityLimitation !== null && s.qualityLimitation !== "none").length,
      packetsLost: states.reduce((a, s) => a + Math.max(0, s.packetsLost), 0),
      freezes: viewerStates.reduce((a, s) => a + s.freezes, 0),
      errors: states.filter((s) => s.error !== null).length,
    };
    samples.push(sample);
    previous = now;
    previousAt = at;
    console.log(JSON.stringify(sample));
  }
} catch (error) {
  failure = String(error);
} finally {
  await farm.close();
}

// Verdict (SPEC 7.4: no lost frames on the server, no memory growth).
const settled = samples.filter((s) => s.minute * 60_000 >= warmUpMs);
const growth = settled.length > 1 ? (settled.at(-1)?.rssMb ?? 0) - (settled[0]?.rssMb ?? 0) : 0;
const last = samples.at(-1);
const checks = [
  { check: "the run completed", ok: failure === undefined && last !== undefined, detail: failure ?? `${String(samples.length)} samples` },
  { check: "no RTP packets lost", ok: last?.packetsLost === 0, detail: `${String(last?.packetsLost)} lost` },
  { check: "no video freezes", ok: last?.freezes === 0, detail: `${String(last?.freezes)} freezes` },
  { check: "every viewer decodes all along (≥ 25 fps in every sample)", ok: samples.every((s) => s.minViewerFps >= 25 && s.errors === 0), detail: `lowest ${String(Math.min(...samples.map((s) => s.minViewerFps)))} fps` },
  { check: `memory grows ≤ ${String(maxGrowthMb)} MB after the warm-up`, ok: settled.length > 1 && growth <= maxGrowthMb, detail: `${growth.toFixed(1)} MB over ${String(settled.length)} samples (RSS ${String(settled[0]?.rssMb)} → ${String(settled.at(-1)?.rssMb)} MB)` },
];
for (const c of checks) console.log(`${c.ok ? "PASS" : "FAIL"}  ${c.check}: ${c.detail}`);

const csv = [
  "minute,rss_mb,node_mb,workers_mb,ffmpeg_mb,cpu_percent,procs,dvr_mb,min_viewer_fps,min_camera_fps,cameras_limited,packets_lost,freezes,errors",
  ...samples.map((s) =>
    [s.minute, s.rssMb, s.nodeMb, s.workersMb, s.ffmpegMb, s.cpuPercent, s.procs, s.dvrMb, s.minViewerFps, s.minCameraFps, s.camerasLimited, s.packetsLost, s.freezes, s.errors].join(","),
  ),
];
await writeFile(join(out, "samples.csv"), `${csv.join("\n")}\n`);
await writeFile(join(out, "summary.json"), `${JSON.stringify({ tables, viewers_per_table: viewersPerTable, duration_min: Number(args.duration), checks, passed: checks.every((c) => c.ok) }, null, 2)}\n`);
await writeFile(join(out, "chart.svg"), chart(samples));
process.exit(checks.every((c) => c.ok) ? 0 : 1);

/** Memory (MB) and CPU (%) of media-server over the run, as a plain SVG. */
function chart(data: Sample[]): string {
  const w = 900;
  const h = 260;
  const pad = 40;
  const maxX = Math.max(1, ...data.map((s) => s.minute));
  const line = (values: number[], max: number, color: string) =>
    `<polyline fill="none" stroke="${color}" stroke-width="2" points="${data.map((s, i) => `${(pad + (s.minute / maxX) * (w - 2 * pad)).toFixed(1)},${(h - pad - ((values[i] ?? 0) / max) * (h - 2 * pad)).toFixed(1)}`).join(" ")}"/>`;
  const maxRss = Math.max(1, ...data.map((s) => s.rssMb)) * 1.2;
  const maxCpu = Math.max(1, ...data.map((s) => s.cpuPercent)) * 1.2;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${String(w)}" height="${String(h)}" font-family="sans-serif" font-size="12">
<rect width="100%" height="100%" fill="white"/>
<line x1="${String(pad)}" y1="${String(h - pad)}" x2="${String(w - pad)}" y2="${String(h - pad)}" stroke="#999"/>
${line(data.map((s) => s.rssMb), maxRss, "#1f6feb")}
${line(data.map((s) => s.cpuPercent), maxCpu, "#d1242f")}
<text x="${String(pad)}" y="20" fill="#1f6feb">RSS, MB (max ${maxRss.toFixed(0)})</text>
<text x="${String(pad + 220)}" y="20" fill="#d1242f">CPU, % (max ${maxCpu.toFixed(0)})</text>
<text x="${String(w - pad)}" y="${String(h - 10)}" text-anchor="end">${maxX.toFixed(0)} min</text>
</svg>
`;
}
