#!/usr/bin/env node
// Amber Terminal server. Node 18+ and nothing else: no npm install, no build step.
//   node server.js            start on http://localhost:3787 (or the next free port)
//   node server.js --open     start and open your browser
//   PORT=4000 node server.js  pick a port

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawn } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import * as data from "./lib/providers.js";
import * as feeds from "./lib/feeds.js";
import * as alerts from "./lib/alerts.js";
import * as store from "./lib/store.js";
import * as info from "./lib/market-info.js";
import * as bbg from "./lib/bloomberg-fields.js";
import { yahooQuotes } from "./lib/fn/board.js";
import { relaunchForProxy, proxyNote } from "./lib/proxy.js";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(ROOT, "public");
const VERSION = JSON.parse(
  fs.readFileSync(path.join(ROOT, "package.json"), "utf8"),
).version;
// Only AMBER_HOST opens the terminal to your network (with no login), so a HOST variable some
// other tool exports can't do it by accident.
const HOST = process.env.AMBER_HOST || "127.0.0.1";
const START_PORT = Number(process.env.PORT) || 3787;

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
};

// ---------- helpers ----------
const httpError = (status, message) => Object.assign(new Error(message), { status });

// The page may run only its own script files and talk only to this server, so markup that slips
// into a screen can't run code. Inline styles stay allowed because the screens build style attributes.
const PAGE_CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "connect-src 'self'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join("; ");

function send(res, status, body, headers = {}) {
  const isStr = typeof body === "string" || Buffer.isBuffer(body);
  res.writeHead(status, {
    "Content-Type": isStr ? "text/plain; charset=utf-8" : "application/json",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    ...headers,
  });
  res.end(isStr ? body : JSON.stringify(body));
}

async function readBody(req, limit = 2e6) {
  let size = 0;
  const chunks = [];
  for await (const c of req) {
    size += c.length;
    if (size > limit)
      throw Object.assign(new Error("Request too large"), { status: 413 });
    chunks.push(c);
  }
  const text = Buffer.concat(chunks).toString("utf8");
  if (!text) return {};
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    throw httpError(400, "The request body isn't valid JSON");
  }
  if (!body || typeof body !== "object" || Array.isArray(body))
    throw httpError(400, "The request body must be a JSON object");
  return body;
}

// The server only answers to this machine's browser. Writes need a custom header, which a random
// website can't add to a cross-site request, so other pages can't drive your terminal.
function allowed(req) {
  const host = (req.headers.host || "")
    .replace(/:\d+$/, "")
    .replace(/^\[|\]$/g, "");
  const okHosts = new Set(["localhost", "127.0.0.1", "::1", ...lanAddresses()]);
  if (!okHosts.has(host)) return false;
  // Browsers say where a request comes from. Another site may link to the terminal's page (a
  // navigation it can't read), but its pages can't call the API. Excel, pandas and scripts send no
  // such header; nor do older browsers or LAN addresses, so routes with side effects also need the
  // app header (see handle()).
  const site = req.headers["sec-fetch-site"];
  const pageVisit =
    (req.method === "GET" || req.method === "HEAD") &&
    req.headers["sec-fetch-mode"] === "navigate" &&
    req.headers["sec-fetch-dest"] === "document" &&
    !req.url.startsWith("/api/");
  if (site && site !== "same-origin" && site !== "none" && !pageVisit) return false;
  if (req.method !== "GET" && req.method !== "HEAD") {
    if (req.headers["x-qt"] !== "1") return false;
    const origin = req.headers.origin;
    if (origin) {
      try {
        if (new URL(origin).host !== req.headers.host) return false;
      } catch {
        return false; // "null" and other opaque origins
      }
    }
  }
  return true;
}

function lanAddresses() {
  if (HOST === "127.0.0.1" || HOST === "localhost") return [];
  return Object.values(os.networkInterfaces())
    .flat()
    .filter(Boolean)
    .map((i) => i.address);
}

function serveStatic(res, baseDir, rel) {
  const file = path.normalize(path.join(baseDir, rel));
  if (!file.startsWith(baseDir + path.sep)) return send(res, 403, "Forbidden");
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) return send(res, 404, "Not found");
    const ext = path.extname(file);
    res.writeHead(200, {
      "Content-Type": MIME[ext] || "application/octet-stream",
      "Cache-Control": rel.startsWith("vendor/")
        ? "public, max-age=86400"
        : "no-cache",
      "X-Content-Type-Options": "nosniff",
      ...(ext === ".html" ? { "Content-Security-Policy": PAGE_CSP, "X-Frame-Options": "DENY", "Referrer-Policy": "same-origin" } : {}),
    });
    fs.createReadStream(file).pipe(res);
  });
}

// ---------- server-sent events (alerts pop up in the browser) ----------
const clients = new Set();
function broadcast(type, payload) {
  const msg = `event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`;
  for (const res of clients) res.write(msg);
}
alerts.onFire((e) => broadcast("alert", e));
setInterval(() => {
  for (const res of clients) res.write(": keep-alive\n\n");
}, 25000).unref();

// ---------- routes ----------
async function handle(req, res) {
  if (!allowed(req))
    return send(
      res,
      403,
      "Forbidden: Amber Terminal only answers to this computer.",
    );
  const url = new URL(req.url, "http://localhost");
  let p;
  try {
    p = decodeURIComponent(url.pathname);
  } catch {
    return send(res, 400, "Bad URL");
  }
  const q = Object.fromEntries(url.searchParams);

  if (!p.startsWith("/api/")) {
    if (p === "/" || p === "/index.html")
      return serveStatic(res, PUBLIC, "index.html");
    return serveStatic(res, PUBLIC, p.slice(1));
  }

  try {
    if (p === "/api/health") {
      return send(res, 200, {
        ok: true,
        app: "amber-terminal",
        root: ROOT,
        version: VERSION,
        node: process.version,
        platform: process.platform,
        providers: data.health,
        feeds: feeds.configured(),
        yahoo: data.yahooAvailable() ? "available" : "rate limited",
        alerts: alerts.list().filter((a) => a.active).length,
      });
    }
    // A backtest saves a snapshot and the probe calls your own data keys, so a link or an old browser
    // mustn't trigger them: they need the app's header, which another site can't send.
    if ((p === "/api/probe" || p === "/api/fn/btst") && req.headers["x-qt"] !== "1")
      throw httpError(403, "This one needs the header x-qt: 1 (the app sends it).");
    if (p === "/api/probe") return send(res, 200, await data.probeAll());
    if (p === "/api/resolve")
      return send(res, 200, await data.resolve(q.symbol));
    if (p === "/api/search") return send(res, 200, await data.search(q.q));
    if (p === "/api/spread") return send(res, 200, await data.getSpread(q.symbol));
    if (p === "/api/candles") {
      const c = await data.getCandles(q.symbol, q.tf || "1D", q.limit);
      // A Yahoo chart carries the delay Yahoo states for its symbol, so the screen can label the last price.
      const y = c.yahoo && (await yahooQuotes([c.yahoo], 10 * 60e3).catch(() => ({})))[c.yahoo];
      return send(res, 200, y ? { ...c, delayMin: y.delayMin } : c);
    }
    if (p === "/api/quotes")
      return send(
        res,
        200,
        await data.getQuotes(
          (q.symbols || "").split(",").filter(Boolean).slice(0, 200),
        ),
      );
    if (p === "/api/calendar")
      return send(res, 200, await data.economicCalendar());
    if (p === "/api/earnings") return send(res, 200, await info.earnings(Number(q.days) || 5));
    if (p === "/api/dividends") return send(res, 200, await info.dividends(Number(q.days) || 5));
    if (p === "/api/news") return send(res, 200, await info.news(q.symbol));
    if (p === "/api/financials") return send(res, 200, await info.financials(q.symbol, q.frequency));
    if (p === "/api/screener") {
      const u = q.universe || "crypto";
      const rows =
        u === "crypto"
          ? await data.cryptoScreener()
          : await data.nasdaqScreener(u === "etf" ? "etf" : "stocks");
      return send(res, 200, rows);
    }
    if (p === "/api/state") {
      if (req.method === "GET") return send(res, 200, store.read("state", {}));
      if (req.method === "PUT") {
        const patch = await readBody(req, 20e6);
        const next = { ...store.read("state", {}), ...patch };
        store.write("state", next);
        return send(res, 200, { ok: true });
      }
    }
    if (p === "/api/events") {
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "X-Content-Type-Options": "nosniff",
        Connection: "keep-alive",
      });
      res.write("retry: 3000\n\n");
      clients.add(res);
      req.on("close", () => clients.delete(res));
      return;
    }
    if (p === "/api/alerts") {
      if (req.method === "GET") return send(res, 200, alerts.list());
      if (req.method === "POST")
        return send(res, 200, alerts.add(await readBody(req)));
    }
    if (p === "/api/alerts/log") return send(res, 200, alerts.history());
    if (p === "/api/alerts/check" && req.method === "POST") {
      await alerts.evaluate();
      return send(res, 200, { ok: true });
    }
    if (p.startsWith("/api/alerts/")) {
      const id = p.split("/")[3];
      if (req.method === "DELETE") {
        alerts.remove(id);
        return send(res, 200, { ok: true });
      }
      if (req.method === "PATCH")
        return send(res, 200, alerts.update(id, await readBody(req)));
    }
    if (p === "/api/shutdown" && req.method === "POST") {
      // Lets the installer stop a running copy before updating it, on any OS.
      send(res, 200, { ok: true });
      setTimeout(() => process.exit(0), 100);
      return;
    }
    // Bloomberg's Excel functions as URLs, for Excel (Data > From Web), pandas.read_csv and scripts. Read-only GETs,
    // so no app header is needed; the server still only answers to this computer.
    if (p === "/api/about")
      return send(res, 200, {
        app: "amber-terminal",
        dir: ROOT,
        port: req.socket.localPort,
        version: VERSION,
        mcp: bbg.mcpCommand(ROOT),
        fields: { bdp: bbg.BDP_FIELDS, bdh: bbg.BDH_FIELDS },
      });
    if (p === "/api/bdp" || p === "/api/bdh") {
      const out = p === "/api/bdp" ? await bbg.bdp(q) : await bbg.bdh(q);
      if (String(q.format || "").toLowerCase() === "csv")
        return send(res, 200, bbg.csvOf(out), { "Content-Type": "text/csv; charset=utf-8" });
      return send(res, 200, out);
    }
    // Terminal functions: /api/fn/<name> runs lib/fn/<name>.js, one file per data source.
    const fm = /^\/api\/fn\/([a-z0-9-]{1,40})$/.exec(p);
    if (fm) {
      const mod = await loadFn(fm[1]);
      if (!mod) throw httpError(404, `No terminal function called ${fm[1]}`);
      return send(res, 200, await mod.default(q));
    }
    return send(res, 404, { error: "Unknown endpoint" });
  } catch (e) {
    // Upstream failures are a bad gateway, whatever status the provider used.
    const code = e.upstream ? 502 : e.status >= 400 && e.status < 600 ? e.status : 500;
    return send(res, code, { error: e.message });
  }
}

const fnCache = new Map();
async function loadFn(name) {
  if (!fnCache.has(name)) {
    const file = path.join(ROOT, "lib", "fn", `${name}.js`);
    if (!fs.existsSync(file)) return null;
    fnCache.set(name, await import(pathToFileURL(file).href));
  }
  return fnCache.get(name);
}

// ---------- start ----------
function openBrowser(url) {
  const cmd =
    process.platform === "win32"
      ? ["cmd", ["/c", "start", '""', url]]
      : process.platform === "darwin"
        ? ["open", [url]]
        : ["xdg-open", [url]];
  try {
    const child = spawn(cmd[0], cmd[1], { detached: true, stdio: "ignore" });
    child.on("error", () => {});
    child.unref();
  } catch {
    /* no desktop: the URL is printed anyway */
  }
}

export function start(port = START_PORT, tries = 20) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      handle(req, res).catch((e) => {
        if (!res.headersSent) send(res, 500, { error: e.message });
      });
    });
    server.once("error", (e) => {
      if (e.code === "EADDRINUSE" && tries > 0)
        resolve(start(port + 1, tries - 1));
      else reject(e);
    });
    server.listen(port, HOST, () => resolve({ server, port }));
  });
}

const isMain =
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
const relaunched = isMain ? relaunchForProxy() : null;
if (relaunched) process.exit(await relaunched);
if (isMain) {
  const { port } = await start();
  const url = `http://localhost:${port}`;
  alerts.start();
  console.log(
    `\n  Amber Terminal ${VERSION} is running\n\n  Open:  ${url}\n  Stop:  Ctrl+C\n  Data:  ${store.DATA_DIR}\n`,
  );
  if (proxyNote()) console.log(`  ${proxyNote()}\n`);
  if (HOST !== "127.0.0.1" && HOST !== "localhost")
    console.log(
      `  Also on your network: ${lanAddresses()
        .filter((a) => a.includes(".") && a !== "127.0.0.1")
        .map((a) => `http://${a}:${port}`)
        .join("  ")}\n`,
    );
  if (process.argv.includes("--open") || process.env.QT_OPEN === "1")
    openBrowser(url);
  const bye = () => {
    console.log("\n  Stopped.");
    process.exit(0);
  };
  process.on("SIGINT", bye);
  process.on("SIGTERM", bye);
}
