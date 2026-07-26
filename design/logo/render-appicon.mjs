#!/usr/bin/env node
// Rasterizes design/logo/app-icon-macos.svg into the 10 PNG sizes macOS's AppIcon.appiconset
// requires, plus writes Contents.json for that imageset and for the top-level Assets.xcassets.
//
// Usage (from repo root or anywhere):
//   node design/logo/render-appicon.mjs
// or, if @resvg/resvg-js is not installed as a dependency anywhere on the machine:
//   npx -y @resvg/resvg-js node design/logo/render-appicon.mjs   (does not work — npx doesn't
//   inject packages into an arbitrary script's resolution this way)
// The correct one-shot form (installs the package into a throwaway location, then runs this
// script under a shell that can resolve it) is:
//   npx -y -p @resvg/resvg-js node design/logo/render-appicon.mjs
//
// This script requires network access to the npm registry the first time (to fetch
// @resvg/resvg-js's prebuilt native binding). If that fails (offline/proxy-blocked), it throws
// and produces no PNGs -- run it later once network access is available, e.g. on the Mac.

import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..", "..");
const svgPath = path.join(here, "app-icon-macos.svg");
const appiconsetDir = path.join(
  repoRoot,
  "Volar",
  "Resources",
  "Assets.xcassets",
  "AppIcon.appiconset"
);
const assetsRootDir = path.join(repoRoot, "Volar", "Resources", "Assets.xcassets");

// macOS AppIcon.appiconset: 10 required PNGs (idiom "mac"), each entry pairs a logical
// "size" (points) with a "scale" (1x/2x); the rendered pixel dimension is size * scale.
const specs = [
  { size: 16, scale: 1, px: 16, filename: "icon_16x16.png" },
  { size: 16, scale: 2, px: 32, filename: "icon_16x16@2x.png" },
  { size: 32, scale: 1, px: 32, filename: "icon_32x32.png" },
  { size: 32, scale: 2, px: 64, filename: "icon_32x32@2x.png" },
  { size: 128, scale: 1, px: 128, filename: "icon_128x128.png" },
  { size: 128, scale: 2, px: 256, filename: "icon_128x128@2x.png" },
  { size: 256, scale: 1, px: 256, filename: "icon_256x256.png" },
  { size: 256, scale: 2, px: 512, filename: "icon_256x256@2x.png" },
  { size: 512, scale: 1, px: 512, filename: "icon_512x512.png" },
  { size: 512, scale: 2, px: 1024, filename: "icon_512x512@2x.png" },
];

function writeContentsJson() {
  mkdirSync(appiconsetDir, { recursive: true });

  const contents = {
    images: specs.map((s) => ({
      filename: s.filename,
      idiom: "mac",
      scale: `${s.scale}x`,
      size: `${s.size}x${s.size}`,
    })),
    info: { author: "xcode", version: 1 },
  };
  writeFileSync(
    path.join(appiconsetDir, "Contents.json"),
    JSON.stringify(contents, null, 2) + "\n"
  );

  const rootContents = { info: { author: "xcode", version: 1 } };
  writeFileSync(
    path.join(assetsRootDir, "Contents.json"),
    JSON.stringify(rootContents, null, 2) + "\n"
  );
  console.log("[render-appicon] wrote Contents.json (imageset + xcassets root).");
}

async function main() {
  // Contents.json is metadata Xcode needs regardless of whether we can rasterize right now, so
  // write it unconditionally before touching resvg.
  writeContentsJson();

  let resvgModule;
  try {
    resvgModule = await import("@resvg/resvg-js");
  } catch (err) {
    console.error(
      "[render-appicon] Could not load @resvg/resvg-js -- Contents.json was written but NO PNGs " +
        "were generated. Install it first, e.g.:\n" +
        "  npm install --no-save @resvg/resvg-js\n" +
        "or run this script via:\n" +
        "  npx -y -p @resvg/resvg-js node design/logo/render-appicon.mjs\n" +
        "Original error:\n" + String(err)
    );
    process.exitCode = 1;
    return;
  }
  const { Resvg } = resvgModule;

  if (!existsSync(svgPath)) {
    throw new Error(`Source SVG not found: ${svgPath}`);
  }
  const svg = readFileSync(svgPath, "utf8");

  const results = [];
  for (const spec of specs) {
    const resvg = new Resvg(svg, {
      fitTo: { mode: "width", value: spec.px },
      background: "rgba(0,0,0,0)",
    });
    const rendered = resvg.render();
    const png = rendered.asPng();
    const outPath = path.join(appiconsetDir, spec.filename);
    writeFileSync(outPath, png);
    const bytes = statSync(outPath).size;
    results.push({ ...spec, bytes });
    console.log(`[render-appicon] wrote ${spec.filename} (${spec.px}x${spec.px}px, ${bytes} bytes)`);
  }

  console.log(`[render-appicon] done: ${results.length} PNGs written.`);
}

main().catch((err) => {
  console.error("[render-appicon] FAILED:", err);
  process.exitCode = 1;
});
