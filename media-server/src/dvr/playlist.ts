// The DVR playlists (SPEC 7.2): FFmpeg writes a short HLS playlist per run, media-server keeps the
// table's last N segments across runs and serves one sliding-window playlist with a discontinuity
// wherever FFmpeg restarted or the camera changed. For the player it also serves one run from a given
// segment on as an EVENT playlist (?from=): its head never moves, so a player can seek in it.

/** A finished segment as FFmpeg listed it. */
export interface RunSegment {
  /** Media sequence number inside the run. */
  sequence: number;
  /** File name inside the run's directory. */
  uri: string;
  durationS: number;
  /** EXT-X-PROGRAM-DATE-TIME, epoch ms. */
  programDateTime: number;
}

/** Reads the segments of an FFmpeg media playlist; an entry without its URI line (half written) is skipped. */
export function parseRunPlaylist(text: string): RunSegment[] {
  let sequence = 0;
  let duration: number | undefined;
  let pdt: number | undefined;
  const segments: RunSegment[] = [];
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (line.startsWith("#EXT-X-MEDIA-SEQUENCE:")) {
      sequence = Number(line.slice("#EXT-X-MEDIA-SEQUENCE:".length));
    } else if (line.startsWith("#EXTINF:")) {
      duration = Number.parseFloat(line.slice("#EXTINF:".length));
    } else if (line.startsWith("#EXT-X-PROGRAM-DATE-TIME:")) {
      pdt = parseDateTime(line.slice("#EXT-X-PROGRAM-DATE-TIME:".length));
    } else if (line !== "" && !line.startsWith("#")) {
      if (duration !== undefined && Number.isFinite(duration) && pdt !== undefined) {
        segments.push({ sequence, uri: line, durationS: duration, programDateTime: pdt });
      }
      sequence++;
      duration = undefined;
      pdt = undefined;
    }
  }
  return segments;
}

/** FFmpeg writes the offset as +0000, which not every parser takes. */
function parseDateTime(value: string): number | undefined {
  const ms = Date.parse(value.replace(/([+-]\d\d)(\d\d)$/, "$1:$2"));
  return Number.isNaN(ms) ? undefined : ms;
}

const path = (run: number, uri: string): string => `r${String(run)}/${uri}`;

export interface DvrEntry extends RunSegment {
  run: number;
  /** Sequence number in the table's playlist. */
  mediaSequence: number;
  /** The first segment of a run after another run: a discontinuity precedes it. */
  discontinuity: boolean;
}

/**
 * One table's buffer: the last `capacity` segments of all runs, oldest first. The segments that fell out
 * stay listed in the runs' EVENT playlists for `history` more (their files are gone), so the playlist a
 * player has open keeps its head.
 */
export class DvrIndex {
  private readonly entries: DvrEntry[] = [];
  /** Entries that fell out of the window, oldest first, at most `history`. */
  private readonly past: DvrEntry[] = [];
  /** Runs FFmpeg has finished: their EVENT playlists end (EXT-X-ENDLIST). */
  private readonly closed = new Set<number>();
  /** `r{run}/{uri}` of every entry, for serving only what the playlist lists. */
  private readonly paths = new Set<string>();
  /** Per run, ms to add to FFmpeg's program date-times so they match the wall clock (see setClockOffset). */
  private readonly offsets = new Map<number, number>();
  private nextMediaSequence = 0;
  private discontinuitySequence = 0;
  private lastRun: number | undefined;
  /** HLS forbids changing it, so it only grows, and only if a segment is longer than expected. */
  private targetDuration = 2;

  constructor(
    readonly capacity: number,
    readonly history = capacity * 6,
  ) {}

  get size(): number {
    return this.entries.length;
  }

  get first(): DvrEntry | undefined {
    return this.entries[0];
  }

  get last(): DvrEntry | undefined {
    return this.entries.at(-1);
  }

  /** Adds a run's finished segment; returns the entries that fell out of the window (their files go). */
  add(run: number, segment: RunSegment): DvrEntry[] {
    const entry: DvrEntry = {
      ...segment,
      run,
      mediaSequence: this.nextMediaSequence++,
      discontinuity: this.lastRun !== undefined && this.lastRun !== run,
    };
    this.lastRun = run;
    this.entries.push(entry);
    this.paths.add(path(run, segment.uri));
    this.targetDuration = Math.max(this.targetDuration, Math.ceil(segment.durationS));
    const removed = this.entries.splice(0, Math.max(0, this.entries.length - this.capacity));
    for (const e of removed) this.paths.delete(path(e.run, e.uri));
    this.past.push(...removed);
    this.past.splice(0, Math.max(0, this.past.length - this.history));
    const live = this.liveRuns();
    for (const r of this.offsets.keys()) if (!live.has(r)) this.offsets.delete(r);
    const listed = new Set([...this.past, ...this.entries].map((e) => e.run));
    for (const r of this.closed) if (!listed.has(r)) this.closed.delete(r);
    // RFC 8216 6.2.2: dropping a segment that carries EXT-X-DISCONTINUITY bumps the sequence.
    this.discontinuitySequence += removed.filter((e) => e.discontinuity).length;
    return removed;
  }

  /** FFmpeg finished this run: no segment will be added to it. */
  closeRun(run: number): void {
    this.closed.add(run);
  }

  /** Runs that still have segments in the window. */
  liveRuns(): Set<number> {
    return new Set(this.entries.map((e) => e.run));
  }

  /**
   * FFmpeg stamps a run's first segment with the time it wrote the output header, after probing the input,
   * so its program date-times run ahead of the real moment (about 0.9 s). The recorder measures that from
   * when segments actually appear and sets the run's correction here (SPEC 8.3: −5 s is exactly 5 s ago).
   */
  setClockOffset(run: number, ms: number): void {
    this.offsets.set(run, ms);
  }

  /** An entry's program date-time on the wall clock, epoch ms. */
  programDateTime(entry: DvrEntry): number {
    return entry.programDateTime + (this.offsets.get(entry.run) ?? 0);
  }

  /** Whether the playlist lists this segment now. */
  has(run: number, uri: string): boolean {
    return this.paths.has(path(run, uri));
  }

  /** Buffer bounds for dvr.info: from the oldest segment's start to the newest one's end, epoch ms. */
  range(): { from: number; to: number } | undefined {
    const first = this.first;
    const last = this.last;
    if (!first || !last) return undefined;
    return { from: Math.round(this.programDateTime(first)), to: Math.round(this.programDateTime(last) + last.durationS * 1000) };
  }

  /** The sliding-window playlist; segment URIs are relative to it (`r{run}/{file}`). */
  render(): string {
    const lines = [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      `#EXT-X-TARGETDURATION:${String(this.targetDuration)}`,
      `#EXT-X-MEDIA-SEQUENCE:${String(this.first?.mediaSequence ?? this.nextMediaSequence)}`,
      `#EXT-X-DISCONTINUITY-SEQUENCE:${String(this.discontinuitySequence)}`,
      "#EXT-X-INDEPENDENT-SEGMENTS",
    ];
    for (const entry of this.entries) {
      if (entry.discontinuity) lines.push("#EXT-X-DISCONTINUITY");
      lines.push(
        `#EXT-X-PROGRAM-DATE-TIME:${new Date(Math.round(this.programDateTime(entry))).toISOString()}`,
        `#EXTINF:${entry.durationS.toFixed(3)},`,
        `r${String(entry.run)}/${entry.uri}`,
      );
    }
    return `${lines.join("\n")}\n`;
  }

  /**
   * The player's playlist: the run of segment `from` (a media sequence number) from that segment on, as an
   * EVENT playlist that only grows and ends when FFmpeg has finished the run. A player seeks in it, which it
   * cannot do in the sliding window (FFmpeg's HLS demuxer maps time to segments from the playlist's head).
   * Without program date-times, to keep it small: the player reloads it every second. Undefined when that
   * segment is no longer remembered.
   */
  renderRun(from: number): string | undefined {
    const all = [...this.past, ...this.entries];
    const head = all.find((e) => e.mediaSequence === from);
    if (!head) return undefined;
    const lines = [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      `#EXT-X-TARGETDURATION:${String(this.targetDuration)}`,
      "#EXT-X-PLAYLIST-TYPE:EVENT",
      `#EXT-X-MEDIA-SEQUENCE:${String(from)}`,
      "#EXT-X-INDEPENDENT-SEGMENTS",
    ];
    for (const entry of all) {
      if (entry.run === head.run && entry.mediaSequence >= from) {
        lines.push(`#EXTINF:${entry.durationS.toFixed(3)},`, `r${String(entry.run)}/${entry.uri}`);
      }
    }
    if (this.closed.has(head.run)) lines.push("#EXT-X-ENDLIST");
    return `${lines.join("\n")}\n`;
  }
}
