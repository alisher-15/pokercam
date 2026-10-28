// Runs inside headless Chromium (bundled by esbuild): a camera or a viewer speaking to media-server like
// the real apps do — mediasoup-client's Device API only, never hand-built SDP (CLAUDE.md).
import { Device, type types } from "mediasoup-client";

export interface BotConfig {
  wsUrl: string;
  token: string;
  tableId: string;
  role: "camera" | "viewer";
}

export interface BotState {
  joined: boolean;
  error: string | null;
  closedCode: number | null;
  license: string | null;
  stream: string | null;
  /** Camera: what it sends. Viewer: what it decodes. */
  codec: string | null;
  width: number;
  height: number;
  fps: number;
  frames: number;
  producerId: string | null;
  acks: { request_id: string; ok: boolean }[];
  cameraSets: number;
}

interface Envelope {
  type: string;
  id: string;
  ts: number;
  table_id: string;
  payload: Record<string, unknown>;
}

const state: BotState = {
  joined: false,
  error: null,
  closedCode: null,
  license: null,
  stream: null,
  codec: null,
  width: 0,
  height: 0,
  fps: 0,
  frames: 0,
  producerId: null,
  acks: [],
  cameraSets: 0,
};

let ws: WebSocket;
let config: BotConfig;
let device: Device;
/** Resolves once the device knows the router's codecs: the server may announce a producer before that. */
let markLoaded: () => void;
const loaded = new Promise<void>((resolve) => (markLoaded = resolve));
let transport: types.Transport | undefined;
let producer: types.Producer | undefined;
const consumers = new Map<string, types.Consumer>();
const pending = new Map<string, { resolve: (p: Record<string, unknown>) => void; reject: (e: Error) => void }>();

function send(type: string, payload: Record<string, unknown>): string {
  const msg: Envelope = { type, id: crypto.randomUUID(), ts: Date.now(), table_id: config.tableId, payload };
  ws.send(JSON.stringify(msg));
  return msg.id;
}

function request(type: string, payload: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
  const id = send(type, payload);
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

function onMessage(msg: Envelope): void {
  const requestId = msg.payload.request_id;
  const waiting = typeof requestId === "string" ? pending.get(requestId) : undefined;
  if (waiting && (msg.type.endsWith(".result") || msg.type === "signaling.error")) {
    pending.delete(requestId as string);
    if (msg.type === "signaling.error") waiting.reject(new Error(String(msg.payload.code)));
    else waiting.resolve(msg.payload);
    return;
  }
  switch (msg.type) {
    case "license.status":
      state.license = String(msg.payload.status);
      return;
    case "stream.status":
      state.stream = String(msg.payload.status);
      return;
    case "signaling.new_producer":
      if (config.role === "viewer") void loaded.then(consume).catch((e: unknown) => (state.error = String(e)));
      return;
    case "signaling.consumer_closed":
      consumers.get(String(msg.payload.consumer_id))?.close();
      consumers.delete(String(msg.payload.consumer_id));
      return;
    case "camera.set":
      // The fake camera applies everything at once and reports it, like the real app (SPEC 5.3).
      state.cameraSets++;
      send("camera.ack", { request_id: msg.id, ok: true, applied: (msg.payload as { control: unknown }).control });
      send("camera.state", { controls: { [String(msg.payload.param)]: msg.payload.control } });
      return;
    case "camera.ack":
      state.acks.push({ request_id: String(msg.payload.request_id), ok: Boolean(msg.payload.ok) });
      return;
  }
}

async function createTransport(direction: "send" | "recv"): Promise<types.Transport> {
  const p = await request("signaling.create_transport", { direction });
  const options = {
    id: p.transport_id as string,
    iceParameters: p.ice_parameters as types.IceParameters,
    iceCandidates: p.ice_candidates as types.IceCandidate[],
    dtlsParameters: p.dtls_parameters as types.DtlsParameters,
  };
  const t = direction === "send" ? device.createSendTransport(options) : device.createRecvTransport(options);
  t.on("connect", ({ dtlsParameters }, done, fail) => {
    request("signaling.connect_transport", { transport_id: t.id, dtls_parameters: dtlsParameters }).then(() => {
      done();
    }, fail);
  });
  t.on("produce", ({ rtpParameters }, done, fail) => {
    request("signaling.produce", { transport_id: t.id, kind: "video", rtp_parameters: rtpParameters }).then((r) => {
      done({ id: r.producer_id as string });
    }, fail);
  });
  return t;
}

async function publish(): Promise<void> {
  const stream = await navigator.mediaDevices.getUserMedia({ video: { width: 1920, height: 1080, frameRate: 30 } });
  const track = stream.getVideoTracks()[0];
  if (!track) throw new Error("no camera");
  transport = await createTransport("send");
  const h264 = device.sendRtpCapabilities.codecs?.find((c) => c.mimeType.toLowerCase() === "video/h264");
  producer = await transport.produce({
    track,
    encodings: [{ maxBitrate: 4_000_000, maxFramerate: 30 }],
    ...(h264 ? { codec: h264 } : {}),
  });
  state.producerId = producer.id;
  const unsupported = { supported: false, modes: [], presets: [] };
  send("camera.capabilities", {
    params: {
      focus: unsupported,
      iso: { supported: true, modes: ["auto", "manual"], min: 100, max: 1600, step: 50, presets: [] },
      exposure: unsupported,
      brightness: unsupported,
      contrast: unsupported,
      white_balance: unsupported,
      zoom: { supported: true, modes: ["manual"], min: 1, max: 4, step: 0.1, presets: [] },
    },
  });
}

async function consume(): Promise<void> {
  transport ??= await createTransport("recv");
  const p = await request("signaling.consume", { transport_id: transport.id, rtp_capabilities: device.recvRtpCapabilities });
  const consumer = await transport.consume({
    id: p.consumer_id as string,
    producerId: p.producer_id as string,
    kind: "video",
    rtpParameters: p.rtp_parameters as types.RtpParameters,
  });
  consumers.set(consumer.id, consumer);
  const video = document.createElement("video");
  video.muted = true;
  video.autoplay = true;
  video.srcObject = new MediaStream([consumer.track]);
  document.body.append(video);
  await request("signaling.resume", { consumer_id: consumer.id });
}

async function refreshStats(): Promise<void> {
  const source = config.role === "camera" ? producer : [...consumers.values()].at(-1);
  if (!source) return;
  const reports = [...(await source.getStats()).values()] as Record<string, unknown>[];
  const rtp = reports.find((r) => r.type === (config.role === "camera" ? "outbound-rtp" : "inbound-rtp"));
  if (!rtp) return;
  const codec = reports.find((r) => r.type === "codec" && r.id === rtp.codecId);
  state.codec = codec ? String(codec.mimeType) : null;
  state.width = Number(rtp.frameWidth ?? 0);
  state.height = Number(rtp.frameHeight ?? 0);
  state.fps = Number(rtp.framesPerSecond ?? 0);
  state.frames = Number((config.role === "camera" ? rtp.framesEncoded : rtp.framesDecoded) ?? 0);
}

async function start(cfg: BotConfig): Promise<void> {
  config = cfg;
  ws = new WebSocket(cfg.wsUrl);
  ws.onmessage = (event: MessageEvent<string>) => {
    onMessage(JSON.parse(event.data) as Envelope);
  };
  ws.onclose = (event) => {
    state.closedCode = event.code;
  };
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = reject;
  });
  try {
    await request("signaling.join", { token: cfg.token });
    state.joined = true;
    device = await Device.factory();
    const caps = await request("signaling.get_router_rtp_capabilities");
    await device.load({ routerRtpCapabilities: caps.rtp_capabilities as types.RtpCapabilities });
    markLoaded();
    if (cfg.role === "camera") await publish();
    setInterval(() => void refreshStats(), 1000);
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error);
  }
}

declare global {
  interface Window {
    bot: {
      start: (cfg: BotConfig) => Promise<void>;
      state: () => BotState;
      cameraSet: (param: string, value: number) => string;
    };
  }
}

window.bot = {
  start,
  state: () => structuredClone(state),
  cameraSet: (param, value) => send("camera.set", { param, control: { mode: "manual", value } }),
};
