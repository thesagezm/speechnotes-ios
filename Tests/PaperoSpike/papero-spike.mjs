// Proves the VENDORED papero engine still works, in CI, before a device ever
// runs it. The app serves these exact files to a hidden WKWebView; if the
// vendoring drifts (a CDN import creeping back in, pdf.js moved, a path
// changed) the failure belongs here, not on the phone.
//
// Run with: node papero-spike.mjs <pdf>   (Node 22+; 20 needs the shim below)

if (!Promise.withResolvers) {
  // Safari 17.4 / iOS 18 has this; the CI runner's node may not.
  Promise.withResolvers = function () {
    let resolve, reject;
    const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
    return { promise, resolve, reject };
  };
}

import { readFile } from "node:fs/promises";
import { extractDocument, SCHEMA } from "../../App/Resources/papero/engine.js";

const path = process.argv[2];
if (!path) { console.error("PAPERO-SPIKE usage: node papero-spike.mjs <pdf>"); process.exit(2); }

const bytes = new Uint8Array(await readFile(path));
const { doc } = await extractDocument(bytes, { pages: "1-4" });

// The same markdown mapping the extractor shell does.
const FURNITURE = new Set(["header", "footer", "page_number"]);
const out = [];
for (const page of doc.pages ?? []) {
  for (const block of page.blocks ?? []) {
    if (FURNITURE.has(block.type)) continue;
    if (block.text?.trim()) out.push(block.text.trim());
  }
}
const text = out.join("\n\n");

const checks = [
  ["schema is papero's", doc.schema === SCHEMA],
  ["engine is pdf.js", doc.engine === "pdf.js"],
  ["a page count came back", (doc.page_count ?? 0) > 0],
  ["blocks were classified", (doc.pages?.length ?? 0) > 0],
  ["text was produced", text.length > 200],
  ["text is not just furniture", new Set(out).size > 3],
];
let failed = 0;
for (const [name, ok] of checks) {
  console.log(`PAPERO-SPIKE ${ok ? "PASS" : "FAIL"}: ${name}`);
  if (!ok) failed++;
}
console.log(`PAPERO-SPIKE pages=${doc.page_count} extracted=${doc.pages_extracted} chars=${text.length} scanned=${doc.likely_scanned}`);
console.log(`PAPERO-SPIKE sample: ${text.slice(0, 180).replace(/\n/g, " ⏎ ")}`);
process.exit(failed === 0 ? 0 : 1);
