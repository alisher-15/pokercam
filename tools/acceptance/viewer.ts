// The browser viewer (media-server's /viewer/, the club's PC until the Windows client): signs in with the club's
// activation key, plays the table's fake camera, changes a camera setting and shows the camera's answer, and
// shows a pairing code with its QR. Any error on the page fails the run.
// node acceptance/viewer.ts --key K [--backend http://localhost:8000] [--media ws://localhost:3000/ws] [--screenshot file.png]
import { toolArgs } from "../bots/args.ts";
import { club } from "../bots/backend.ts";
import { BotFarm } from "../bots/farm.ts";

const { backend, media, key, screenshot } = toolArgs({ screenshot: { type: "string", default: "" } }) as Record<
  "backend" | "media" | "key" | "screenshot",
  string
>;
const results: { check: string; ok: boolean; detail: string }[] = [];
const check = (name: string, ok: boolean, detail: string): void => {
  results.push({ check: name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}: ${detail}`);
};

const viewerUrl = `${media.replace(/^ws/, "http").replace(/\/ws$/, "")}/viewer/`;
const table = await club(backend, key);
const farm = await BotFarm.start();
const pageErrors: string[] = [];
try {
  const camera = await farm.launch("camera", { wsUrl: media, tableId: table.tableId, role: "camera", token: await table.cameraToken() });
  await camera.waitFor((s) => s.frames > 10);

  const page = await farm.page();
  page.on("pageerror", (error) => pageErrors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") pageErrors.push(message.text());
  });
  await page.goto(viewerUrl);
  await page.getByLabel("Server address").fill(backend);
  await page.getByLabel("Client activation key").fill(key);
  const started = Date.now();
  await page.getByRole("button", { name: "Connect" }).click();

  // One table: the page goes straight to it.
  await page.locator(".chip.live").waitFor({ timeout: 30_000 });
  await page.waitForFunction(() => (document.querySelector("video")?.getVideoPlaybackQuality().totalVideoFrames ?? 0) > 10, undefined, {
    timeout: 30_000,
  });
  const size = await page.evaluate(() => {
    const video = document.querySelector("video");
    return `${String(video?.videoWidth)}x${String(video?.videoHeight)}`;
  });
  check("activation key → the table's camera plays", true, `${((Date.now() - started) / 1000).toFixed(1)} s, ${size}`);

  // The fake camera offers ISO (auto/manual) and zoom (manual) and acknowledges at once.
  const zoom = page.locator(".param", { hasText: "Zoom" });
  await zoom.locator('input[type="range"]').fill("2");
  const ack = zoom.locator(".ack.ok");
  await ack.waitFor({ timeout: 10_000 });
  check("a camera setting from the page gets the camera's answer", /applied in \d+ ms/.test(await ack.innerText()), await ack.innerText());
  const unsupported = await page.locator(".param", { hasText: "Focus" }).innerText();
  check("unsupported settings say so", unsupported.includes("not supported"), unsupported.replace(/\s+/g, " "));

  const received = page.locator("section", { hasText: "Table" }).locator("dl");
  await received.locator("dd").first().waitFor({ timeout: 10_000 });
  check("what this computer receives is shown", true, (await received.innerText()).replace(/\s+/g, " "));
  if (screenshot) await page.screenshot({ path: screenshot });
  await page.getByRole("button", { name: "Pair a phone" }).click();
  const dialog = page.locator("dialog[open]");
  if (screenshot) await dialog.screenshot({ path: screenshot.replace(/(\.png)?$/, "-pairing.png") });
  const code = (await dialog.locator(".code").innerText()).trim();
  const qr = await dialog.locator(".qr svg").count();
  check("pairing code with its QR", /^\d{6}$/.test(code) && qr === 1, `code ${code}, QR ${qr === 1 ? "shown" : "missing"}`);
  await dialog.getByRole("button", { name: "Close" }).click();

  // Back after a reload: the key is remembered.
  await page.reload();
  await page.locator(".chip.live").waitFor({ timeout: 30_000 });
  check("a reload goes straight back to the table", true, "no key asked");
} catch (error) {
  check("the run completed", false, String(error));
} finally {
  await farm.close();
}
check("no errors on the page", pageErrors.length === 0, pageErrors.join(" | ") || "none");

const failed = results.filter((r) => !r.ok);
console.log(JSON.stringify({ table_id: table.tableId, passed: failed.length === 0, results }, null, 2));
process.exit(failed.length === 0 ? 0 : 1);
