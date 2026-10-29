// Stage 4 acceptance (SPEC 7.4, prompt of stage 4 in SPEC 12): a fake camera publishes for --minutes;
// the DVR playlist then holds 590–600 one-second segments and the oldest file is gone; a segment decodes
// as 1080p H.264; FFmpeg killed with SIGKILL is writing again within 5 s behind a discontinuity while
// live goes on; no token → 401, another table's token → 403; an expired license blocks the table.
// node acceptance/stage4.ts --key K --other-key K2 [--minutes 11] [--ffmpeg-container media-server]
//   [--license-wait 660] [--backend URL] [--media ws://host:3000/ws]
import { execFile } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { adminSession, claimsOf, setPaidUntil } from "../bots/admin.ts";
import { toolArgs } from "../bots/args.ts";
import { club } from "../bots/backend.ts";
import { BotFarm, type BotState } from "../bots/farm.ts";

const run = promisify(execFile);
const args = toolArgs({
  "other-key": { type: "string", default: process.env.OTHER_CLUB_KEY ?? "" },
  minutes: { type: "string", default: "11" },
  segments: { type: "string", default: "600" },
  "ffmpeg-container": { type: "string", default: "" },
  "license-wait": { type: "string", default: "660" },
  "admin-email": { type: "string", default: process.env.ADMIN_EMAIL ?? "" },
  "admin-password": { type: "string", default: process.env.ADMIN_PASSWORD ?? "" },
});
const backendUrl = args.backend as string;
const httpBase = (args.media as string).replace(/^ws/, "http").replace(/\/ws$/, "");
const minutes = Number(args.minutes);
const capacity = Number(args.segments);

const results: { check: string; ok: boolean; detail: string }[] = [];
const check = (name: string, ok: boolean, detail: string): void => {
  results.push({ check: name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}: ${detail}`);
};
const note = (text: string): void => {
  console.log(`      ${text}`);
};
const describe = (s: BotState): string =>
  `${s.codec ?? "?"} ${String(s.width)}x${String(s.height)} ${String(s.fps)} fps, ${String(s.frames)} frames${s.error ? `, error ${s.error}` : ""}`;
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

interface Entry {
  uri: string;
  run: number;
  duration: number;
  pdt: number;
}

function parse(text: string): { mediaSequence: number; entries: Entry[]; discontinuities: number } {
  let duration = 0;
  let pdt = 0;
  const entries: Entry[] = [];
  for (const line of text.split("\n")) {
    if (line.startsWith("#EXTINF:")) duration = Number.parseFloat(line.slice(8));
    else if (line.startsWith("#EXT-X-PROGRAM-DATE-TIME:")) pdt = Date.parse(line.slice(25));
    else if (line && !line.startsWith("#")) entries.push({ uri: line, run: Number(/^r(\d+)\//.exec(line)?.[1]), duration, pdt });
  }
  return {
    mediaSequence: Number(/#EXT-X-MEDIA-SEQUENCE:(\d+)/.exec(text)?.[1] ?? -1),
    entries,
    discontinuities: (text.match(/^#EXT-X-DISCONTINUITY$/gm) ?? []).length,
  };
}

const dvrGet = (path: string, jwt?: string): Promise<Response> =>
  fetch(`${httpBase}${path}`, jwt ? { headers: { Authorization: `Bearer ${jwt}` } } : {});

/** SIGKILL every FFmpeg the DVR runs: in the compose container, or on this machine (media-server run on the host). */
async function killFfmpeg(): Promise<void> {
  const container = args["ffmpeg-container"] as string;
  if (container) {
    const script = `for (const p of require("fs").readdirSync("/proc")) { try { if (require("fs").readFileSync("/proc/" + p + "/comm", "utf8").trim() === "ffmpeg") process.kill(Number(p), "SIGKILL"); } catch {} }`;
    await run("docker", ["compose", "exec", "-T", container, "node", "-e", script]);
    return;
  }
  for (const pid of readdirSync("/proc").filter((p) => /^\d+$/.test(p))) {
    try {
      if (readFileSync(`/proc/${pid}/cmdline`, "utf8").includes("input.sdp")) process.kill(Number(pid), "SIGKILL");
    } catch {
      // gone already
    }
  }
}

/** Codec and size of a segment as a player would see it: init segment + media segment through ffprobe. */
async function probe(tableId: string, jwt: string, entry: Entry): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "pokercam-probe-"));
  try {
    const init = Buffer.from(await (await dvrGet(`/dvr/${tableId}/r${String(entry.run)}/init.mp4`, jwt)).arrayBuffer());
    const media = Buffer.from(await (await dvrGet(`/dvr/${tableId}/${entry.uri}`, jwt)).arrayBuffer());
    const file = join(dir, "segment.mp4");
    await writeFile(file, Buffer.concat([init, media]));
    const { stdout } = await run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries", "stream=codec_name,width,height,nb_read_frames", "-of", "csv=p=0", file]);
    return stdout.trim();
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

const table = await club(backendUrl, args.key as string);
const otherKey = args["other-key"] as string;
const other = otherKey ? await club(backendUrl, otherKey) : undefined;
const farm = await BotFarm.start();
const base = { wsUrl: args.media as string, tableId: table.tableId };
const playlistPath = `/dvr/${table.tableId}/index.m3u8`;
try {
  const camera = await farm.launch("camera", { ...base, role: "camera", token: await table.cameraToken() });
  const published = await camera.waitFor((s) => s.frames > 30 || s.error !== null, 45_000);
  check("camera publishes", published.error === null && published.frames > 30, describe(published));
  const jwt = await table.viewerToken();
  const viewer = await farm.launch("viewer", { ...base, role: "viewer", token: jwt });

  const informed = await viewer.waitFor((s) => s.dvr !== null || s.error !== null, 20_000).catch(() => viewer.state());
  check(
    "the viewer gets dvr.info",
    informed.dvr?.url === playlistPath && informed.dvr.to > informed.dvr.from,
    JSON.stringify(informed.dvr),
  );

  const noToken = await dvrGet(playlistPath);
  const otherTable = other ? await dvrGet(playlistPath, await other.viewerToken()) : undefined;
  check(
    "the playlist without a token → 401, with another table's token → 403",
    noToken.status === 401 && (otherTable === undefined || otherTable.status === 403),
    `${String(noToken.status)}, ${otherTable ? String(otherTable.status) : "no --other-key"}`,
  );

  const first = parse(await (await dvrGet(playlistPath, jwt)).text());
  const oldest = first.entries[0];
  const startedAt = Date.now();
  note(`recording ${String(minutes)} min; first segment ${oldest?.uri ?? "none"}`);
  while (Date.now() - startedAt < minutes * 60_000) {
    await sleep(Math.min(60_000, minutes * 60_000 - (Date.now() - startedAt)));
    const now = parse(await (await dvrGet(playlistPath, jwt)).text());
    note(`${((Date.now() - startedAt) / 60_000).toFixed(1)} min: ${String(now.entries.length)} segments, media sequence ${String(now.mediaSequence)}`);
  }

  const full = parse(await (await dvrGet(playlistPath, jwt)).text());
  const durations = full.entries.map((e) => e.duration);
  const average = durations.reduce((a, b) => a + b, 0) / Math.max(1, durations.length);
  const last = full.entries.at(-1);
  check(
    `after ${String(minutes)} min the playlist has ${String(capacity - 10)}–${String(capacity)} segments`,
    full.entries.length >= capacity - 10 && full.entries.length <= capacity,
    `${String(full.entries.length)} segments, ${average.toFixed(3)} s on average, longest ${Math.max(...durations).toFixed(3)} s, media sequence ${String(full.mediaSequence)}`,
  );
  const gone = oldest ? await dvrGet(`/dvr/${table.tableId}/${oldest.uri}`, jwt) : undefined;
  check("the oldest segment is deleted", gone?.status === 404, `${oldest?.uri ?? "none"} → ${String(gone?.status)}`);
  if (last) note(`live edge of the DVR: ${((Date.now() - last.pdt - last.duration * 1000) / 1000).toFixed(1)} s behind now`);

  const probed = last ? await probe(table.tableId, jwt, last).catch((e: unknown) => String(e)) : "no segment";
  check("a segment decodes as 1920x1080 H.264", /^h264,1920,1080,\d+/.test(probed), probed);

  const before = parse(await (await dvrGet(playlistPath, jwt)).text());
  const lastRun = Math.max(...before.entries.map((e) => e.run));
  const framesBefore = (await viewer.state()).frames;
  const killedAt = Date.now();
  await killFfmpeg();
  let after = before;
  while (Date.now() - killedAt < 15_000 && !after.entries.some((e) => e.run > lastRun)) {
    await sleep(250);
    after = parse(await (await dvrGet(playlistPath, jwt)).text());
  }
  const resumed = Date.now() - killedAt;
  check(
    "FFmpeg killed → recording again within 5 s, behind a discontinuity",
    after.entries.some((e) => e.run > lastRun) && resumed <= 5000 && after.discontinuities > before.discontinuities,
    `${String(resumed)} ms, discontinuities ${String(before.discontinuities)} → ${String(after.discontinuities)}`,
  );
  await sleep(2000);
  const live = await viewer.state();
  check("live goes on meanwhile", live.error === null && live.frames > framesBefore + 60, `${String(live.frames - framesBefore)} frames since the kill`);

  const email = args["admin-email"] as string;
  const password = args["admin-password"] as string;
  if (email && password) {
    const wait = Number(args["license-wait"]);
    const session = await adminSession(backendUrl, email, password);
    const expiredDay = new Date(Date.now() - 5 * 86_400_000);
    await setPaidUntil(backendUrl, session, String(claimsOf(jwt).client_id), expiredDay);
    const expiredAt = Date.now();
    const blocked = await viewer.waitFor((s) => s.license === "blocked", wait * 1000).catch(() => viewer.state());
    check(
      `an expired license blocks the table within ${String(wait)} s`,
      blocked.license === "blocked" && blocked.stream === "offline",
      `license ${String(blocked.license)}, stream ${String(blocked.stream)} after ${String(Math.round((Date.now() - expiredAt) / 1000))} s`,
    );
    const denied = await dvrGet(playlistPath, jwt);
    const code = ((await denied.json().catch(() => ({}))) as { detail?: { code?: string } }).detail?.code;
    check("…and its DVR → 403 license_blocked", denied.status === 403 && code === "license_blocked", `${String(denied.status)} ${String(code)}`);
  } else {
    note("no --admin-email/--admin-password: the license check is skipped");
  }
} finally {
  await farm.close();
}

const failed = results.filter((r) => !r.ok);
console.log(JSON.stringify({ table_id: table.tableId, minutes, passed: failed.length === 0, results }, null, 2));
process.exit(failed.length === 0 ? 0 : 1);
