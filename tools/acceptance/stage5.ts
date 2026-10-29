// Stage 5 acceptance (SPEC 6.5) on an Android emulator, with apps/camera_android/integration_test/e2e_test.dart
// running on it. This side plays the club's PC: hands the app a pairing code (GET /pairing), watches the
// stream with a bot viewer, changes every camera setting, cuts the phone's network for 30 s and heats it
// (adb), then pairs another camera to the table; GET /done tells the app the checks are over.
// node acceptance/stage5.ts --key K --phone-api http://HOST_IP:8000 [--port 8765] [--adb adb]
//   [--backend http://localhost:8000] [--media ws://localhost:3000/ws]
import { execFile } from "node:child_process";
import { once } from "node:events";
import { createServer } from "node:http";
import { promisify } from "node:util";
import { toolArgs } from "../bots/args.ts";
import { Backend, club } from "../bots/backend.ts";
import { BotFarm, type Bot, type BotState } from "../bots/farm.ts";

const run = promisify(execFile);
const args = toolArgs({
  "phone-api": { type: "string", default: "" },
  port: { type: "string", default: "8765" },
  adb: { type: "string", default: "adb" },
  "wait-pairing": { type: "string", default: "900" },
});
const results: { check: string; ok: boolean; detail: string }[] = [];
const check = (name: string, ok: boolean, detail: string): void => {
  results.push({ check: name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}: ${detail}`);
};
const note = (text: string): void => {
  console.log(`      ${text}`);
};
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const adb = async (...command: string[]): Promise<string> => (await run(args.adb as string, ["shell", ...command])).stdout.trim();

async function until(bot: Bot, done: (s: BotState) => boolean, timeoutMs: number): Promise<{ state: BotState; ms: number }> {
  const start = Date.now();
  const state = await bot.waitFor(done, timeoutMs).catch(() => bot.state());
  return { state, ms: Date.now() - start };
}

const backendUrl = args.backend as string;
const phoneApi = (args["phone-api"] as string) || backendUrl;
const table = await club(backendUrl, args.key as string);
const backend = new Backend(backendUrl);

// The PC's half of pairing, on the app's request, and the end signal.
let pairingRequestedAt = 0;
let finished: { done: boolean; expect?: string } = { done: false };
const server = createServer((req, res) => {
  const reply = (body: unknown) => res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(body));
  if (req.url === "/pairing") {
    pairingRequestedAt = Date.now();
    void (async () => {
      const pc = await backend.activate(args.key as string, "e2e-pc");
      const code = await backend.pairingCode(await backend.token(pc.refresh_token), table.tableId);
      reply({ api: phoneApi, code: code.code });
    })().catch((error: unknown) => res.writeHead(500).end(String(error)));
  } else if (req.url === "/done") {
    reply(finished);
  } else {
    res.writeHead(404).end();
  }
});
server.listen(Number(args.port), "0.0.0.0");
await once(server, "listening");
note(`harness on :${String(args.port)}; the app pairs with ${phoneApi}`);

const farm = await BotFarm.start();
const base = { wsUrl: args.media as string, tableId: table.tableId };
try {
  const viewer = await farm.launch("pc", { ...base, role: "viewer", token: await table.viewerToken() });
  const waitPairing = Number(args["wait-pairing"]) * 1000;
  for (const end = Date.now() + waitPairing; pairingRequestedAt === 0 && Date.now() < end; ) await sleep(500);
  if (pairingRequestedAt === 0) throw new Error("the app never asked for a pairing code");

  // 1. Pairing and the first frames on the PC.
  const live = await until(viewer, (s) => s.frames > 10, 90_000);
  const pairingS = (Date.now() - pairingRequestedAt) / 1000;
  check("pairing by code → video on the PC in < 1 min", live.state.frames > 10 && pairingS < 60, `${pairingS.toFixed(1)} s, ${live.state.codec ?? "?"} ${String(live.state.width)}x${String(live.state.height)}`);
  if (live.state.frames <= 10) throw new Error("no video from the app: the other checks need it");

  // 2. Every setting the camera supports, from the PC; the rest refused honestly.
  const caps = (await until(viewer, (s) => s.capabilities !== null, 20_000)).state.capabilities ?? {};
  const supported = Object.entries(caps).filter(([, c]) => c.supported);
  const unsupported = Object.entries(caps).filter(([, c]) => !c.supported);
  note(`supported: ${supported.map(([p]) => p).join(", ") || "none"}; not: ${unsupported.map(([p]) => p).join(", ") || "none"}`);
  const timings: string[] = [];
  let allApplied = supported.length > 0;
  for (const [param, cap] of supported) {
    const value = cap.min !== undefined && cap.max !== undefined ? cap.min + (cap.max - cap.min) / 2 : 1;
    const control = cap.modes.includes("manual")
      ? { mode: "manual", value }
      : cap.modes.includes("preset")
        ? { mode: "preset", preset: "daylight" }
        : { mode: "auto" };
    const sentAt = Date.now();
    const id = await viewer.cameraSetControl(param, control);
    const acked = await until(viewer, (s) => s.acks.some((a) => a.request_id === id), 10_000);
    const ack = acked.state.acks.find((a) => a.request_id === id);
    const ms = ack ? ack.at - sentAt : -1;
    timings.push(`${param} ${ack?.ok ? `${String(ms)} ms` : `refused (${String(ack?.error)})`}`);
    if (!ack?.ok || ms > 2500) allApplied = false;
    // Back to automatic, so the next setting starts from the camera's own (brightness needs auto ISO and exposure).
    if (cap.modes.includes("auto")) {
      const reset = await viewer.cameraSetControl(param, { mode: "auto" });
      await until(viewer, (s) => s.acks.some((a) => a.request_id === reset), 10_000);
    }
  }
  check("every supported setting changes from the PC, acknowledged once in the picture (emulator ≤ 2.5 s)", allApplied, timings.join(", "));
  const refusals: string[] = [];
  let allRefused = true;
  for (const [param] of unsupported) {
    const id = await viewer.cameraSetControl(param, { mode: "auto" });
    const ack = (await until(viewer, (s) => s.acks.some((a) => a.request_id === id), 10_000)).state.acks.find((a) => a.request_id === id);
    refusals.push(`${param} ${String(ack?.error)}`);
    if (ack?.ok !== false || ack.error !== "unsupported_param") allRefused = false;
  }
  check("unsupported settings are marked and refused", allRefused, refusals.join(", ") || "none unsupported on this camera");

  // 3. 30 s without network (SPEC 6.5: back on its own ≤ 15 s after the network returns).
  const before = await viewer.state();
  await adb("cmd", "connectivity", "airplane-mode", "enable");
  note("airplane mode on");
  await sleep(30_000);
  await adb("cmd", "connectivity", "airplane-mode", "disable");
  const backAt = Date.now();
  const back = await until(viewer, (s) => s.producers > before.producers && s.lastFrameAt > backAt, 60_000);
  const backS = (Date.now() - backAt) / 1000;
  check("network off 30 s → the stream is back ≤ 15 s after it returns", back.state.lastFrameAt > backAt && backS <= 15, `${backS.toFixed(1)} s`);

  // 4. Heat (SPEC 6.5: emulated thermal status).
  const alertsBefore = (await viewer.state()).alerts.length;
  await adb("cmd", "thermalservice", "override-status", "3");
  const hot = await until(viewer, (s) => s.alerts.slice(alertsBefore).some((a) => a.kind === "overheating" && a.level === "critical"), 30_000);
  check("SEVERE → bitrate down and a critical overheating alert on the PC", hot.state.alerts.slice(alertsBefore).some((a) => a.level === "critical"), `${(hot.ms / 1000).toFixed(1)} s`);
  await adb("cmd", "thermalservice", "override-status", "0");
  const coolFrom = (await viewer.state()).alerts.length;
  const cooled = await until(viewer, (s) => s.alerts.slice(coolFrom).some((a) => a.message_key === "alertCooledDown"), 200_000);
  check("cool for 2 min → bitrate back and an info alert", cooled.state.alerts.slice(coolFrom).some((a) => a.message_key === "alertCooledDown"), `${(cooled.ms / 1000).toFixed(0)} s`);
  await adb("cmd", "thermalservice", "reset").catch(() => "");

  // 5. Another phone takes the table: this one is dropped and the PC sees the new one.
  const producers = (await viewer.state()).producers;
  const replacement = await farm.launch("new-phone", { ...base, role: "camera", token: await table.cameraToken() });
  const switched = await until(viewer, (s) => s.producers > producers && s.frames > 0, 30_000);
  check("a new phone replaces this one; the PC switches to it", switched.state.producers > producers && (await replacement.state()).error === null, `${(switched.ms / 1000).toFixed(1)} s`);
  finished = { done: true, expect: "replaced" };
  await sleep(40_000); // the app checks it is back on pairing, then the test ends
} catch (error) {
  check("the run completed", false, String(error));
  finished = { done: true };
  await sleep(10_000);
} finally {
  await farm.close();
  server.close();
}

const failed = results.filter((r) => !r.ok);
console.log(JSON.stringify({ table_id: table.tableId, passed: failed.length === 0, results }, null, 2));
process.exit(failed.length === 0 ? 0 : 1);
