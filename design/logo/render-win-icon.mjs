#!/usr/bin/env node
// design/logo/render-win-icon.mjs — rasterizes design/logo/app-icon.svg (1024x1024, self-contained,
// no external refs) into the multi-resolution Windows .ico Volar.App needs (Task 3, floating-
// capture-window + settings-gear + app-icon follow-up fix).
//
// TOOLING CONSTRAINT (this task's brief): no ImageMagick/Inkscape available in this environment
// (Windows' own convert.exe is the NTFS file-system converter, NOT ImageMagick — never call it).
// node + npm ARE available, so this renders PNGs via @resvg/resvg-js (a WASM/native SVG rasterizer,
// no system dependency beyond node) and assembles them into a real multi-image .ico container via
// png-to-ico, both installed locally under design/logo/.icon-tools/node_modules (a throwaway,
// gitignored-by-convention scratch install — see this file's own header note below on running it).
//
// USAGE:
//   cd design/logo/.icon-tools && npm install @resvg/resvg-js png-to-ico   (one-time, if not already
//     installed — this repo does not commit node_modules; re-run this install after a fresh clone)
//   node ../render-win-icon.mjs
//
// OUTPUT: windows/src/Volar.App/Assets/Volar.ico (16/32/48/64/128/256 px, per this task's brief).
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");

const { Resvg } = await import(pathToFileURL(join(here, ".icon-tools", "node_modules", "@resvg", "resvg-js", "index.js")));
const pngToIco = (await import(pathToFileURL(join(here, ".icon-tools", "node_modules", "png-to-ico", "index.js")))).default;

const svgPath = join(here, "app-icon.svg");
const outDir = join(repoRoot, "windows", "src", "Volar.App", "Assets");
const outIco = join(outDir, "Volar.ico");

// Windows .ico convention (this task's brief): 16/32/48/64/128/256 px — covers taskbar (16/32),
// shell/Explorer large icons (48/64), and jumbo/high-DPI (256) without an oversized file.
const sizes = [16, 32, 48, 64, 128, 256];

const svg = readFileSync(svgPath);

console.log(`Rendering ${sizes.length} PNG sizes from ${svgPath}...`);
const pngBuffers = sizes.map((size) => {
  const resvg = new Resvg(svg, {
    fitTo: { mode: "width", value: size },
    background: "rgba(0,0,0,0)", // app-icon.svg already paints its own opaque rounded-square
                                   // background (the ai-clip clipPath's rx=224 corners + ai-studio
                                   // gradient fill) — transparent canvas here just avoids resvg
                                   // adding an extra white/black matte OUTSIDE that clipped shape,
                                   // which for a perfectly square 1024x1024 source is a no-op in
                                   // practice but is the correct default regardless.
  });
  const rendered = resvg.render();
  const png = rendered.asPng();
  console.log(`  ${size}x${size}: ${png.length} bytes`);
  return png;
});

mkdirSync(outDir, { recursive: true });

console.log("Assembling .ico container...");
const icoBuffer = await pngToIco(pngBuffers);
writeFileSync(outIco, icoBuffer);
console.log(`Wrote ${outIco} (${icoBuffer.length} bytes, sizes: ${sizes.join(", ")})`);
