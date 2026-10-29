/**
 * Localhost UDP ports of a table's DVR, four in a block: FFmpeg receives RTP on the first and RTCP on the
 * second, mediasoup's PlainTransport sends from the third (RTP) and fourth (RTCP). All fixed, so no
 * randomly chosen port can take one FFmpeg is about to bind.
 */
export class PortPool {
  private readonly free: number[] = [];

  constructor(min: number, max: number) {
    for (let port = min + (min % 2); port + 3 <= max; port += 4) this.free.push(port);
  }

  get available(): number {
    return this.free.length;
  }

  /** The first port of a free block, or undefined when every block is taken. */
  take(): number | undefined {
    return this.free.shift();
  }

  /** A released block goes to the back, so ports a dying FFmpeg may still hold are reused last. */
  release(port: number): void {
    if (!this.free.includes(port)) this.free.push(port);
  }
}
