// /api/fn/board?symbols=^GSPC,GC=F,EURUSD=X : last price, day change, YTD and 52-week range for a list of
// Yahoo symbols, from Yahoo's public spark endpoint (one request per 20 symbols, no key). Powers WEI, GLCO, FXC.
import { getJson, cached, YAHOO_UA as UA, samePrint } from "../providers.js";
import { yahooSession, resetYahooSession } from "./des.js";

// Minutes Yahoo says a price runs behind the market (0 when live). Yahoo gives US stocks 15, but quotes them from
// Nasdaq's real-time feed and says so in quoteSourceName, so those count as live.
export const delayOf = (q) =>
  q?.exchangeDataDelayedBy > 0 && !/real ?time/i.test(q.quoteSourceName || "")
    ? q.exchangeDataDelayedBy
    : 0;

// Yahoo's own quote per symbol: its price, the time of that price and the delay it states (needs the session crumb).
export async function yahooQuotes(symbols, ttl = 30e3) {
  const out = {};
  const list = [...new Set(symbols)];
  for (let i = 0; i < list.length; i += 50) {
    const part = list.slice(i, i + 50);
    const j = await cached(`yquote:${ttl}:${part.join(",")}`, ttl, async () => {
      const s = await yahooSession();
      return getJson(
        `https://query1.finance.yahoo.com/v7/finance/quote?symbols=${encodeURIComponent(part.join(","))}&crumb=${encodeURIComponent(s.crumb)}`,
        { ...UA, Cookie: s.cookie },
      ).catch((e) => {
        if (e.status === 401) resetYahooSession();
        throw e;
      });
    });
    for (const q of j?.quoteResponse?.result || [])
      out[q.symbol] = {
        price: q.regularMarketPrice,
        asOf: q.regularMarketTime ?? null,
        delayMin: delayOf(q),
      };
  }
  return out;
}

// What a screen needs to label a delayed price: the delay, and the time only when Yahoo's quote is at that price.
export const stamp = (price, q) =>
  q ? { delayMin: q.delayMin, asOf: samePrint(q.price, price) ? q.asOf : null } : {};

export function rowFrom(sym, v) {
  const closes = (v.close || []).map(Number);
  const times = v.timestamp || [];
  const valid = closes
    .map((c, i) => [times[i], c])
    .filter(([, c]) => Number.isFinite(c) && c > 0);
  const price = Number.isFinite(v.fulldayPrice)
    ? v.fulldayPrice
    : valid.at(-1)?.[1];
  const prev = Number.isFinite(v.previousClose)
    ? v.previousClose
    : valid.at(-2)?.[1];
  const year = new Date().getUTCFullYear();
  const jan = valid
    .filter(([t]) => new Date(t * 1000).getUTCFullYear() < year)
    .at(-1)?.[1];
  const highs = valid.map(([, c]) => c);
  return {
    symbol: sym,
    price,
    change: Number.isFinite(v.fulldayChange) ? v.fulldayChange : price - prev,
    changePct: Number.isFinite(v.fulldayChangePercent)
      ? v.fulldayChangePercent
      : ((price - prev) / prev) * 100,
    ytdPct: jan ? ((price - jan) / jan) * 100 : null,
    high52: highs.length ? Math.max(...highs) : null,
    low52: highs.length ? Math.min(...highs) : null,
    spark: valid.slice(-30).map(([, c]) => c),
    time: times.at(-1) || null,
  };
}

export async function board(symbols, ttl = 30e3) {
  const list = [...new Set(symbols)].slice(0, 120);
  const out = {};
  const times = yahooQuotes(list, ttl).catch(() => ({}));
  for (let i = 0; i < list.length; i += 20) {
    const part = list.slice(i, i + 20);
    const path = `/v8/finance/spark?symbols=${encodeURIComponent(part.join(","))}&range=1y&interval=1d`;
    // query1 and query2 rate-limit separately, so a 429 on one is often fine on the other.
    const d = await cached(`spark:${ttl}:${part.join(",")}`, ttl, () =>
      getJson(`https://query1.finance.yahoo.com${path}`, UA).catch(() => getJson(`https://query2.finance.yahoo.com${path}`, UA)),
    );
    for (const [k, v] of Object.entries(d || {})) out[k] = rowFrom(k, v);
  }
  const q = await times;
  for (const [k, r] of Object.entries(out)) Object.assign(r, stamp(r.price, q[k]));
  return out;
}

export default async function (q) {
  const symbols = String(q.symbols || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (!symbols.length)
    throw Object.assign(new Error("Send ?symbols=^GSPC,GC=F"), { status: 400 });
  return {
    source:
      "Yahoo Finance (public, prices can be delayed up to 15 minutes for some exchanges)",
    // LIVE on WEI/GLCO asks every 5 seconds, so it gets a 5-second cache.
    rows: await board(symbols, q.live ? 5e3 : 30e3),
  };
}
