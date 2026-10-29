import { generateKeyPairSync, randomUUID, sign } from "node:crypto";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WebSocket } from "ws";
import { createApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import type { Message, MessageType } from "../src/contracts/messages.js";
import type { AccessTokenClaims, InternalLicenseResponse } from "../src/contracts/types.js";
import { validateMessage, type MessageOf } from "../src/contracts/validate.js";
import { createLogger } from "../src/log.js";

export const INTERNAL_TOKEN = "test-internal-token";
const keys = generateKeyPairSync("ed25519");

/** An access JWT signed like the backend's (EdDSA). */
export function token(claims: Partial<AccessTokenClaims> & Pick<AccessTokenClaims, "role" | "sub">, key = keys.privateKey): string {
  const now = Math.floor(Date.now() / 1000);
  const full = { client_id: randomUUID(), lic: "active", iat: now, exp: now + 3600, ...claims };
  const part = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const unsigned = `${part({ alg: "EdDSA", typ: "JWT" })}.${part(full)}`;
  return `${unsigned}.${sign(null, Buffer.from(unsigned), key).toString("base64url")}`;
}

/** The backend's internal API as media-server sees it, with licenses set by the test. */
export class FakeBackend {
  readonly licenses = new Map<string, Partial<InternalLicenseResponse>>();
  readonly presence: [string, boolean][] = [];
  starts = 0;
  server: Server = createServer((req, res) => {
    if (req.headers["x-internal-token"] !== INTERNAL_TOKEN) {
      res.writeHead(401).end();
      return;
    }
    const url = req.url ?? "";
    if (url === "/api/v1/internal/jwt-key") {
      const pem = keys.publicKey.export({ type: "spki", format: "pem" }).toString();
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ algorithm: "EdDSA", public_key_pem: pem }));
      return;
    }
    if (url === "/api/v1/internal/media-server/started") {
      this.starts++;
      res.writeHead(204).end();
      return;
    }
    const license = /^\/api\/v1\/internal\/tables\/([^/]+)\/license$/.exec(url);
    if (license) {
      const tableId = license[1] as string;
      const body = {
        table_id: tableId,
        client_id: randomUUID(),
        status: "active",
        paid_until: new Date(Date.now() + 86_400_000).toISOString(),
        grace_until: new Date(Date.now() + 4 * 86_400_000).toISOString(),
        ...this.licenses.get(tableId),
      };
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(body));
      return;
    }
    const camera = /^\/api\/v1\/internal\/tables\/([^/]+)\/camera$/.exec(url);
    if (camera && req.method === "PUT") {
      let body = "";
      req.on("data", (chunk: Buffer) => (body += chunk.toString()));
      req.on("end", () => {
        this.presence.push([camera[1] as string, (JSON.parse(body) as { online: boolean }).online]);
        res.writeHead(204).end();
      });
      return;
    }
    res.writeHead(404).end();
  });

  async start(): Promise<string> {
    this.server.listen(0, "127.0.0.1");
    await once(this.server, "listening");
    return `http://127.0.0.1:${String((this.server.address() as AddressInfo).port)}`;
  }
}

// Below the kernel's ephemeral ports (32768+), in a random block per test file: files run in parallel.
let nextDvrPort = 20000 + 40 * Math.floor(Math.random() * 300);

/** media-server in this process: real mediasoup workers, real HTTP and WebSocket, the fake backend. */
export async function startMediaServer(overrides: Partial<Config> = {}) {
  const backend = new FakeBackend();
  const backendUrl = await backend.start();
  const dvrRtpPortMin = nextDvrPort;
  nextDvrPort += 40;
  const config: Config = {
    port: 0,
    logLevel: "silent",
    backendUrl,
    internalApiToken: INTERNAL_TOKEN,
    rtcListenIp: "127.0.0.1",
    rtcAnnouncedAddress: "127.0.0.1",
    rtcPortMin: 0,
    workers: 1,
    maxViewersPerTable: 5,
    licenseCheckIntervalMs: 600_000,
    dvrEnabled: false,
    dvrDir: await mkdtemp(join(tmpdir(), "pokercam-dvr-")),
    dvrSegments: 600,
    dvrRtpPortMin,
    dvrRtpPortMax: dvrRtpPortMin + 39,
    ffmpegPath: "ffmpeg",
    ...overrides,
  };
  const app = await createApp(config, createLogger(process.env.TEST_LOG_LEVEL ?? "silent"), 0);
  app.server.listen(0, "127.0.0.1");
  await once(app.server, "listening");
  const port = (app.server.address() as AddressInfo).port;
  return {
    backend,
    rooms: app.rooms,
    dvr: app.dvr,
    config,
    httpUrl: `http://127.0.0.1:${String(port)}`,
    wsUrl: `ws://127.0.0.1:${String(port)}/ws`,
    async stop() {
      await app.close();
      backend.server.close();
      await rm(config.dvrDir, { recursive: true, force: true });
    },
  };
}

/** A WebSocket client speaking the contracts; every message it receives is checked against them. */
export class Client {
  readonly received: Message[] = [];
  readonly invalid: string[] = [];
  private waiters: { match: (m: Message) => boolean; resolve: (m: Message) => void }[] = [];
  closedWith: number | undefined;

  private constructor(
    private readonly ws: WebSocket,
    readonly tableId: string,
  ) {
    ws.on("message", (data) => {
      // eslint-disable-next-line @typescript-eslint/no-base-to-string -- text frames only
      const parsed = validateMessage(JSON.parse(data.toString()));
      if (!parsed.ok) {
        this.invalid.push(parsed.error);
        return;
      }
      this.received.push(parsed.message);
      this.waiters = this.waiters.filter((w) => {
        if (!w.match(parsed.message)) return true;
        w.resolve(parsed.message);
        return false;
      });
    });
    ws.on("close", (code) => {
      this.closedWith = code;
    });
  }

  static async connect(url: string, tableId: string): Promise<Client> {
    const ws = new WebSocket(url);
    await once(ws, "open");
    return new Client(ws, tableId);
  }

  sendRaw(text: string): void {
    this.ws.send(text);
  }

  /** Sends a message and returns it (its id is what replies point to). */
  send<T extends MessageType>(type: T, payload: MessageOf<T>["payload"], tableId = this.tableId): MessageOf<T> {
    const msg = { type, id: randomUUID(), ts: Date.now(), table_id: tableId, payload } as MessageOf<T>;
    this.ws.send(JSON.stringify(msg));
    return msg;
  }

  /** The first received message (already or later) of this type that matches. */
  next<T extends MessageType>(type: T, match: (m: MessageOf<T>) => boolean = () => true, timeoutMs = 3000): Promise<MessageOf<T>> {
    const test = (m: Message): boolean => m.type === type && match(m as MessageOf<T>);
    const seen = this.received.find(test);
    if (seen) return Promise.resolve(seen as MessageOf<T>);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`no ${type} within ${String(timeoutMs)} ms; got ${this.received.map((m) => m.type).join(", ")}`));
      }, timeoutMs);
      this.waiters.push({
        match: test,
        resolve: (m) => {
          clearTimeout(timer);
          resolve(m as MessageOf<T>);
        },
      });
    });
  }

  /** Sends a request and waits for its result or signaling.error. */
  async request<T extends MessageType>(type: T, payload: MessageOf<T>["payload"], tableId?: string): Promise<Message> {
    const sent = this.send(type, payload, tableId);
    const isReply = (m: Message): boolean =>
      "request_id" in m.payload && (m.payload).request_id === sent.id;
    const seen = this.received.find(isReply);
    if (seen) return seen;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`no reply to ${type}`));
      }, 5000);
      this.waiters.push({
        match: isReply,
        resolve: (m) => {
          clearTimeout(timer);
          resolve(m);
        },
      });
    });
  }

  async join(jwt: string): Promise<Message> {
    return this.request("signaling.join", { token: jwt });
  }

  close(): void {
    this.ws.close();
  }

  async closed(): Promise<number> {
    if (this.closedWith !== undefined) return this.closedWith;
    const [code] = (await once(this.ws, "close")) as [number];
    return code;
  }
}
