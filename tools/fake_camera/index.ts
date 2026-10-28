// A fake phone over a table: pairs itself through the backend and publishes 1080p30 to media-server.
// Pairing replaces the table's phone, as a real one would: use a test club, not a live table.
// node fake_camera/index.ts --key XXXX-XXXX-XXXX-XXXX [--backend URL] [--media ws://host:3000/ws] [--table 1]
import { toolArgs } from "../bots/args.ts";
import { club } from "../bots/backend.ts";
import { BotFarm } from "../bots/farm.ts";

const args = toolArgs();
const table = await club(args.backend as string, args.key as string, Number(args.table));
const farm = await BotFarm.start();
const camera = await farm.launch("camera", {
  wsUrl: args.media as string,
  token: await table.cameraToken(),
  tableId: table.tableId,
  role: "camera",
});
console.log(`fake camera on table ${table.tableId}; Ctrl+C to stop`);
const timer = setInterval(() => {
  void camera.state().then((s) => {
    console.log(JSON.stringify({ error: s.error, codec: s.codec, size: `${String(s.width)}x${String(s.height)}`, fps: s.fps, frames: s.frames, license: s.license }));
  });
}, 5000);
process.once("SIGINT", () => {
  clearInterval(timer);
  void farm.close().then(() => process.exit(0));
});
