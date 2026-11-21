// White-label builds (SPEC 10.1): one folder in branding/ and one command.
//
//   node brand/brand.ts apply <brand>    prepare the apps' sources for the brand (no build)
//   node brand/brand.ts apk <brand>      apply + the camera APK
//   node brand/brand.ts windows <brand>  apply + the Windows program and its installer (on Windows)
//   node brand/brand.ts build <brand>    apk, and windows when run on Windows (`make build BRAND=<brand>`)
//
// What "apply" changes:
// - build/brand/<brand>/defines.json: brand.json flattened for `flutter build --dart-define-from-file`
//   (the apps' BuildBrand; Android's applicationId and label come from it in build.gradle.kts);
// - apps/viewer_windows/windows/runner/brand.h: the program's names and window title (git-ignored);
// - apps/shared/assets/brand/logo.png and the launcher/program icons (flutter_launcher_icons): the default
//   brand's are committed, so `apply default` puts the repository back as it was.
// Results land in build/brand/<brand>/.
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const WINDOWS = process.platform === "win32";

export interface SellerContacts {
  phone?: string;
  whatsapp?: string;
  telegram?: string;
  email?: string;
  website?: string;
  note?: string;
}

export interface BrandConfig {
  app_name: string;
  android_application_id: string;
  windows_app_id: string;
  colors: { primary: string; secondary: string; background: string; accent: string };
  logo: string;
  icon: string;
  seller_contacts?: SellerContacts;
}

/** branding/<name>/brand.json, checked against the rules of contracts/branding/brand_config.json. */
export function loadBrand(name: string): { config: BrandConfig; dir: string } {
  if (!/^[a-z0-9][a-z0-9_-]*$/.test(name)) throw new Error(`bad brand name: ${name}`);
  const dir = join(ROOT, "branding", name);
  const file = join(dir, "brand.json");
  if (!existsSync(file)) {
    const known = readdirSync(join(ROOT, "branding")).join(", ");
    throw new Error(`no ${file}; brands: ${known}`);
  }
  const config = JSON.parse(readFileSync(file, "utf8")) as BrandConfig;
  const problems: string[] = [];
  if (!config.app_name || config.app_name.length > 50) problems.push("app_name");
  if (!/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/.test(config.android_application_id)) problems.push("android_application_id");
  if (!/^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$/.test(config.windows_app_id)) problems.push("windows_app_id");
  for (const key of ["primary", "secondary", "background", "accent"] as const) {
    if (!/^#[0-9A-Fa-f]{6}$/.test(config.colors[key])) problems.push(`colors.${key}`);
  }
  for (const key of ["logo", "icon"] as const) {
    if (!/^[A-Za-z0-9_.-]+\.png$/.test(config[key]) || !existsSync(join(dir, config[key]))) problems.push(key);
  }
  if (problems.length > 0) throw new Error(`${file}: bad ${problems.join(", ")}`);
  return { config, dir };
}

/** brand.json flattened: the keys the apps (BuildBrand) and build.gradle.kts read. */
export function defines(name: string, config: BrandConfig): Record<string, string> {
  return {
    BRAND_ID: name,
    BRAND_APP_NAME: config.app_name,
    BRAND_ANDROID_APPLICATION_ID: config.android_application_id,
    BRAND_WINDOWS_APP_ID: config.windows_app_id,
    BRAND_COLOR_PRIMARY: config.colors.primary,
    BRAND_COLOR_SECONDARY: config.colors.secondary,
    BRAND_COLOR_BACKGROUND: config.colors.background,
    BRAND_COLOR_ACCENT: config.colors.accent,
    // The build's fallback for the seller's contacts, as JSON (the server's take precedence).
    ...(config.seller_contacts ? { BRAND_SELLER_CONTACTS: JSON.stringify(config.seller_contacts) } : {}),
  };
}

/** A C string literal; non-ASCII as \x escapes of its UTF-8 bytes, `wide` as L"" with \u escapes. */
export function cString(text: string, wide = false): string {
  let out = "";
  for (const ch of text) {
    const code = ch.codePointAt(0) ?? 0;
    if (ch === '"' || ch === "\\") out += `\\${ch}`;
    else if (code >= 0x20 && code < 0x7f) out += ch;
    else if (wide) out += code > 0xffff ? `\\U${code.toString(16).padStart(8, "0")}` : `\\u${code.toString(16).padStart(4, "0")}`;
    else for (const byte of Buffer.from(ch, "utf8")) out += `\\x${byte.toString(16).padStart(2, "0")}`;
  }
  // A hex escape swallows the hex digits after it: close and reopen the literal after each.
  return wide ? `L"${out}"` : `"${out.replace(/(\\x[0-9a-f]{2})(?=[0-9A-Fa-f])/g, '$1""')}"`;
}

/** apps/viewer_windows/windows/runner/brand.h: the names Runner.rc and main.cpp use. */
export function brandHeader(config: BrandConfig): string {
  return [
    "// Written by tools/brand/brand.ts from branding/<brand>/brand.json; not in git.",
    "#pragma once",
    `#define BRAND_APP_NAME ${cString(config.app_name)}`,
    `#define BRAND_WINDOW_TITLE ${cString(config.app_name, true)}`,
    "",
  ].join("\n");
}

function run(command: string, args: string[], cwd: string): void {
  console.log(`brand: ${command} ${args.join(" ")}  (in ${cwd})`);
  // flutter and dart are .bat files on Windows: they need a shell there (ISCC is an .exe, its arguments go as is).
  const script = command === "flutter" || command === "dart";
  execFileSync(command, args, { cwd, stdio: "inherit", shell: WINDOWS && script });
}

/** The icons from brand.json's icon: Android launcher icons, and the program's .ico on Windows. */
function icons(name: string, iconPath: string, out: string): void {
  const apps: [string, string][] = [
    ["camera_android", `flutter_launcher_icons:\n  image_path: "${iconPath}"\n  android: true\n  ios: false\n`],
    [
      "viewer_windows",
      `flutter_launcher_icons:\n  image_path: "${iconPath}"\n  android: false\n  ios: false\n  windows:\n    generate: true\n    image_path: "${iconPath}"\n    icon_size: 256\n`,
    ],
  ];
  for (const [app, yaml] of apps) {
    const config = join(out, `icons_${app}.yaml`);
    writeFileSync(config, yaml);
    run("dart", ["run", "flutter_launcher_icons", "-f", config], join(ROOT, "apps", app));
  }
  console.log(`brand: ${name} icons done`);
}

/** Prepares the sources for the brand; returns the folder of its build results. */
export function apply(name: string, options: { icons?: boolean } = {}): string {
  const { config, dir } = loadBrand(name);
  const out = join(ROOT, "build", "brand", name);
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, "defines.json"), `${JSON.stringify(defines(name, config), null, 2)}\n`);
  writeFileSync(join(ROOT, "apps/viewer_windows/windows/runner/brand.h"), brandHeader(config));
  copyFileSync(join(dir, config.logo), join(ROOT, "apps/shared/assets/brand/logo.png"));
  if (options.icons !== false) icons(name, join(dir, config.icon).replaceAll("\\", "/"), out);
  console.log(`brand: ${name} applied (${config.app_name}); results in ${out}`);
  return out;
}

function slug(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "app";
}

const version = (): string => {
  const pubspec = readFileSync(join(ROOT, "apps/viewer_windows/pubspec.yaml"), "utf8");
  return /^version:\s*([0-9.]+)/m.exec(pubspec)?.[1] ?? "0.0.0";
};

/** The camera app's release APK, as build/brand/<brand>/<name>-camera.apk. */
export function apk(name: string): string {
  const out = apply(name);
  const { config } = loadBrand(name);
  const app = join(ROOT, "apps/camera_android");
  run("flutter", ["build", "apk", "--release", `--dart-define-from-file=${join(out, "defines.json")}`], app);
  const file = join(out, `${slug(config.app_name)}-camera.apk`);
  copyFileSync(join(app, "build/app/outputs/flutter-apk/app-release.apk"), file);
  console.log(`brand: ${file}`);
  return file;
}

/** The C++ runtime the program needs, next to it: no VC++ redistributable to install (SPEC 8.6). */
const RUNTIME = ["msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"];

function innoCompiler(): string {
  for (const path of [
    process.env.ISCC,
    "C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe",
    "C:\\Program Files\\Inno Setup 6\\ISCC.exe",
  ]) {
    if (path && existsSync(path)) return path;
  }
  return "iscc";
}

/** The Windows program and its Inno Setup installer, as build/brand/<brand>/<name>-setup.exe. */
export function windows(name: string): string {
  if (!WINDOWS) throw new Error("the Windows program builds on Windows only");
  const out = apply(name);
  const { config } = loadBrand(name);
  const app = join(ROOT, "apps/viewer_windows");
  run("flutter", ["build", "windows", "--release", `--dart-define-from-file=${join(out, "defines.json")}`], app);
  const release = join(app, "build/windows/x64/runner/Release");
  const system = join(process.env.SystemRoot ?? "C:\\Windows", "System32");
  for (const dll of RUNTIME) copyFileSync(join(system, dll), join(release, dll));
  const setupName = `${slug(config.app_name)}-setup`;
  run(
    innoCompiler(),
    [
      `/DAppName=${config.app_name}`,
      `/DAppId=${config.windows_app_id}`,
      `/DAppVersion=${version()}`,
      `/DSourceDir=${release}`,
      `/DOutputDir=${out}`,
      `/DOutputName=${setupName}`,
      `/DIconFile=${join(app, "windows/runner/resources/app_icon.ico")}`,
      join(app, "installer/viewer.iss"),
    ],
    app,
  );
  console.log(`brand: ${join(out, `${setupName}.exe`)}`);
  return join(out, `${setupName}.exe`);
}

const [command, name = "default"] = process.argv.slice(2);
if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  switch (command) {
    case "apply":
      apply(name);
      break;
    case "apk":
      apk(name);
      break;
    case "windows":
      windows(name);
      break;
    case "build":
      apk(name);
      if (WINDOWS) windows(name);
      else console.log("brand: the Windows installer builds on Windows (CI's build-windows job)");
      break;
    default:
      console.error("usage: node brand/brand.ts apply|apk|windows|build <brand>");
      process.exit(2);
  }
}
