import type { types } from "mediasoup";
import type { Logger } from "pino";
import type { BackendClient } from "../backend.js";
import type { DvrManager } from "../dvr/manager.js";
import type { Message } from "../contracts/messages.js";
import type {
  CameraCapabilitiesMessage,
  CameraStateMessage,
  DeviceTelemetryMessage,
  DvrInfoMessage,
  LicenseStatusMessage,
  RoomLicenseStatus,
  StreamState,
  StreamStatusMessage,
} from "../contracts/types.js";
import { message } from "../contracts/validate.js";
import { withContext } from "../log.js";
import type { Peer } from "../signaling/peer.js";

export interface RoomLicense {
  status: RoomLicenseStatus;
  graceUntil?: number;
  /** The phone paired to the table; unknown while the backend has not answered. */
  cameraDeviceId?: string;
}

export class RoomFullError extends Error {}

const DVR_INFO_INTERVAL_MS = 5000;

/** The backend's license status as a room applies it: expired and suspended both block. */
export function roomLicenseStatus(status: string): RoomLicenseStatus {
  return status === "active" || status === "grace" ? status : "blocked";
}

export interface RoomDeps {
  backend: BackendClient;
  /** Records the camera's stream (SPEC 7.2); absent when the DVR is off. */
  dvr?: DvrManager | undefined;
  log: Logger;
  maxViewers: number;
  licenseCheckIntervalMs: number;
  onEmpty: (room: Room) => void;
}

/**
 * One table (SPEC 7): one camera producing, up to maxViewers viewers consuming.
 * The camera's latest capabilities, state and telemetry are kept for viewers that join later.
 */
export class Room {
  camera: Peer | undefined;
  readonly viewers = new Map<string, Peer>();
  producer: types.Producer | undefined;
  license: RoomLicense;
  readonly cache: {
    capabilities?: CameraCapabilitiesMessage;
    state?: CameraStateMessage;
    telemetry?: DeviceTelemetryMessage;
  } = {};
  /** camera.set message id -> the viewer waiting for its camera.ack. */
  readonly pendingAcks = new Map<string, string>();
  private stream: { state: StreamState; since: number } = { state: "offline", since: Date.now() };
  private readonly timer: NodeJS.Timeout;
  private readonly dvrTimer: NodeJS.Timeout;
  readonly log: Logger;

  constructor(
    readonly tableId: string,
    readonly router: types.Router,
    readonly webRtcServer: types.WebRtcServer,
    initial: RoomLicense,
    private readonly deps: RoomDeps,
  ) {
    this.license = initial;
    this.log = withContext(deps.log, { table_id: tableId });
    this.timer = setInterval(() => void this.checkLicense(), deps.licenseCheckIntervalMs);
    this.timer.unref();
    // The buffer's bounds move every second; viewers hear about them every 5 s (and on joining).
    this.dvrTimer = setInterval(() => {
      const info = this.dvrInfo();
      if (info) this.broadcast(info, true);
    }, DVR_INFO_INTERVAL_MS);
    this.dvrTimer.unref();
  }

  dvrInfo(): DvrInfoMessage | undefined {
    return this.deps.dvr?.info(this.tableId);
  }

  /**
   * Asks the backend for the license (SPEC 7.1) and applies it. If the backend cannot be reached the last
   * known status stays: a backend outage must not stop the tables (SPEC 9.1).
   */
  async checkLicense(): Promise<RoomLicense> {
    try {
      const answer = await this.deps.backend.tableLicense(this.tableId);
      const status = roomLicenseStatus(answer.status);
      this.applyLicense({
        status,
        ...(status === "grace" ? { graceUntil: Date.parse(answer.grace_until) } : {}),
        ...(answer.camera_device_id ? { cameraDeviceId: answer.camera_device_id } : {}),
      });
    } catch (error) {
      this.log.warn({ err: error }, "license check failed, keeping the last status");
    }
    return this.license;
  }

  applyLicense(next: RoomLicense): void {
    const changed = next.status !== this.license.status;
    this.license = next;
    if (next.status === "blocked") {
      if (changed) this.log.warn("license blocked: stopping the stream");
      this.stopProducer();
    }
    // Grace is announced at every check: a reminder with the blocking date (SPEC 7.1).
    if (changed || next.status === "grace") this.broadcast(this.licenseStatus());
  }

  /** Adds a peer whose token is for this table. A new camera replaces the old one (phone replaced, SPEC 7.1). */
  admit(peer: Peer): void {
    if (peer.role === "camera") {
      const old = this.camera;
      this.camera = peer;
      if (old && old !== peer) {
        this.log.info({ device_id: old.claims?.sub }, "camera replaced");
        this.leave(old);
        old.close(4001, "replaced by another camera");
      }
      return;
    }
    if (this.viewers.size >= this.deps.maxViewers) throw new RoomFullError();
    this.viewers.set(peer.id, peer);
  }

  leave(peer: Peer): void {
    if (this.camera === peer) {
      this.camera = undefined;
      this.stopProducer();
    }
    this.viewers.delete(peer.id);
    peer.closeMedia();
    if (!this.camera && this.viewers.size === 0) this.deps.onEmpty(this);
  }

  /** The camera started publishing: viewers consume it without reconnecting. */
  setProducer(producer: types.Producer): void {
    if (this.producer && this.producer !== producer) this.producer.close();
    this.producer = producer;
    producer.observer.once("close", () => {
      if (this.producer === producer) {
        this.producer = undefined;
        this.setStream("offline");
      }
    });
    this.setStream("live");
    this.broadcast(message("signaling.new_producer", this.tableId, { producer_id: producer.id, kind: "video" }), true);
    void this.deps.dvr?.record(this.tableId, this.router, producer);
  }

  private stopProducer(): void {
    // Closing it closes every consumer; each viewer gets signaling.consumer_closed.
    this.producer?.close();
  }

  private setStream(state: StreamState): void {
    if (this.stream.state === state) return;
    this.stream = { state, since: Date.now() };
    this.deps.backend.reportCamera(this.tableId, state === "live");
    this.broadcast(this.streamStatus());
  }

  streamStatus(): StreamStatusMessage {
    return message("stream.status", this.tableId, { status: this.stream.state, since: this.stream.since });
  }

  licenseStatus(): LicenseStatusMessage {
    const { status, graceUntil } = this.license;
    return message("license.status", this.tableId, { status, ...(graceUntil === undefined ? {} : { grace_until: graceUntil }) });
  }

  /** To every viewer, and to the camera too unless `viewersOnly`. */
  broadcast(msg: Message, viewersOnly = false): void {
    for (const viewer of this.viewers.values()) viewer.send(msg);
    if (!viewersOnly) this.camera?.send(msg);
  }

  close(): void {
    clearInterval(this.timer);
    clearInterval(this.dvrTimer);
    this.router.close();
  }
}
