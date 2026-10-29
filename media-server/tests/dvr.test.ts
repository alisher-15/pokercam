// The DVR with a real FFmpeg (SPEC 7.2, 7.4): another FFmpeg plays the phone, sending H.264 RTP with a
// keyframe every second into a PlainTransport producer; media-server records it and serves HLS.
import { spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { join } from "node:path";
import type { types } from "mediasoup";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import type { Room } from "../src/rooms/room.js";
import { Client, startMediaServer, token } from "./support.js";

type Server = Awaited<ReturnType<typeof startMediaServer>>;
let server: Server;
const senders: ChildProcess[] = [];
const clients: Client[] = [];

beforeAll(async () => {
  server = await startMediaServer({ dvrEnabled: true, dvrSegments: 10 });
});

afterAll(async () => {
  for (const sender of senders) sender.kill("SIGKILL");
  for (const client of clients) client.close();
  await server.stop();
});

async function viewer(table: string): Promise<Client> {
  const client = await Client.connect(server.wsUrl, table);
  clients.push(client);
  expect((await client.join(viewerToken(table))).type).toBe("signaling.join.result");
  return client;
}

const viewerToken = (table: string): string => token({ role: "viewer", sub: randomUUID(), table_id: table });

/** A fake phone: FFmpeg's test pattern as H.264 RTP (SPS/PPS in band, like WebRTC) into a new producer. */
async function publish(room: Room): Promise<types.Producer> {
  const transport = await room.router.createPlainTransport({ listenInfo: { protocol: "udp", ip: "127.0.0.1" }, rtcpMux: false, comedia: true });
  const ssrc = 1000 + Math.floor(Math.random() * 100_000);
  const producer = await transport.produce({
    kind: "video",
    rtpParameters: {
      codecs: [{ mimeType: "video/H264", clockRate: 90000, payloadType: 102, parameters: { "packetization-mode": 1, "profile-level-id": "42e01f" } }],
      encodings: [{ ssrc }],
    },
  });
  const sender = spawn("ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-re",
    "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
    "-c:v", "libx264", "-profile:v", "baseline", "-pix_fmt", "yuv420p", "-tune", "zerolatency", "-g", "30",
    "-bsf:v", "dump_extra=freq=keyframe",
    "-f", "rtp", "-payload_type", "102", "-ssrc", String(ssrc),
    `rtp://127.0.0.1:${String(transport.tuple.localPort)}?rtcpport=${String(transport.rtcpTuple?.localPort)}&pkt_size=1200`,
  ], { stdio: "ignore" });
  senders.push(sender);
  producer.observer.once("close", () => sender.kill("SIGKILL"));
  room.setProducer(producer);
  return producer;
}

/** Polls until `get` returns something truthy, and returns it. */
async function until<T>(what: string, get: () => T | undefined | false | 0, timeoutMs: number): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = get();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

const get = (path: string, jwt?: string): Promise<Response> =>
  fetch(`${server.httpUrl}${path}`, jwt ? { headers: { Authorization: `Bearer ${jwt}` } } : {});

describe("recording", () => {
  const table = randomUUID();
  let room: Room;
  let jwt: string;

  beforeAll(async () => {
    await viewer(table);
    room = server.rooms.find(table) as Room;
    jwt = viewerToken(table);
    await publish(room);
  });

  test("1 s segments in a playlist served to the table's viewers", async () => {
    const dvr = await until("3 segments", () => (server.dvr?.table(table)?.index.size ?? 0) >= 3 && server.dvr?.table(table), 15_000);
    const response = await get(`/dvr/${table}/index.m3u8`, jwt);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/vnd.apple.mpegurl");
    const playlist = await response.text();
    expect(playlist).toMatch(/^#EXTM3U\n/);
    expect(playlist).toContain('#EXT-X-MAP:URI="r1/init.mp4"');
    const durations = [...playlist.matchAll(/#EXTINF:([\d.]+),/g)].map((m) => Number(m[1]));
    for (const d of durations.slice(1)) expect(d).toBeCloseTo(1, 1);

    const first = dvr.index.first;
    if (!first) throw new Error("no segment");
    const segment = await get(`/dvr/${table}/r1/${first.uri}`, jwt);
    expect(segment.status).toBe(200);
    expect(segment.headers.get("content-type")).toBe("video/iso.segment");
    expect((await segment.arrayBuffer()).byteLength).toBeGreaterThan(1000);
    expect((await get(`/dvr/${table}/r1/init.mp4`, jwt)).status).toBe(200);
  }, 20_000);

  test("program date-times follow the wall clock: a new segment ends about now", async () => {
    const dvr = server.dvr?.table(table);
    if (!dvr) throw new Error("no DVR");
    // After the run's clock correction has its samples, catch the moment a segment appears.
    await until("15 segments", () => (dvr.index.last?.mediaSequence ?? 0) >= 15, 20_000);
    const seen = dvr.index.last?.mediaSequence;
    await until("the next segment", () => dvr.index.last?.mediaSequence !== seen, 3000);
    const end = dvr.index.range()?.to ?? 0;
    expect(Date.now() - end).toBeGreaterThan(-300);
    expect(Date.now() - end).toBeLessThan(600);
  }, 25_000);

  test("a viewer joining later gets dvr.info with the buffer's bounds", async () => {
    const late = await viewer(table);
    const info = await late.next("dvr.info");
    expect(info.payload.playlist_url).toBe(`/dvr/${table}/index.m3u8`);
    expect(info.payload.available_to).toBeGreaterThan(info.payload.available_from);
    expect(Math.abs(info.payload.available_to - Date.now())).toBeLessThan(5000);
  });

  test("the window keeps the last N segments and deletes older files", async () => {
    const dvr = await until("a full window", () => server.dvr?.table(table)?.index.first?.mediaSequence && server.dvr.table(table), 20_000);
    expect(dvr.index.size).toBe(10);
    expect(existsSync(join(dvr.dir, "r1", "0.m4s"))).toBe(false);
    expect((await get(`/dvr/${table}/r1/0.m4s`, jwt)).status).toBe(404);
  }, 25_000);

  test("killed FFmpeg: recording resumes within 5 s after a discontinuity", async () => {
    const dvr = server.dvr?.table(table);
    const pid = dvr?.ffmpegPid;
    if (!dvr || pid === undefined) throw new Error("FFmpeg is not running");
    const killedAt = Date.now();
    process.kill(pid, "SIGKILL");
    await until("a segment of the next run", () => dvr.index.last && dvr.index.last.run > 1, 10_000);
    expect(Date.now() - killedAt).toBeLessThan(5000);
    const playlist = await (await get(`/dvr/${table}/index.m3u8`, jwt)).text();
    expect(playlist).toContain("#EXT-X-DISCONTINUITY\n");
    expect(playlist).toContain('#EXT-X-MAP:URI="r2/init.mp4"');
  }, 15_000);

  test("a new camera starts a new run; when it leaves, the buffer stays", async () => {
    const dvr = server.dvr?.table(table);
    if (!dvr) throw new Error("no DVR");
    const before = dvr.index.last?.run ?? 0;
    const producer = await publish(room);
    await until("a segment of the new camera", () => (dvr.index.last?.run ?? 0) > before, 10_000);
    producer.close();
    await until("recording to stop", () => !dvr.recordingActive, 5000);
    expect(dvr.ffmpegPid).toBeUndefined();
    const size = dvr.index.size;
    expect(size).toBeGreaterThan(0);
    expect((await get(`/dvr/${table}/index.m3u8`, jwt)).status).toBe(200);
  }, 20_000);
});

describe("access (SPEC 7.4: someone else's table or no token → 401/403)", () => {
  const table = randomUUID();

  beforeAll(async () => {
    await viewer(table);
    await publish(server.rooms.find(table) as Room);
    await until("a segment", () => (server.dvr?.table(table)?.index.size ?? 0) > 0, 15_000);
  }, 20_000);

  test("no token or a bad one: 401", async () => {
    expect((await get(`/dvr/${table}/index.m3u8`)).status).toBe(401);
    expect((await get(`/dvr/${table}/index.m3u8`, "not-a-jwt")).status).toBe(401);
  });

  test("another table's viewer or a camera: 403", async () => {
    const other = await get(`/dvr/${table}/index.m3u8`, viewerToken(randomUUID()));
    expect(other.status).toBe(403);
    expect(((await other.json()) as { detail: { code: string } }).detail.code).toBe("forbidden");
    expect((await get(`/dvr/${table}/index.m3u8`, token({ role: "camera", sub: randomUUID(), table_id: table }))).status).toBe(403);
  });

  test("paths outside the window or the layout: 404", async () => {
    const jwt = viewerToken(table);
    expect((await get(`/dvr/${table}/r99/init.mp4`, jwt)).status).toBe(404);
    expect((await get(`/dvr/${table}/r1/../../input.sdp`, jwt)).status).toBe(404);
    expect((await get(`/dvr/${table}/input.sdp`, jwt)).status).toBe(404);
  });

  test("a blocked license: 403 license_blocked, and the stream stops", async () => {
    server.backend.licenses.set(table, { status: "expired" });
    await server.rooms.find(table)?.checkLicense();
    const response = await get(`/dvr/${table}/index.m3u8`, viewerToken(table));
    expect(response.status).toBe(403);
    expect(((await response.json()) as { detail: { code: string } }).detail.code).toBe("license_blocked");
    await until("recording to stop", () => server.dvr?.table(table)?.recordingActive === false, 5000);
  });
});
