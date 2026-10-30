// Stage 6 acceptance (SPEC 12: the camera is controlled from the PC) with
// apps/viewer_windows/integration_test/e2e_test.dart running the real Windows app against the servers.
// This side plays the table's phone: a fake camera (Chromium) publishes 1080p30 and answers camera.set.
// GET /setup gives the app the server and the club's key, GET /camera what the camera got, POST /done the
// app's own findings; then the run ends.
// node acceptance/stage6.ts --key K [--port 8766] [--backend http://127.0.0.1:8000] [--media ws://127.0.0.1:3000/ws]
import { once } from "node:events";
import { createServer } from "node:http";
import { toolArgs } from "../bots/args.ts";
import { club } from "../bots/backend.ts";
import { BotFarm } from "../bots/farm.ts";

const { backend, media, key, port, wait } = toolArgs({
  port: { type: "string", default: "8766" },
  wait: { type: "string", default: "900" },
}) as Record<"backend" | "media" | "key" | "port" | "wait", string>;
const results: { check: string; ok: boolean; detail: string }[] = [];
const check = (name: string, ok: boolean, detail: string): void => {
  results.push({ check: name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}: ${detail}`);
};

const table = await club(backend, key);
const farm = await BotFarm.start();
const camera = await farm.launch("camera", { wsUrl: media, tableId: table.tableId, role: "camera", token: await table.cameraToken() });
await camera.waitFor((s) => s.frames > 10);
console.log("      the fake camera publishes; waiting for the app");

interface AppReport {
  checks?: { check: string; ok: boolean; detail: string }[];
}
const app: { report: AppReport | null } = { report: null };
const server = createServer((req, res) => {
  const reply = (body: unknown) => res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(body));
  if (req.url === "/setup") {
    reply({ api: backend, key });
  } else if (req.url === "/camera") {
    void camera.state().then((s) => {
      reply({ camera_sets: s.cameraSets, frames: s.frames, producer: s.producerId });
    });
  } else if (req.url === "/done" && req.method === "POST") {
    let body = "";
    req.on("data", (chunk: Buffer) => (body += chunk.toString()));
    req.on("end", () => {
      app.report = JSON.parse(body || "{}") as AppReport;
      reply({ ok: true });
    });
  } else {
    res.writeHead(404).end();
  }
});
server.listen(Number(port), "127.0.0.1");
await once(server, "listening");

const end = Date.now() + Number(wait) * 1000;
while (app.report === null && Date.now() < end) await new Promise((resolve) => setTimeout(resolve, 500));
const report = app.report;
if (report === null) check("the app finished", false, "no report from the app");
for (const c of report?.checks ?? []) check(c.check, c.ok, c.detail);
const state = await camera.state();
check("camera.set from the Windows app reached the camera, which answered", state.cameraSets > 0, `${String(state.cameraSets)} set(s)`);

await farm.close();
server.close();
const failed = results.filter((r) => !r.ok);
console.log(JSON.stringify({ table_id: table.tableId, passed: failed.length === 0, results }, null, 2));
process.exit(failed.length === 0 ? 0 : 1);
