// Stage 3 acceptance (SPEC 12): a fake camera publishes; as many fake viewers as the table allows
// get its stream; one more gets room_full; camera.set reaches the camera and its ack comes back.
// node acceptance/stage3.ts --key XXXX-XXXX-XXXX-XXXX --viewers 5 [--backend URL] [--media ws://host:3000/ws]
import { toolArgs } from "../bots/args.ts";
import { club } from "../bots/backend.ts";
import { BotFarm, type Bot, type BotState } from "../bots/farm.ts";

const args = toolArgs({ viewers: { type: "string", default: "5" } });
const viewerCount = Number(args.viewers);
const results: { check: string; ok: boolean; detail: string }[] = [];
const check = (name: string, ok: boolean, detail: string): void => {
  results.push({ check: name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}: ${detail}`);
};
const describe = (s: BotState): string =>
  `${s.codec ?? "?"} ${String(s.width)}x${String(s.height)} ${String(s.fps)} fps, ${String(s.frames)} frames${s.error ? `, error ${s.error}` : ""}`;

const table = await club(args.backend as string, args.key as string, Number(args.table));
const farm = await BotFarm.start();
const base = { wsUrl: args.media as string, tableId: table.tableId };
try {
  const camera = await farm.launch("camera", { ...base, role: "camera", token: await table.cameraToken() });
  const published = await camera.waitFor((s) => s.frames > 30 || s.error !== null, 45_000);
  check("camera publishes", published.error === null && published.frames > 30, describe(published));

  const viewers: Bot[] = [];
  for (let i = 1; i <= viewerCount; i++) {
    viewers.push(await farm.launch(`viewer-${String(i)}`, { ...base, role: "viewer", token: await table.viewerToken() }));
  }
  for (const viewer of viewers) {
    const s = await viewer.waitFor((st) => st.frames >= 60 || st.error !== null, 60_000).catch(() => viewer.state());
    check(`${viewer.name} receives the stream`, s.error === null && s.frames >= 60, describe(s));
  }

  const extra = await farm.launch("viewer-extra", { ...base, role: "viewer", token: await table.viewerToken() });
  const refused = await extra.waitFor((s) => s.error !== null || s.joined, 15_000);
  check(`viewer ${String(viewerCount + 1)} is refused`, refused.error === "room_full", `error ${String(refused.error)}`);

  const first = viewers[0];
  if (first) {
    const requestId = await first.cameraSet("zoom", 2);
    const acked = await first.waitFor((s) => s.acks.some((a) => a.request_id === requestId), 10_000).catch(() => first.state());
    const reached = (await camera.state()).cameraSets;
    check("camera.set reaches the camera, camera.ack comes back", acked.acks.some((a) => a.request_id === requestId && a.ok) && reached > 0, `camera got ${String(reached)}, viewer got ${String(acked.acks.length)} acks`);
  }

  // Sampled last: the encoder starts lower and climbs to the full size as the bandwidth estimate grows.
  const sending = await camera.state();
  check("the camera sends 1080p30", sending.width === 1920 && sending.height === 1080 && sending.fps >= 25, describe(sending));
} finally {
  await farm.close();
}

const failed = results.filter((r) => !r.ok);
console.log(JSON.stringify({ table_id: table.tableId, viewers: viewerCount, passed: failed.length === 0, results }, null, 2));
process.exit(failed.length === 0 ? 0 : 1);
