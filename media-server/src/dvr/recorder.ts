import { spawn, type ChildProcess } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createInterface } from "node:readline";
import type { types } from "mediasoup";
import type { Logger } from "pino";
import { DvrIndex, parseRunPlaylist } from "./playlist.js";
import type { PortPool } from "./ports.js";
import { ffmpegSdp, isH264 } from "./sdp.js";

/** ADR-4: a keyframe every second, so FFmpeg cuts 1 s segments and new viewers start fast. */
const KEYFRAME_INTERVAL_MS = 1000;
/** SPEC 7.4: a killed FFmpeg must be writing again within 5 s. */
const STALL_TIMEOUT_MS = 5000;
const POLL_MS = 250;
/** Segments a run's clock correction is measured on. */
const CLOCK_SAMPLES = 15;
const MAX_RESTART_DELAY_MS = 5000;
const STOP_TIMEOUT_MS = 3000;

export interface RecorderSettings {
  ffmpegPath: string;
  ports: PortPool;
  log: Logger;
}

/**
 * FFmpeg's command line (SPEC 7.2) for one run, started in the run's directory: RTP from the SDP file,
 * remuxed without transcoding into 1 s fMP4 segments. Its own playlist only lists the latest segments;
 * media-server keeps the window, deletes old files and serves the playlist (see DvrIndex).
 */
export function ffmpegArgs(sdpPath: string): string[] {
  return [
    "-hide_banner",
    "-nostdin",
    "-nostats",
    "-loglevel",
    "warning",
    "-protocol_whitelist",
    "file,udp,rtp",
    "-fflags",
    "+genpts",
    "-i",
    sdpPath,
    "-map",
    "0:v:0",
    "-c",
    "copy",
    "-f",
    "hls",
    "-hls_time",
    "1",
    "-hls_list_size",
    "10",
    "-hls_segment_type",
    "fmp4",
    "-hls_fmp4_init_filename",
    "init.mp4",
    "-hls_segment_filename",
    "%d.m4s",
    "-hls_flags",
    "program_date_time+independent_segments",
    "index.m3u8",
  ];
}

/** One FFmpeg process writing into r{run}/. */
interface Run {
  id: number;
  dir: string;
  /** Unset until its directory exists and FFmpeg is spawned. */
  process: ChildProcess | undefined;
  startedAt: number;
  /** Highest FFmpeg sequence number already in the index. */
  seen: number;
  segments: number;
  /** Set when we stop it on purpose: its exit is not a crash. */
  stopping: boolean;
  exited: Promise<void>;
  stderr: string[];
  /** When its first segments appeared minus their program date-time ends, ms (see DvrIndex.setClockOffset). */
  lags: number[];
}

/** A camera's stream being recorded: the PlainTransport consumer and the FFmpeg runs reading it. */
interface Recording {
  producer: types.Producer;
  transport: types.PlainTransport;
  consumer: types.Consumer;
  port: number;
  sdpPath: string;
  run: Run | undefined;
  stopped: boolean;
  failures: number;
  restartTimer: NodeJS.Timeout | undefined;
  timers: NodeJS.Timeout[];
  lastSegmentAt: number;
  lastPacketAt: number;
  packets: number;
}

/**
 * One table's DVR (SPEC 7.2). It outlives cameras and rooms: when the camera goes away the buffer stays
 * until newer segments push it out (SPEC 8.5: "DVR остаётся доступен до конца буфера").
 */
export class TableDvr {
  readonly index: DvrIndex;
  private recording: Recording | undefined;
  private nextRun = 1;
  private readonly finishedRuns = new Set<number>();
  private scanning: Promise<void> = Promise.resolve();
  private scansPending = 0;
  /** Serializes record/stop calls for this table. */
  private queue: Promise<void> = Promise.resolve();

  constructor(
    readonly tableId: string,
    readonly dir: string,
    capacity: number,
    private readonly settings: RecorderSettings,
    private readonly log: Logger,
  ) {
    this.index = new DvrIndex(capacity);
  }

  /** True from the start of recording until FFmpeg has exited and the transport is closed. */
  get recordingActive(): boolean {
    return this.recording !== undefined;
  }

  /** The running FFmpeg's pid (logs, tests). */
  get ffmpegPid(): number | undefined {
    return this.recording?.run?.process?.pid;
  }

  /** Starts recording this producer, finishing the previous one first (new phone: a discontinuity). */
  record(router: types.Router, producer: types.Producer): Promise<void> {
    this.queue = this.queue.then(() => this.start(router, producer)).catch((error: unknown) => {
      this.log.error({ err: error }, "DVR could not start");
    });
    return this.queue;
  }

  stop(): Promise<void> {
    const recording = this.recording;
    this.queue = this.queue.then(() => (recording ? this.finish(recording) : undefined));
    return this.queue;
  }

  private async start(router: types.Router, producer: types.Producer): Promise<void> {
    if (this.recording) await this.finish(this.recording);
    if (producer.closed) return;
    if (!isH264(producer.rtpParameters)) {
      this.log.warn({ codec: producer.rtpParameters.codecs[0]?.mimeType }, "DVR records H.264 only; this stream is live only");
      return;
    }
    const port = this.settings.ports.take();
    if (port === undefined) {
      this.log.error("no free DVR RTP port: raise DVR_RTP_PORT_MAX");
      return;
    }
    const transport = await router.createPlainTransport({
      listenInfo: { protocol: "udp", ip: "127.0.0.1", port: port + 2 },
      rtcpListenInfo: { protocol: "udp", ip: "127.0.0.1", port: port + 3 },
      rtcpMux: false,
      comedia: false,
    });
    await transport.connect({ ip: "127.0.0.1", port, rtcpPort: port + 1 });
    const consumer = await transport.consume({ producerId: producer.id, rtpCapabilities: router.rtpCapabilities, paused: true });
    await mkdir(this.dir, { recursive: true });
    const sdpPath = join(this.dir, "input.sdp");
    await writeFile(sdpPath, ffmpegSdp(consumer.rtpParameters, port, port + 1));
    const recording: Recording = {
      producer,
      transport,
      consumer,
      port,
      sdpPath,
      run: undefined,
      stopped: false,
      failures: 0,
      restartTimer: undefined,
      timers: [],
      lastSegmentAt: Date.now(),
      lastPacketAt: 0,
      packets: 0,
    };
    this.recording = recording;
    // The camera left, was replaced, or the license closed its stream: the room closes the producer.
    consumer.observer.once("close", () => void this.stop());
    // A paused camera sends nothing: finish the run, and start a new one (a discontinuity) on resume.
    producer.observer.on("pause", () => {
      if (this.recording === recording) void this.endRun(recording);
    });
    producer.observer.on("resume", () => {
      if (this.recording === recording && !recording.run) this.startRun(recording);
    });
    recording.timers.push(
      setInterval(() => {
        if (!consumer.closed && !consumer.paused && !producer.paused) consumer.requestKeyFrame().catch(() => undefined);
      }, KEYFRAME_INTERVAL_MS),
      setInterval(() => {
        if (this.scansPending === 0) void this.scan();
      }, POLL_MS),
      setInterval(() => void this.watch(recording), 1000),
    );
    await consumer.resume();
    this.log.info({ port, sdp: await readFile(sdpPath, "utf8") }, "DVR recording");
    if (!producer.paused) this.startRun(recording);
  }

  private startRun(recording: Recording): void {
    if (recording.stopped) return;
    const id = this.nextRun++;
    const dir = join(this.dir, `r${String(id)}`);
    const run: Run = {
      id,
      dir,
      process: undefined,
      startedAt: Date.now(),
      seen: -1,
      segments: 0,
      stopping: false,
      exited: Promise.resolve(),
      stderr: [],
      lags: [],
    };
    recording.run = run;
    recording.lastSegmentAt = Date.now();
    void mkdir(dir, { recursive: true }).then(() => {
      if (recording.run !== run || run.stopping) {
        this.finishedRuns.add(id);
        void this.cleanRuns();
        return;
      }
      const child = spawn(this.settings.ffmpegPath, ffmpegArgs(recording.sdpPath), { cwd: dir, stdio: ["ignore", "ignore", "pipe"] });
      run.process = child;
      run.exited = new Promise((resolve) => child.once("close", () => { resolve(); }));
      createInterface({ input: child.stderr }).on("line", (line) => {
        run.stderr.push(line);
        if (run.stderr.length > 20) run.stderr.shift();
        this.log.debug({ run: id, ffmpeg: line }, "ffmpeg");
      });
      child.on("error", (error) => {
        this.log.error({ err: error, run: id }, "FFmpeg did not start");
      });
      child.once("close", (code, signal) => void this.onExit(recording, run, code, signal));
      this.log.info({ run: id, pid: child.pid }, "FFmpeg started");
      recording.consumer.requestKeyFrame().catch(() => undefined);
    });
  }

  private async onExit(recording: Recording, run: Run, code: number | null, signal: NodeJS.Signals | null): Promise<void> {
    await this.scan(recording, run);
    this.finishedRuns.add(run.id);
    if (recording.run === run) recording.run = undefined;
    await this.cleanRuns();
    if (run.stopping || recording.stopped) {
      this.log.info({ run: run.id, segments: run.segments }, "FFmpeg run finished");
      // Stopped for a pause the camera has already ended: record again.
      if (!recording.stopped && !recording.producer.paused && !recording.run) this.startRun(recording);
      return;
    }
    // SPEC 7.2: restart at once after a crash; back off only while runs keep failing before any segment.
    recording.failures = run.segments > 0 ? 0 : recording.failures + 1;
    const delay = recording.failures === 0 ? 0 : Math.min(MAX_RESTART_DELAY_MS, 500 * 2 ** recording.failures);
    this.log.warn({ run: run.id, code, signal, segments: run.segments, restart_in_ms: delay, stderr: run.stderr.slice(-5) }, "FFmpeg exited, restarting");
    recording.restartTimer = setTimeout(() => {
      recording.restartTimer = undefined;
      if (!recording.producer.paused && !recording.run) this.startRun(recording);
    }, delay);
  }

  /** Restarts FFmpeg if packets reach it but no segment came out for STALL_TIMEOUT_MS. */
  private async watch(recording: Recording): Promise<void> {
    const run = recording.run;
    if (recording.stopped || recording.consumer.closed) return;
    const stats = await recording.consumer.getStats().catch(() => []);
    const packets = stats.find((s) => s.type === "outbound-rtp")?.packetCount ?? 0;
    if (packets > recording.packets) recording.lastPacketAt = Date.now();
    recording.packets = packets;
    if (!run || run.stopping || run.process === undefined) return;
    const now = Date.now();
    if (now - recording.lastSegmentAt > STALL_TIMEOUT_MS && now - recording.lastPacketAt < 2000) {
      this.log.warn({ run: run.id, stderr: run.stderr.slice(-5) }, "FFmpeg stalled, killing it");
      run.process.kill("SIGKILL");
    }
  }

  /** Moves a run's newly finished segments (by default the current run's) into the window and deletes what fell out. */
  scan(recording = this.recording, run = recording?.run): Promise<void> {
    this.scansPending++;
    this.scanning = this.scanning.then(async () => {
      if (!recording || !run) return;
      let text: string;
      try {
        text = await readFile(join(run.dir, "index.m3u8"), "utf8");
      } catch {
        return;
      }
      for (const segment of parseRunPlaylist(text)) {
        if (segment.sequence <= run.seen) continue;
        // FFmpeg's list only holds the last few: segments it dropped before we looked would never be deleted.
        for (let missed = run.seen + 1; missed < segment.sequence; missed++) {
          this.log.warn({ run: run.id, segment: missed }, "DVR missed a segment");
          await rm(join(run.dir, `${String(missed)}.m4s`), { force: true });
        }
        run.seen = segment.sequence;
        run.segments++;
        recording.lastSegmentAt = Date.now();
        if (run.lags.length < CLOCK_SAMPLES) {
          // A segment is written when the next keyframe arrives, so it shows up when it ends (+ half a poll on average).
          run.lags.push(Date.now() - POLL_MS / 2 - (segment.programDateTime + segment.durationS * 1000));
          const sorted = [...run.lags].sort((a, b) => a - b);
          this.index.setClockOffset(run.id, sorted[Math.floor(sorted.length / 2)] ?? 0);
        }
        for (const old of this.index.add(run.id, segment)) {
          await rm(join(this.dir, `r${String(old.run)}`, old.uri), { force: true });
        }
      }
      await this.cleanRuns();
    }).catch((error: unknown) => {
      this.log.warn({ err: error }, "DVR scan failed");
    }).finally(() => {
      this.scansPending--;
    });
    return this.scanning;
  }

  /** Deletes the directories of finished runs that have no segment left in the window. */
  private async cleanRuns(): Promise<void> {
    const live = this.index.liveRuns();
    for (const id of [...this.finishedRuns]) {
      if (live.has(id)) continue;
      this.finishedRuns.delete(id);
      await rm(join(this.dir, `r${String(id)}`), { recursive: true, force: true });
    }
  }

  /** Stops the current FFmpeg run gracefully: SIGINT makes it write out the segment in progress. */
  private async endRun(recording: Recording): Promise<void> {
    const run = recording.run;
    if (!run) return;
    run.stopping = true;
    const child = run.process;
    if (child === undefined) return;
    child.kill("SIGINT");
    const killer = setTimeout(() => child.kill("SIGKILL"), STOP_TIMEOUT_MS);
    await run.exited;
    clearTimeout(killer);
  }

  private async finish(recording: Recording): Promise<void> {
    if (recording.stopped) return;
    recording.stopped = true;
    clearTimeout(recording.restartTimer);
    for (const timer of recording.timers) clearInterval(timer);
    const run = recording.run;
    await this.endRun(recording);
    await this.scan(recording, run);
    recording.transport.close();
    this.settings.ports.release(recording.port);
    await rm(recording.sdpPath, { force: true });
    if (this.recording === recording) this.recording = undefined;
    this.log.info({ segments: this.index.size }, "DVR recording stopped");
  }

  /** Stops recording and deletes the whole buffer. */
  async destroy(): Promise<void> {
    await this.stop();
    await rm(this.dir, { recursive: true, force: true });
  }
}
