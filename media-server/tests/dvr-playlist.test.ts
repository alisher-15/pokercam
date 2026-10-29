import { describe, expect, test } from "vitest";
import { DvrIndex, parseRunPlaylist, type RunSegment } from "../src/dvr/playlist.js";
import { PortPool } from "../src/dvr/ports.js";
import { ffmpegSdp, isH264 } from "../src/dvr/sdp.js";

// What FFmpeg 6/7 writes with -hls_flags program_date_time and a 10-segment list.
const FFMPEG_PLAYLIST = `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:1
#EXT-X-MEDIA-SEQUENCE:4
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MAP:URI="init.mp4"
#EXTINF:1.000000,
#EXT-X-PROGRAM-DATE-TIME:2026-10-28T21:50:54.912+0000
4.m4s
#EXTINF:0.966667,
#EXT-X-PROGRAM-DATE-TIME:2026-10-28T21:50:55.912+0000
5.m4s
#EXTINF:1.033333,
#EXT-X-PROGRAM-DATE-TIME:2026-10-28T21:50:56.879+0000
`;

const segment = (sequence: number, at = 1_793_180_000_000 + sequence * 1000): RunSegment => ({
  sequence,
  uri: `${String(sequence)}.m4s`,
  durationS: 1,
  programDateTime: at,
});

describe("FFmpeg's playlist", () => {
  test("gives finished segments with their sequence, duration and wall-clock time", () => {
    expect(parseRunPlaylist(FFMPEG_PLAYLIST)).toEqual([
      { sequence: 4, uri: "4.m4s", durationS: 1, programDateTime: Date.parse("2026-10-28T21:50:54.912Z") },
      { sequence: 5, uri: "5.m4s", durationS: 0.966667, programDateTime: Date.parse("2026-10-28T21:50:55.912Z") },
    ]);
  });

  test("an empty or missing playlist has no segments", () => {
    expect(parseRunPlaylist("")).toEqual([]);
    expect(parseRunPlaylist("#EXTM3U\n#EXT-X-VERSION:7\n")).toEqual([]);
  });
});

describe("the table's window", () => {
  test("keeps the last N segments and reports what fell out", () => {
    const index = new DvrIndex(3);
    for (let i = 0; i < 3; i++) expect(index.add(1, segment(i))).toEqual([]);
    const removed = index.add(1, segment(3));
    expect(removed.map((e) => e.uri)).toEqual(["0.m4s"]);
    expect(index.size).toBe(3);
    expect(index.has(1, "0.m4s")).toBe(false);
    expect(index.has(1, "3.m4s")).toBe(true);
    expect(index.render()).toContain("#EXT-X-MEDIA-SEQUENCE:1\n");
  });

  test("a new run gets a discontinuity and its own init segment", () => {
    const index = new DvrIndex(10);
    index.add(1, segment(0));
    index.add(1, segment(1));
    index.add(2, segment(0, 1_793_180_005_000));
    expect(index.render()).toBe(
      [
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        "#EXT-X-TARGETDURATION:2",
        "#EXT-X-MEDIA-SEQUENCE:0",
        "#EXT-X-DISCONTINUITY-SEQUENCE:0",
        "#EXT-X-INDEPENDENT-SEGMENTS",
        '#EXT-X-MAP:URI="r1/init.mp4"',
        "#EXT-X-PROGRAM-DATE-TIME:2026-10-28T09:33:20.000Z",
        "#EXTINF:1.000,",
        "r1/0.m4s",
        "#EXT-X-PROGRAM-DATE-TIME:2026-10-28T09:33:21.000Z",
        "#EXTINF:1.000,",
        "r1/1.m4s",
        "#EXT-X-DISCONTINUITY",
        '#EXT-X-MAP:URI="r2/init.mp4"',
        "#EXT-X-PROGRAM-DATE-TIME:2026-10-28T09:33:25.000Z",
        "#EXTINF:1.000,",
        "r2/0.m4s",
        "",
      ].join("\n"),
    );
    expect([...index.liveRuns()]).toEqual([1, 2]);
  });

  test("dropping a segment that starts a run bumps the discontinuity sequence (RFC 8216 6.2.2)", () => {
    const index = new DvrIndex(2);
    index.add(1, segment(0));
    index.add(2, segment(0));
    index.add(2, segment(1));
    expect(index.render()).toContain("#EXT-X-DISCONTINUITY-SEQUENCE:0\n");
    index.add(2, segment(2));
    const text = index.render();
    expect(text).toContain("#EXT-X-DISCONTINUITY-SEQUENCE:1\n");
    expect(text).not.toContain("#EXT-X-DISCONTINUITY\n");
    expect(text).toContain('#EXT-X-MAP:URI="r2/init.mp4"');
    expect([...index.liveRuns()]).toEqual([2]);
  });

  test("range spans the oldest segment's start to the newest one's end", () => {
    const index = new DvrIndex(10);
    expect(index.range()).toBeUndefined();
    index.add(1, segment(0, 1000));
    index.add(1, { ...segment(1, 2000), durationS: 0.5 });
    expect(index.range()).toEqual({ from: 1000, to: 2500 });
  });

  test("the target duration only grows", () => {
    const index = new DvrIndex(2);
    index.add(1, { ...segment(0), durationS: 2.6 });
    index.add(1, segment(1));
    index.add(1, segment(2));
    expect(index.render()).toContain("#EXT-X-TARGETDURATION:3\n");
  });
});

describe("FFmpeg's SDP input", () => {
  test("describes the consumer's H.264 RTP on localhost", () => {
    const sdp = ffmpegSdp(
      {
        codecs: [
          {
            mimeType: "video/H264",
            payloadType: 102,
            clockRate: 90000,
            parameters: { "level-asymmetry-allowed": 1, "packetization-mode": 1, "profile-level-id": "42e01f" },
          },
        ],
        encodings: [{ ssrc: 1 }],
      },
      50000,
      50001,
    );
    expect(sdp).toBe(
      [
        "v=0",
        "o=- 0 0 IN IP4 127.0.0.1",
        "s=PokerCam DVR",
        "c=IN IP4 127.0.0.1",
        "t=0 0",
        "m=video 50000 RTP/AVP 102",
        "a=rtcp:50001",
        "a=rtpmap:102 H264/90000",
        "a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
        "a=sendonly",
        "",
      ].join("\n"),
    );
  });

  test("only H.264 is recorded", () => {
    expect(isH264({ codecs: [{ mimeType: "video/H264", payloadType: 102, clockRate: 90000 }] })).toBe(true);
    expect(isH264({ codecs: [{ mimeType: "video/VP8", payloadType: 101, clockRate: 90000 }] })).toBe(false);
  });
});

test("ports come in blocks of four from an even port; released blocks are reused last", () => {
  const pool = new PortPool(30001, 30010);
  expect(pool.available).toBe(2);
  expect(pool.take()).toBe(30002);
  expect(pool.take()).toBe(30006);
  expect(pool.take()).toBeUndefined();
  pool.release(30002);
  pool.release(30002);
  expect(pool.available).toBe(1);
  expect(pool.take()).toBe(30002);
});
