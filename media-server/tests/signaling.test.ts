import { randomUUID } from "node:crypto";
import * as mediasoup from "mediasoup";
import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { Client, INTERNAL_TOKEN, startMediaServer, token } from "./support.js";

type Server = Awaited<ReturnType<typeof startMediaServer>>;
let server: Server;
const clients: Client[] = [];

async function connect(table: string): Promise<Client> {
  const client = await Client.connect(server.wsUrl, table);
  clients.push(client);
  return client;
}

async function viewer(table: string): Promise<Client> {
  const client = await connect(table);
  const reply = await client.join(token({ role: "viewer", sub: randomUUID(), table_id: table }));
  expect(reply.type).toBe("signaling.join.result");
  return client;
}

async function camera(table: string, device = randomUUID()): Promise<Client> {
  server.backend.licenses.set(table, { ...server.backend.licenses.get(table), camera_device_id: device });
  const client = await connect(table);
  const reply = await client.join(token({ role: "camera", sub: device, table_id: table }));
  expect(reply.type).toBe("signaling.join.result");
  return client;
}

function errorCode(reply: { type: string; payload: unknown }): string | undefined {
  return reply.type === "signaling.error" ? (reply.payload as { code: string }).code : undefined;
}

beforeEach(async () => {
  server = await startMediaServer({ maxViewersPerTable: 2 });
});

afterEach(() => {
  for (const client of clients.splice(0)) {
    expect(client.invalid, "every message from the server matches contracts/").toEqual([]);
    client.close();
  }
  server.stop();
});

describe("join", () => {
  test("a viewer joins its table and learns the license and stream state", async () => {
    const table = randomUUID();
    const client = await viewer(table);
    expect((await client.next("license.status")).payload).toEqual({ status: "active" });
    expect((await client.next("stream.status")).payload.status).toBe("offline");
  });

  test("the token decides the table", async () => {
    const client = await connect(randomUUID());
    expect(errorCode(await client.join(token({ role: "viewer", sub: randomUUID(), table_id: randomUUID() })))).toBe("forbidden");
    expect(errorCode(await client.join(token({ role: "viewer", sub: randomUUID() })))).toBe("forbidden");
    expect(errorCode(await client.join("bad.token.here"))).toBe("unauthorized");
  });

  test("SPEC 7.1: a viewer over the limit gets room_full; a free seat can be taken again", async () => {
    const table = randomUUID();
    const first = await viewer(table);
    await viewer(table);
    const third = await connect(table);
    expect(errorCode(await third.join(token({ role: "viewer", sub: randomUUID(), table_id: table })))).toBe("room_full");
    first.close();
    await first.closed();
    await expect.poll(async () => (await third.join(token({ role: "viewer", sub: randomUUID(), table_id: table }))).type).toBe(
      "signaling.join.result",
    );
  });

  test("only the phone paired to the table may be its camera", async () => {
    const table = randomUUID();
    server.backend.licenses.set(table, { camera_device_id: randomUUID() });
    const replaced = await connect(table);
    expect(errorCode(await replaced.join(token({ role: "camera", sub: randomUUID(), table_id: table })))).toBe("forbidden");
  });

  test("a new camera replaces the old one", async () => {
    const table = randomUUID();
    const old = await camera(table);
    await camera(table);
    expect(await old.closed()).toBe(4001);
  });

  test("a blocked license keeps everyone out", async () => {
    const table = randomUUID();
    server.backend.licenses.set(table, { status: "expired" });
    const client = await connect(table);
    expect(errorCode(await client.join(token({ role: "viewer", sub: randomUUID(), table_id: table })))).toBe("license_blocked");
  });
});

describe("requests", () => {
  test("nothing before join", async () => {
    const client = await connect(randomUUID());
    expect(errorCode(await client.request("signaling.get_router_rtp_capabilities", {}))).toBe("unauthorized");
  });

  test("invalid messages get bad_request with their id", async () => {
    const client = await viewer(randomUUID());
    client.sendRaw("{");
    expect((await client.next("signaling.error", (m) => m.payload.request_id === "invalid")).payload.code).toBe("bad_request");
    client.sendRaw(JSON.stringify({ type: "camera.set", id: "x-1", ts: 1, table_id: client.tableId, payload: { param: "flash" } }));
    expect((await client.next("signaling.error", (m) => m.payload.request_id === "x-1")).payload.code).toBe("bad_request");
  });

  test("router capabilities offer H.264 and VP8", async () => {
    const client = await viewer(randomUUID());
    const reply = await client.request("signaling.get_router_rtp_capabilities", {});
    const codecs = (reply.payload as { rtp_capabilities: { codecs: { mimeType: string }[] } }).rtp_capabilities.codecs;
    expect(codecs.map((c) => c.mimeType)).toEqual(expect.arrayContaining(["video/H264", "video/VP8"]));
  });

  test("a viewer gets a receive transport on the announced address", async () => {
    const client = await viewer(randomUUID());
    const reply = await client.request("signaling.create_transport", { direction: "recv" });
    expect(reply.type).toBe("signaling.create_transport.result");
    const candidates = (reply.payload as { ice_candidates: { address: string; port: number; protocol: string }[] }).ice_candidates;
    expect(candidates.map((c) => c.protocol).sort()).toEqual(["tcp", "udp"]);
    for (const c of candidates) expect([c.address, c.port]).toEqual(["127.0.0.1", server.config.rtcPortMin]);
    const tcpOnly = await client.request("signaling.create_transport", { direction: "recv", force_tcp: true });
    const tcp = (tcpOnly.payload as { ice_candidates: { protocol: string }[] }).ice_candidates;
    expect(tcp.map((c) => c.protocol)).toEqual(["tcp"]);
  });

  test("viewers receive, cameras send", async () => {
    const table = randomUUID();
    const v = await viewer(table);
    expect(errorCode(await v.request("signaling.create_transport", { direction: "send" }))).toBe("forbidden");
    const c = await camera(table);
    expect(errorCode(await c.request("signaling.create_transport", { direction: "recv" }))).toBe("forbidden");
  });

  test("consuming before the camera publishes is not_found", async () => {
    const client = await viewer(randomUUID());
    const transport = await client.request("signaling.create_transport", { direction: "recv" });
    const reply = await client.request("signaling.consume", {
      transport_id: (transport.payload as { transport_id: string }).transport_id,
      rtp_capabilities: {},
    });
    expect(errorCode(reply)).toBe("not_found");
  });
});

describe("the camera's stream", () => {
  test("viewers are told to consume, consume, and are told when it ends", async () => {
    const table = randomUUID();
    const v = await viewer(table);
    const c = await camera(table);
    const room = server.rooms.find(table);
    if (!room) throw new Error("no room");
    // A producer made on the server stands in for the phone's WebRTC one: media itself is tested by tools/acceptance.
    const plain = await room.router.createPlainTransport({ listenInfo: { protocol: "udp", ip: "127.0.0.1" } });
    const producer = await plain.produce({
      kind: "video",
      rtpParameters: {
        codecs: [{ mimeType: "video/VP8", clockRate: 90000, payloadType: 101 }],
        encodings: [{ ssrc: 1111 }],
      },
    });
    room.setProducer(producer);

    expect((await v.next("signaling.new_producer")).payload.producer_id).toBe(producer.id);
    expect((await v.next("stream.status", (m) => m.payload.status === "live")).payload.status).toBe("live");
    // The camera hears the stream is live but is never asked to consume itself.
    await c.next("stream.status", (m) => m.payload.status === "live");
    expect(c.received.some((m) => m.type === "signaling.new_producer")).toBe(false);
    await expect.poll(() => server.backend.presence).toContainEqual([table, true]);

    const transport = await v.request("signaling.create_transport", { direction: "recv" });
    const consumed = await v.request("signaling.consume", {
      transport_id: (transport.payload as { transport_id: string }).transport_id,
      rtp_capabilities: room.router.rtpCapabilities,
    });
    expect(consumed.type).toBe("signaling.consume.result");
    const consumerId = (consumed.payload as { consumer_id: string }).consumer_id;
    expect((await v.request("signaling.resume", { consumer_id: consumerId })).type).toBe("signaling.resume.result");

    producer.close();
    expect((await v.next("signaling.consumer_closed")).payload.consumer_id).toBe(consumerId);
    expect((await v.next("stream.status", (m) => m.payload.status === "offline")).payload.status).toBe("offline");
    await expect.poll(() => server.backend.presence).toContainEqual([table, false]);
    expect(mediasoup.version).toBeTruthy();
  });
});

describe("control channel", () => {
  test("camera reports reach viewers; late viewers get the latest ones", async () => {
    const table = randomUUID();
    const v1 = await viewer(table);
    const c = await camera(table);
    const caps = c.send("camera.capabilities", {
      params: Object.fromEntries(
        ["focus", "iso", "exposure", "brightness", "contrast", "white_balance", "zoom"].map((p) => [
          p,
          { supported: false, modes: [], presets: [] },
        ]),
      ) as never,
    });
    expect((await v1.next("camera.capabilities")).id).toBe(caps.id);
    const v2 = await viewer(table);
    expect((await v2.next("camera.capabilities")).id).toBe(caps.id);
  });

  test("camera.set goes to the camera, its ack only to the sender", async () => {
    const table = randomUUID();
    const c = await camera(table);
    const sender = await viewer(table);
    const other = await viewer(table);
    const set = sender.send("camera.set", { param: "iso", control: { mode: "manual", value: 400 } });
    expect((await c.next("camera.set")).id).toBe(set.id);
    c.send("camera.ack", { request_id: set.id, ok: true, applied: { mode: "manual", value: 400 } });
    expect((await sender.next("camera.ack")).payload.request_id).toBe(set.id);
    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(other.received.some((m) => m.type === "camera.ack")).toBe(false);
  });

  test("camera.set without a camera is answered camera_unavailable", async () => {
    const v = await viewer(randomUUID());
    const set = v.send("camera.set", { param: "zoom", control: { mode: "manual", value: 2 } });
    const ack = await v.next("camera.ack", (m) => m.payload.request_id === set.id);
    expect(ack.payload).toEqual({ request_id: set.id, ok: false, error: "camera_unavailable" });
  });

  test("a viewer cannot speak for the camera", async () => {
    const v = await viewer(randomUUID());
    const fake = v.send("device.alert", { kind: "low_battery", level: "warning", message_key: "alertLowBattery" });
    expect((await v.next("signaling.error", (m) => m.payload.request_id === fake.id)).payload.code).toBe("forbidden");
  });

  test("messages must name the sender's table", async () => {
    const v = await viewer(randomUUID());
    const other = v.send("camera.set", { param: "iso", control: { mode: "auto" } }, randomUUID());
    expect((await v.next("signaling.error", (m) => m.payload.request_id === other.id)).payload.code).toBe("forbidden");
  });
});

describe("license", () => {
  async function recheck(table: string, auth = INTERNAL_TOKEN): Promise<number> {
    const res = await fetch(`${server.httpUrl}/internal/tables/${table}/license-check`, {
      method: "POST",
      headers: { "X-Internal-Token": auth },
    });
    return res.status;
  }

  test("«Применить сейчас» blocks the stream at once when the license expired", async () => {
    const table = randomUUID();
    const v = await viewer(table);
    server.backend.licenses.set(table, { status: "expired" });
    expect(await recheck(table)).toBe(204);
    expect((await v.next("license.status", (m) => m.payload.status === "blocked")).payload).toEqual({ status: "blocked" });
  });

  test("grace is announced with the blocking date", async () => {
    const table = randomUUID();
    const v = await viewer(table);
    const graceUntil = new Date(Date.now() + 2 * 86_400_000);
    server.backend.licenses.set(table, { status: "grace", grace_until: graceUntil.toISOString() });
    await recheck(table);
    const msg = await v.next("license.status", (m) => m.payload.status === "grace");
    expect(msg.payload.grace_until).toBe(graceUntil.getTime());
  });

  test("the recheck endpoint is internal and knows only open rooms", async () => {
    expect(await recheck(randomUUID())).toBe(404);
    expect(await recheck(randomUUID(), "wrong")).toBe(401);
  });

  test("a backend outage keeps the last status", async () => {
    const table = randomUUID();
    const v = await viewer(table);
    server.backend.server.close();
    server.backend.server.closeAllConnections();
    await server.rooms.find(table)?.checkLicense();
    expect(server.rooms.find(table)?.license.status).toBe("active");
    expect(v.received.some((m) => m.type === "license.status" && m.payload.status === "blocked")).toBe(false);
  });
});
