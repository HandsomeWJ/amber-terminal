// Delayed prices carry their as-at time: which sources count as delayed, which time goes with a price, and the
// "delayed, 14:32" label every screen and the ticker tape draw beside it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { delayOf, stamp } from "../lib/fn/board.js";
import { parseQuote } from "../lib/fn/bq.js";
import { parseCboe } from "../lib/fn/omon.js";
import { watchRows } from "../public/js/fn/workspace.js";
import { delayTag } from "../public/js/ui.js";

const fixture = (p) =>
  JSON.parse(readFileSync(new URL(`fixtures/${p}`, import.meta.url), "utf8"));

test("delayed means the delay Yahoo states, except US stocks it quotes from Nasdaq's real-time feed", () => {
  assert.equal(
    delayOf({ exchangeDataDelayedBy: 15, quoteSourceName: "Delayed Quote" }),
    15,
  );
  assert.equal(delayOf({ exchangeDataDelayedBy: 10 }), 10);
  assert.equal(
    delayOf({
      exchangeDataDelayedBy: 15,
      quoteSourceName: "Nasdaq Real Time Price",
    }),
    0,
  );
  assert.equal(
    delayOf({ exchangeDataDelayedBy: 0, quoteSourceName: "Delayed Quote" }),
    0,
  );
  assert.equal(delayOf(undefined), 0);
});

test("a price keeps Yahoo's time only when Yahoo's quote is at that same price", () => {
  const q = { price: 10733, asOf: 1792510529, delayMin: 15 };
  assert.deepEqual(stamp(10733, q), { delayMin: 15, asOf: 1792510529 });
  assert.deepEqual(stamp(10734.5, q), { delayMin: 15, asOf: null });
  assert.deepEqual(stamp(10733, undefined), {});
  // Yahoo's 32-bit floats: the same print written two ways still matches.
  assert.equal(stamp(5.117, { price: 5.1169996, asOf: 7, delayMin: 15 }).asOf, 7);
  assert.equal(stamp(98.18000030517578, { price: 98.18, asOf: 7, delayMin: 10 }).asOf, 7);
  assert.equal(stamp(2773.42, { price: 2773.4197, asOf: 7, delayMin: 15 }).asOf, 7);
  assert.equal(stamp(7712.57, { price: 7712.58, asOf: 7, delayMin: 15 }).asOf, null, "a real tick apart");
});

test("BQ: Vodafone in London is 15 minutes delayed, Apple's Nasdaq price is live", () => {
  const vod = parseQuote(
    fixture("coverage/yahoo-quotesummary-vod.json").quoteSummary.result[0],
  );
  assert.equal(vod.delayMin, 15);
  assert.equal(vod.last.time, 1792069872);
  const aapl = parseQuote(
    fixture("coverage/yahoo-quotesummary-aapl-bq.json").quoteSummary.result[0],
  );
  assert.equal(aapl.delayMin, 0);
});

test("OMON: the underlying's last trade, written in New York time by CBOE, becomes UTC", () => {
  const c = parseCboe(fixture("options/cboe-aapl.json"), "2026-10-15");
  assert.equal(c.priceTime, "2026-10-14T19:59:59.000Z"); // 15:59:59 in New York (EDT)
  assert.equal(c.delayMin, 15);
  assert.equal(
    c.asOf,
    "2026-10-15T12:16:51Z",
    "the file's own time is unchanged",
  );
});

test("W: a watchlist row carries its delay, and a live crypto price clears it", () => {
  const board = {
    "^FTSE": { price: 10733, delayMin: 15, asOf: 1792510529 },
    "BTC-USD": { price: 81000, delayMin: 0, asOf: 1 },
  };
  const quotes = { "BINANCE:BTCUSDT": { price: 82000, changePct: 1 } };
  const [ukx, btc] = watchRows(["UKX INDEX", "BTC CRYPTO"], board, quotes);
  assert.equal(ukx.delayMin, 15);
  assert.equal(ukx.asOf, 1792510529);
  assert.equal(btc.delayMin, 0);
});

test("the label: local time today, the date on another day, the stated delay with no time, nothing when live", () => {
  const today = new Date();
  today.setHours(14, 32, 0, 0);
  assert.match(
    delayTag({ delayMin: 15, asOf: today.getTime() / 1000 }),
    />delayed, 14:32</,
  );
  assert.match(
    delayTag({ delayMin: 15, asOf: today.toISOString() }),
    />delayed, 14:32</,
  );
  assert.match(
    delayTag({ delayMin: 10, asOf: new Date(2026, 0, 5, 9, 7).getTime() }),
    />delayed, 5 Jan 09:07</,
  );
  assert.match(delayTag({ delayMin: 15 }), />delayed 15 min</);
  assert.match(
    delayTag({ delayMin: 15, asOf: "not a time" }),
    />delayed 15 min</,
  );
  assert.match(
    delayTag({ delayMin: 15 }),
    /data-noexp/,
    "kept out of CSV exports",
  );
  assert.equal(delayTag({ delayMin: 0, asOf: 1792510529 }), "");
  assert.equal(delayTag({}), "");
  assert.equal(delayTag(null), "");
});
