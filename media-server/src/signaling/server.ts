import type { Server } from "node:http";
import type { types } from "mediasoup";
import type { Logger } from "pino";
import { WebSocketServer, type WebSocket } from "ws";
import { TokenError, type TokenVerifier } from "../auth/jwt.js";
import { ForbiddenMessage, routeControl, welcome } from "../control/hub.js";
import type { Message } from "../contracts/messages.js";
import type { SignalingErrorCode } from "../contracts/types.js";
import { message, parseMessage, type MessageOf } from "../contracts/validate.js";
import { withContext } from "../log.js";
import type { RoomRegistry } from "../rooms/registry.js";
import { RoomFullError, type Room } from "../rooms/room.js";
import { Peer } from "./peer.js";

/** A signaling request that failed for a reason the client acts on (SPEC 5.3, signaling.error). */
class SignalingFailure extends Error {
  constructor(
    readonly code: SignalingErrorCode,
    reason: string,
  ) {
    super(reason);
  }
}

const fail = (code: SignalingErrorCode, reason: string): never => {
  throw new SignalingFailure(code, reason);
};

export interface SignalingDeps {
  verifier: TokenVerifier;
  rooms: RoomRegistry;
  log: Logger;
}

/** The WebSocket at /ws: mediasoup signaling and the control channel on one connection (ADR-6). */
export class SignalingServer {
  private wss: WebSocketServer | undefined;

  constructor(private readonly deps: SignalingDeps) {}

  attach(server: Server): void {
    this.wss = new WebSocketServer({ server, path: "/ws", maxPayload: 256 * 1024 });
    this.wss.on("connection", (ws) => {
      this.connect(ws);
    });
  }

  close(): void {
    this.wss?.close();
  }

  private connect(ws: WebSocket): void {
    const peer = new Peer(ws, withContext(this.deps.log, {}));
    ws.on("message", (data) => {
      // eslint-disable-next-line @typescript-eslint/no-base-to-string -- text frames only
      const raw = data.toString();
      peer.queue = peer.queue.then(() => this.receive(peer, raw));
    });
    ws.on("close", () => {
      peer.queue = peer.queue.then(() => {
        peer.room?.leave(peer);
        peer.log.info("left");
      });
    });
  }

  private async receive(peer: Peer, raw: string): Promise<void> {
    const parsed = parseMessage(raw);
    if (!parsed.ok) {
      peer.log.warn({ error: parsed.error }, "rejected message");
      this.error(peer, requestIdOf(raw), "bad_request", parsed.error);
      return;
    }
    const msg = parsed.message;
    try {
      if (msg.type.startsWith("signaling.")) {
        await this.signaling(peer, msg);
        return;
      }
      const room = this.joined(peer, msg);
      routeControl(room, peer, msg);
    } catch (error) {
      if (error instanceof SignalingFailure) {
        peer.log.warn({ type: msg.type, code: error.code, reason: error.message }, "request refused");
        this.error(peer, msg.id, error.code, error.message);
      } else if (error instanceof ForbiddenMessage) {
        peer.log.warn({ type: msg.type, code: "forbidden", reason: error.message }, "request refused");
        this.error(peer, msg.id, "forbidden", error.message);
      } else {
        peer.log.error({ err: error, type: msg.type }, "request failed");
        this.error(peer, msg.id, "internal", "internal error");
      }
    }
  }

  private error(peer: Peer, requestId: string, code: SignalingErrorCode, reason: string): void {
    const tableId = peer.claims?.table_id ?? "00000000-0000-0000-0000-000000000000";
    peer.send(message("signaling.error", tableId, { request_id: requestId, code, message: reason }));
  }

  /** The peer's room; every message after join must name the peer's own table. */
  private joined(peer: Peer, msg: Message): Room {
    if (!peer.room || !peer.claims) return fail("unauthorized", "send signaling.join first");
    if (msg.table_id !== peer.claims.table_id) return fail("forbidden", "another table");
    return peer.room;
  }

  private async signaling(peer: Peer, msg: Message): Promise<void> {
    if (msg.type === "signaling.join") {
      await this.join(peer, msg);
      return;
    }
    const room = this.joined(peer, msg);
    const reply = <T extends Parameters<typeof message>[0]>(type: T, payload: MessageOf<T>["payload"]): void => {
      peer.send(message(type, room.tableId, payload));
    };
    switch (msg.type) {
      case "signaling.get_router_rtp_capabilities":
        reply("signaling.get_router_rtp_capabilities.result", {
          request_id: msg.id,
          rtp_capabilities: room.router.rtpCapabilities,
        });
        return;
      case "signaling.create_transport": {
        const sending = msg.payload.direction === "send";
        if (sending !== (peer.role === "camera")) fail("forbidden", "cameras send, viewers receive");
        const transport = await room.router.createWebRtcTransport({
          webRtcServer: room.webRtcServer,
          enableUdp: !msg.payload.force_tcp,
          enableTcp: true,
          preferUdp: true,
          initialAvailableOutgoingBitrate: 4_000_000,
          appData: { direction: msg.payload.direction },
        });
        if (sending) await transport.setMaxIncomingBitrate(5_000_000);
        peer.transports.set(transport.id, transport);
        reply("signaling.create_transport.result", {
          request_id: msg.id,
          transport_id: transport.id,
          ice_parameters: transport.iceParameters,
          ice_candidates: transport.iceCandidates,
          dtls_parameters: transport.dtlsParameters,
          // TURN for viewers outside the club comes with SPEC 13's answer (stage 9).
          ice_servers: [],
        });
        return;
      }
      case "signaling.connect_transport": {
        await this.transport(peer, msg.payload.transport_id).connect({
          dtlsParameters: msg.payload.dtls_parameters as unknown as types.DtlsParameters,
        });
        reply("signaling.connect_transport.result", { request_id: msg.id });
        return;
      }
      case "signaling.produce": {
        if (peer.role !== "camera") fail("forbidden", "only the camera produces");
        if (room.license.status === "blocked") fail("license_blocked", "the license blocks the stream");
        const producer = await this.transport(peer, msg.payload.transport_id).produce({
          kind: "video",
          rtpParameters: msg.payload.rtp_parameters as unknown as types.RtpParameters,
        });
        room.setProducer(producer);
        peer.log.info({ producer_id: producer.id }, "camera producing");
        reply("signaling.produce.result", { request_id: msg.id, producer_id: producer.id });
        return;
      }
      case "signaling.consume": {
        if (peer.role !== "viewer") fail("forbidden", "only viewers consume");
        if (room.license.status === "blocked") fail("license_blocked", "the license blocks the stream");
        const producer = room.producer ?? fail("not_found", "the camera is not publishing");
        const rtpCapabilities = msg.payload.rtp_capabilities as unknown as types.RtpCapabilities;
        if (!room.router.canConsume({ producerId: producer.id, rtpCapabilities })) {
          fail("bad_request", "the client cannot decode the camera's codec");
        }
        const consumer = await this.transport(peer, msg.payload.transport_id).consume({
          producerId: producer.id,
          rtpCapabilities,
          paused: true,
        });
        peer.consumers.set(consumer.id, consumer);
        consumer.observer.once("close", () => {
          peer.consumers.delete(consumer.id);
          peer.send(message("signaling.consumer_closed", room.tableId, { consumer_id: consumer.id }));
        });
        reply("signaling.consume.result", {
          request_id: msg.id,
          consumer_id: consumer.id,
          producer_id: producer.id,
          kind: "video",
          rtp_parameters: consumer.rtpParameters,
        });
        return;
      }
      case "signaling.resume": {
        const consumer = peer.consumers.get(msg.payload.consumer_id) ?? fail("not_found", "no such consumer");
        await consumer.resume();
        await consumer.requestKeyFrame();
        reply("signaling.resume.result", { request_id: msg.id });
        return;
      }
      default:
        fail("bad_request", `${msg.type} is sent by the server`);
    }
  }

  /** Role and table come from the token, never from the message (SPEC 7.1). */
  private async join(peer: Peer, msg: MessageOf<"signaling.join">): Promise<void> {
    if (peer.room) fail("bad_request", "already joined");
    let claims;
    try {
      claims = await this.deps.verifier.verify(msg.payload.token);
    } catch (error) {
      if (error instanceof TokenError) fail("unauthorized", error.message);
      throw error;
    }
    if (!claims.table_id) return fail("forbidden", "the token is not for a table");
    if (claims.table_id !== msg.table_id) fail("forbidden", "the token is for another table");
    const room = await this.deps.rooms.get(claims.table_id, { status: claims.lic });
    if (claims.role === "camera") await room.checkLicense();
    if (room.license.status === "blocked") fail("license_blocked", "the license blocks this table");
    // Only the phone paired now may publish: a replaced phone keeps a valid token for a while (SPEC 9.2).
    const paired = room.license.cameraDeviceId;
    if (claims.role === "camera" && paired !== undefined && paired !== claims.sub) {
      fail("forbidden", "this phone is no longer the table's camera");
    }
    peer.claims = claims;
    try {
      room.admit(peer);
    } catch (error) {
      peer.claims = undefined;
      if (error instanceof RoomFullError) fail("room_full", "the table already has its maximum of viewers");
      throw error;
    }
    peer.room = room;
    peer.log = withContext(this.deps.log, {
      table_id: room.tableId,
      device_id: claims.role === "camera" ? claims.sub : null,
      session_id: peer.sessionId,
    }).child({ role: claims.role, ...(claims.role === "viewer" ? { viewer_id: claims.sub } : {}) });
    peer.send(
      message("signaling.join.result", room.tableId, {
        request_id: msg.id,
        role: claims.role,
        peer_id: peer.id,
        session_id: peer.sessionId,
      }),
    );
    if (claims.role === "viewer") {
      welcome(room, peer);
    } else {
      peer.send(room.licenseStatus());
    }
    peer.log.info("joined");
  }

  private transport(peer: Peer, id: string): types.WebRtcTransport {
    return peer.transports.get(id) ?? fail("not_found", "no such transport");
  }
}

/** The id of a message that failed validation, if it has one, so the client can match the error. */
function requestIdOf(raw: string): string {
  try {
    const id: unknown = (JSON.parse(raw) as { id?: unknown }).id;
    if (typeof id === "string" && id.length > 0 && id.length <= 64) return id;
  } catch {
    // not JSON
  }
  return "invalid";
}
