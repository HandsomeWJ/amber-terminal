// /api/fn/gex?symbol=SPY&expiry=ALL : gamma exposure (GEX) of a US stock, ETF or index, from the same CBOE
// delayed option chain OMON shows (gamma and open interest for every contract, about 15 minutes behind).
// The usual dealer convention: dealers are long the calls and short the puts the public trades, so call gamma
// counts as positive and put gamma as negative. GEX per strike is gamma × open interest × 100 × spot² × 1%,
// the dollars of the underlying dealers would buy or sell for a 1% move.
import {
  cboeSymbol,
  loadChain,
  nyToday,
  pickExpiry,
  daysBetween,
} from "./omon.js";

const RANGE = 10; // strikes within 10% of spot by default
const PROFILE = 15; // the gamma profile runs from 15% below spot to 15% above
const STEPS = 120;
const fail = (message, status) => Object.assign(new Error(message), { status });
const fin = Number.isFinite;

// Dollar gamma for a 1% move: one contract's gamma × open interest × 100 shares × spot² × 0.01.
export const dollarGamma = (gamma, oi, spot) =>
  gamma * oi * 100 * spot * spot * 0.01;

// Per strike across the chosen expiries: call GEX (positive), put GEX (negative) and the net.
export function strikeGex(expiries, spot) {
  const by = new Map();
  for (const e of expiries)
    for (const r of e.rows) {
      const c =
        r.call?.gamma > 0 && r.call.oi > 0
          ? dollarGamma(r.call.gamma, r.call.oi, spot)
          : 0;
      const p =
        r.put?.gamma > 0 && r.put.oi > 0
          ? -dollarGamma(r.put.gamma, r.put.oi, spot)
          : 0;
      if (!c && !p) continue;
      const s = by.get(r.strike) || {
        strike: r.strike,
        call: 0,
        put: 0,
        net: 0,
      };
      s.call += c;
      s.put += p;
      s.net += c + p;
      by.set(r.strike, s);
    }
  return [...by.values()].sort((a, b) => a.strike - b.strike);
}

// Call wall: the strike with the most call GEX. Put wall: the most put GEX.
export function walls(strikes) {
  let call = null,
    put = null;
  for (const s of strikes) {
    if (s.call > 0 && (!call || s.call > call.call)) call = s;
    if (s.put < 0 && (!put || s.put < put.put)) put = s;
  }
  return { call: call?.strike ?? null, put: put?.strike ?? null };
}

// Black-Scholes gamma (no rates or dividends, close enough over a ±15% range).
export function bsGamma(spot, strike, years, iv) {
  if (!(spot > 0 && strike > 0 && years > 0 && iv > 0)) return 0;
  const v = iv * Math.sqrt(years);
  const d1 = (Math.log(spot / strike) + 0.5 * iv * iv * years) / v;
  return Math.exp(-0.5 * d1 * d1) / Math.sqrt(2 * Math.PI) / (spot * v);
}

// Net GEX re-priced at each spot from 15% below to 15% above, using each contract's IV. The gamma flip is
// where it crosses zero: above it dealers are long gamma (they sell rallies and buy dips, which damps moves),
// below it they're short gamma (they sell into falls and buy into rallies, which speeds moves up).
export function gammaProfile(
  expiries,
  spot,
  today,
  range = PROFILE,
  steps = STEPS,
) {
  const legs = [];
  for (const e of expiries) {
    // Contracts expire at 4pm New York; give same-day ones a quarter of a day so gamma stays finite.
    const years = Math.max(daysBetween(today, e.date), 0.25) / 365;
    for (const r of e.rows)
      for (const [q, sign] of [
        [r.call, 1],
        [r.put, -1],
      ])
        if (q?.oi > 0 && q.iv > 0 && q.iv < 5)
          legs.push({ k: r.strike, years, iv: q.iv, oi: q.oi, sign });
  }
  const points = [];
  for (let i = 0; i <= steps; i++) {
    const s = spot * (1 - range / 100 + (2 * range * i) / 100 / steps);
    let net = 0;
    for (const l of legs)
      net += l.sign * dollarGamma(bsGamma(s, l.k, l.years, l.iv), l.oi, s);
    points.push({ spot: s, net });
  }
  return points;
}

// The zero crossing nearest spot, by straight-line interpolation between profile points.
export function gammaFlip(points, spot) {
  let best = null;
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1],
      b = points[i];
    if (Math.sign(a.net) === Math.sign(b.net) || a.net === b.net) continue;
    const x = a.spot + ((b.spot - a.spot) * a.net) / (a.net - b.net);
    if (best == null || Math.abs(x - spot) < Math.abs(best - spot)) best = x;
  }
  return best;
}

export default async function (q) {
  const sym = cboeSymbol(q.symbol);
  if (!sym)
    throw fail(
      "GEX is for US stocks, ETFs and the main US indices (SPX, NDX, RUT). Try SPY, SPX or AAPL.",
      400,
    );
  const chain = await loadChain(sym);
  if (!/^CBOE/.test(chain.source))
    throw fail(
      "GEX needs CBOE's option greeks, and CBOE didn't answer just now. Try again in a minute.",
      502,
    );
  const today = nyToday();
  const all = chain.expiries.filter((e) => e.date >= today);
  if (!all.length)
    throw fail(`${sym.ticker} has no open option expiries right now.`, 404);
  const want = String(q.expiry ?? "")
    .trim()
    .toUpperCase();
  const one = want && want !== "ALL" ? pickExpiry(all, want) : null;
  const used = one == null ? all : [all[one]];
  const spot = chain.price;
  const strikes = strikeGex(used, spot);
  const range =
    fin(Number(q.range)) && Number(q.range) > 0 ? Number(q.range) : RANGE;
  const near = strikes.filter(
    (s) => Math.abs(s.strike / spot - 1) * 100 <= range,
  );
  const total = strikes.reduce(
    (t, s) => ((t.call += s.call), (t.put += s.put), (t.net += s.net), t),
    { call: 0, put: 0, net: 0 },
  );
  const profile = gammaProfile(used, spot, today);
  const flip = gammaFlip(profile, spot);
  return {
    symbol: sym.ticker,
    index: sym.index,
    price: spot,
    change: chain.change,
    changePct: chain.changePct,
    asOf: chain.asOf,
    priceTime: chain.priceTime,
    delayMin: chain.delayMin,
    expiries: all.map((e, n) => ({
      n: n + 1,
      date: e.date,
      root: e.root,
      days: daysBetween(today, e.date),
    })),
    expiry:
      one == null
        ? null
        : {
            n: one + 1,
            date: all[one].date,
            root: all[one].root,
            days: daysBetween(today, all[one].date),
          },
    total,
    walls: walls(strikes),
    flip,
    regime: total.net >= 0 ? "positive" : "negative",
    range,
    strikes: near,
    profile: profile.filter((_, i) => i % 4 === 0),
    method:
      "Dealers assumed long calls and short puts. GEX = gamma × open interest × 100 × spot² × 1%, in dollars per 1% move. The flip re-prices every contract's gamma at nearby spots with its own IV.",
    source: chain.source,
  };
}
