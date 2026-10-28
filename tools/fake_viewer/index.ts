// Fake Windows viewers: one bot PC activated with the club key opens --count connections to a table.
// node fake_viewer/index.ts --key XXXX-XXXX-XXXX-XXXX --count 5 [--backend URL] [--media ws://host:3000/ws] [--table 1]
import { toolArgs } from "../bots/args.ts";
import { club } from "../bots/backend.ts";
import { BotFarm, type Bot } from "../bots/farm.ts";

const args = toolArgs({ count: { type: "string", default: "1" } });
const table = await club(args.backend as string, args.key as string, Number(args.table));
const farm = await BotFarm.start();
const viewers: Bot[] = [];
for (let i = 1; i <= Number(args.count); i++) {
  viewers.push(
    await farm.launch(`viewer-${String(i)}`, {
      wsUrl: args.media as string,
      token: await table.viewerToken(),
      tableId: table.tableId,
      role: "viewer",
    }),
  );
}
console.log(`${String(viewers.length)} fake viewers on table ${table.tableId}; Ctrl+C to stop`);
const timer = setInterval(() => {
  void Promise.all(viewers.map((v) => v.state())).then((states) => {
    for (const [i, s] of states.entries()) {
      console.log(JSON.stringify({ viewer: i + 1, error: s.error, codec: s.codec, size: `${String(s.width)}x${String(s.height)}`, fps: s.fps, frames: s.frames, stream: s.stream }));
    }
  });
}, 5000);
process.once("SIGINT", () => {
  clearInterval(timer);
  void farm.close().then(() => process.exit(0));
});
