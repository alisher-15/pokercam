import type { types } from "mediasoup";

/**
 * The SDP file FFmpeg reads the DVR consumer's RTP with (SPEC 7.2). It only describes plain RTP on
 * localhost for FFmpeg's input and is built from the consumer's own parameters; WebRTC peers still
 * negotiate through mediasoup's Device API only (CLAUDE.md).
 */
export function ffmpegSdp(rtpParameters: types.RtpParameters, rtpPort: number, rtcpPort: number): string {
  const codec = rtpParameters.codecs[0];
  if (!codec) throw new Error("the consumer has no codec");
  const name = codec.mimeType.split("/")[1] ?? "";
  const fmtp = Object.entries(codec.parameters ?? {})
    .map(([key, value]) => `${key}=${String(value)}`)
    .join(";");
  const lines = [
    "v=0",
    "o=- 0 0 IN IP4 127.0.0.1",
    "s=PokerCam DVR",
    "c=IN IP4 127.0.0.1",
    "t=0 0",
    `m=video ${String(rtpPort)} RTP/AVP ${String(codec.payloadType)}`,
    `a=rtcp:${String(rtcpPort)}`,
    `a=rtpmap:${String(codec.payloadType)} ${name}/${String(codec.clockRate)}`,
    ...(fmtp ? [`a=fmtp:${String(codec.payloadType)} ${fmtp}`] : []),
    "a=sendonly",
  ];
  return `${lines.join("\n")}\n`;
}

/** DVR remuxes without transcoding into fMP4, which carries H.264 (the phone's codec, SPEC 6.1). */
export function isH264(rtpParameters: types.RtpParameters): boolean {
  return rtpParameters.codecs[0]?.mimeType.toLowerCase() === "video/h264";
}
