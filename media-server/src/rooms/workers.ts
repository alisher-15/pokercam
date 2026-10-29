import * as mediasoup from "mediasoup";
import type { types } from "mediasoup";
import type { Logger } from "pino";
import type { Config } from "../config.js";

/** H.264 first (SPEC 6.3: the phones' hardware encoder), VP8 for anything without it. */
export const MEDIA_CODECS: types.RouterRtpCodecCapability[] = [
  {
    kind: "video",
    mimeType: "video/H264",
    clockRate: 90000,
    parameters: { "packetization-mode": 1, "profile-level-id": "42e01f", "level-asymmetry-allowed": 1 },
  },
  {
    kind: "video",
    mimeType: "video/H264",
    clockRate: 90000,
    parameters: { "packetization-mode": 1, "profile-level-id": "4d001f", "level-asymmetry-allowed": 1 },
  },
  { kind: "video", mimeType: "video/VP8", clockRate: 90000 },
];

interface Slot {
  worker: types.Worker;
  webRtcServer: types.WebRtcServer;
}

/** mediasoup workers, one per core (SPEC 7.1); rooms go to them round-robin. Each serves RTC on one UDP+TCP port. */
export class WorkerPool {
  private next = 0;

  private constructor(private readonly slots: Slot[]) {}

  static async start(config: Config, log: Logger): Promise<WorkerPool> {
    const slots: Slot[] = [];
    for (let i = 0; i < config.workers; i++) {
      const worker = await mediasoup.createWorker({ logLevel: "warn" });
      worker.on("died", (error) => {
        // A dead worker takes its rooms with it; the container restarts and clients reconnect (SPEC 11.1).
        log.fatal({ err: error, worker_pid: worker.pid }, "mediasoup worker died");
        process.exit(1);
      });
      // RTC_PORT_MIN = 0 (tests only): any free port.
      const port = config.rtcPortMin === 0 ? undefined : config.rtcPortMin + i;
      const listen = { ip: config.rtcListenIp, announcedAddress: config.rtcAnnouncedAddress, ...(port === undefined ? {} : { port }) };
      const webRtcServer = await worker.createWebRtcServer({
        listenInfos: [
          { protocol: "udp", ...listen },
          { protocol: "tcp", ...listen },
        ],
      });
      slots.push({ worker, webRtcServer });
    }
    log.info({ workers: slots.length, rtc_ports: `${String(config.rtcPortMin)}-${String(config.rtcPortMin + slots.length - 1)}` }, "mediasoup workers started");
    return new WorkerPool(slots);
  }

  get size(): number {
    return this.slots.length;
  }

  async createRouter(): Promise<{ router: types.Router; webRtcServer: types.WebRtcServer }> {
    const slot = this.slots[this.next++ % this.slots.length] as Slot;
    return { router: await slot.worker.createRouter({ mediaCodecs: MEDIA_CODECS }), webRtcServer: slot.webRtcServer };
  }

  close(): void {
    for (const { worker } of this.slots) worker.close();
  }
}
