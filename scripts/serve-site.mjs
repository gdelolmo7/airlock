// Dev preview for website/ — static files, no build step, no dependencies.
//   node scripts/serve-site.mjs [port]
// Resolves its own location, so it does not care what the working directory is.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { extname, join, normalize, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// `../..`, not `..`: the site left this repo when it split into app/ and
// website/, so it is now a SIBLING of this one. Pointed inside app/ it served
// nothing — every request 404'd, which reads as a broken page rather than a
// misaimed server, so say so instead.
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', 'website');
const PORT = Number(process.argv[2] ?? 4173);

if (!existsSync(ROOT)) {
  console.error(`✗ no website/ at ${ROOT} — it is a sibling of this repo, not a folder inside it.`);
  process.exit(1);
}

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.json': 'application/json',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.woff2': 'font/woff2',
  '.xml': 'application/xml; charset=utf-8', '.txt': 'text/plain; charset=utf-8',
  '.dmg': 'application/x-apple-diskimage',
};

createServer(async (req, res) => {
  let path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  if (path.endsWith('/')) path += 'index.html';
  const file = join(ROOT, normalize(path).replace(/^(\.\.[/\\])+/, ''));
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end(`404 ${path}\n`);
  }
}).listen(PORT, () => console.log(`website/ on http://localhost:${PORT}`));
