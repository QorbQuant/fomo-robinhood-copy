# rh-copybot

Watches a list of wallets on **Robinhood Chain** and copies their new-token buys
with USDG. One Python process per instance, one stateless router contract, no database.

```
watched wallet swaps into a token it did not hold
        │  (ERC-20 Transfer logs, all wallets in one eth_getLogs pair, ~0.5s poll)
        ▼
gates: stock/stable · plant · pool age · fake LP · sell ratio · honeypot ratio
       · holder probe · Relay payer · route + quote        (see "The gates" below)
        ▼
bot buys `buy_usd` of USDG worth via CopyRouter (Uniswap V3 / V4 legs, hooked pools ok)
        │
        ├─ +5m   sell 75%
        ├─ +10m  sell 25%
        └─ the ORIGINATING wallet starts selling → sell whatever is left
```

Exit timing is measured, not guessed: price paths rebuilt from pool swap events peak
around 5–7 minutes after the fill (mean 1.36x at 5 min, 1.45x at 7 min, 1.14x at 1 hour,
0.64x at 24 hours). `backtest.py` re-scores every schedule against real paths.

## Setup

```bash
pip install -r requirements.txt
cp .env.example .env          # PRIVATE_KEY of a fresh hot wallet (+ optional RPC_URL)
```

1. Put the wallets to copy in `wallets.json` (`{"address": "0x…", "label": "name"}`).
   Any count works; 108 wallets is the same RPC load as 1.
2. `solana.json` maps each watched EVM wallet to its paired Solana wallet
   (`{"0xevm…": "SolanaAddr…"}`). The Relay check needs it; without an entry for a
   wallet that check falls back to the weaker referrer-only test.
3. **Paper first.** A paper instance is a copy of this folder with `"live": false`
   and `"paper_cash_usd"` set:
   ```bash
   python bot.py
   ```
   Every detected buy is logged to `data/signals.jsonl` with the outcome
   (bought / why skipped) and every gate value it saw. Paper positions use real
   on-chain quotes.
4. Go live:
   - fund the hot wallet with USDG and ETH for gas (0.05 ETH ≈ 165 transactions)
   - deploy the router once (needs [Foundry](https://getfoundry.sh)):
     ```bash
     ./deploy.sh
     ```
     paste the printed `Deployed to:` address into `config.json` → `"router"`
   - set `"live": true` and run `python bot.py` again. The first run sends one
     USDG approval; every buy pre-approves its token so exits are one tx.

## Tools

| command | what it does |
|---|---|
| `python bot.py` | the bot itself |
| `python bot.py status` | open/closed positions and PnL |
| `python bot.py route <token>` | dry-run routing, quotes, price impact and the holder-probe verdict |
| `python bot.py payer <txhash>` | Relay's record for a fill and whether it was the trader's own buy |
| `python bot.py holdings <wallet>` | what a watched wallet holds |
| `python bot.py sell <symbol> [pct]` | hand a sell to the running bot via `data/commands/` |
| `python bot.py adopt <token> <usd> [ts]` | take an orphaned bag into the books |
| `python dash.py` | full-screen dashboard of all instances, refreshes every 15s (`--once` for one snapshot) |
| `python stats.py` | exit timing, follower flow, wallet leaderboard, latency (`--live`/`--paper`/`--paper-b`, `--hours N`, `--refresh`) |
| `python backtest.py` | scores every 1-, 2- and 3-tranche exit schedule over rebuilt price paths (`--hours N`, `HORIZONS=1,2,3,5,10`) |
| `python notify.py` | Telegram notifier, a separate process (see below) |

Dashboard keys: up/down pick a position, `o` opens it on dexscreener, `f` opens the
origin wallet's fomo profile, `s` sells it (confirm with `y`; the request is handed to
the bot via `data/commands/`, which executes it on its next tick), `r` refreshes, `q` quits.

The Telegram notifier never touches the bot's hot path: it follows the journal and state
files and relays BUY / SELL / closed / ALERT lines, so a slow or dead Telegram cannot cost
the bot a millisecond. Commands: `/status /open /closed /stats /logs /skips on|off`,
and `/sell SYMBOL` then `/confirm`. Put `TELEGRAM_BOT_TOKEN` in `.env`, start the
service, and send the bot `/start <code>` with the pairing code from its log. Only that
chat is ever answered.

## Config knobs (`config.json`)

Sizing and exits:

| key | live value | meaning |
|---|---|---|
| `buy_usd` | 100 | USDG per signal (one position per token, whichever wallet buys first) |
| `max_positions` | 20 | cap on concurrent open positions (paper runs 1000) |
| `exits` | 75% @5m, 25% @10m | timed tranches; anything left waits for the origin wallet |
| `reentry_cooldown_hours` | 24 | don't re-buy a token closed within this window |
| `paper_cash_usd` | — | paper only: starting bankroll (`live: false`) |

Entry gates:

| key | live value | meaning |
|---|---|---|
| `min_liquidity_usd` | 10000 | skip tokens with a shallower deepest pool |
| `thin_liquidity_usd` / `thin_min_sells_24h` | 50000 / 5 | below this liquidity, require this many sells by others in 24h |
| `min_origin_usd` | 50 | ignore dust buys by the watched wallet |
| `max_price_impact_pct` | 10 | skip if our fill would be this far above market |
| `max_round_trip_loss_pct` | 15 | skip if buying then selling straight back would lose more (thin pool / tax token) |
| `max_signal_age_s` | 120 | never chase a buy older than this (e.g. after a restart) |
| `skip_stock_tokens` | true | ignore Robinhood tokenized stocks/ETFs (on-chain name ends "• Robinhood Token") |
| `exclude_tokens` | [] | extra symbols or addresses never to copy |
| `min_pool_age_minutes` | 2 | skip pools younger than this (was 5 until plants were separated out) |
| `fresh_pool_minutes` / `fresh_pool_max_liquidity_usd` | 30 / 500000 | a pool this young showing this much liquidity is fake LP |
| `fake_lp_min_buys24` | 100 | more than `fresh_pool_max_liquidity_usd` of liquidity with fewer buys than this in 24h is fake LP **at any age** |
| `young_pool_minutes` / `young_pool_min_sell_ratio` | 60 / 0.25 | in a pool this young, require sells to be this fraction of buys (with ≥5 buys) |
| `honeypot_check` | true | skip tokens with many buys and ~no sells on dexscreener |
| `ratio_gate_min_buys` / `ratio_gate_min_sell_ratio` | 30 / 0.15 | with this many buys, require this sell ratio at any age |
| `plant_gate` | true | skip buys that carry attached ETH (bait paid by the operator, not a fomo fill) |
| `quarantine_window_hours` / `quarantine_min_rugs` / `quarantine_rug_rate` | 48 / 3 / 0.5 | hold back a wallet's **young-pool** signals when that many of its recent young-pool buys rugged; its mature-token buys keep flowing |
| `holder_probe` | true | ask the chain whether the token's last buyers can still move it (see below) |
| `holder_probe_count` / `holder_probe_min_age_s` | 8 / 30 | how many recent buyers to test, ignoring ones younger than this (the blocker has not reached them yet) |
| `holder_probe_min_trapped` | 2 | skip when this many probed holders are blocked (or one is and none is free) |
| `holder_probe_lookback_blocks` | 6000 | how far back to look for buyers (falls back to 1500 on busy tokens, 30000 when few are found) |
| `holder_probe_wait_s` | 1.0 | how long to wait for the probe after routing before buying without it |
| `holder_probe_pool_counts` | false | also count holders who can transfer but cannot sell into the pool |
| `bytecode_blocklist` | [0x109b1bd8…] | skip tokens whose bytecode carries one of these constants (the PEZ/MEGADUCK honeypot build) |
| `relay_gate` | true | require the origin buy to be the trader's own fomo buy (see below) |
| `relay_wait_s` / `relay_watch_s` | 2.5 / 300 | how long to wait for Relay before buying, and how long after a fill an unknown one is re-checked |
| `relay_unknown` | buy | `buy` or `skip` when Relay has not answered in time |
| (built in) | | a token that ever rugged us is never bought again, cooldown or not |

Execution and exits:

| key | live value | meaning |
|---|---|---|
| `slippage_pct` | 3 | minOut bound vs the on-chain quote when buying |
| `requote_on_slippage` | true | when a buy reverts with "slippage", re-quote once and retry if still within the impact cap |
| `sell_slippage_pct` | 6 | starting minOut bound when selling; widens ×1.5 per failure up to `sell_slippage_max_pct` (25) |
| `sell_retry_seconds` | 300 | base back-off between failed sell attempts |
| `min_gas_eth` / `critical_gas_eth` | 0.003 / 0.0008 | stop buying below the first (gas is reserved for exits), alert below the second |
| `unsellable_failures` / `unsellable_hours` | 12 / 3 | write a position off after this many failures over this long |
| `blocked_write_off_hours` | 6 | write off a position whose token explicitly blocks selling |
| `dead_pool_liquidity_usd` | 100 | below this the pool counts as drained and the bag is written off |
| `dust_write_off_usd` | 10 | after 5 failures, write off a remainder worth less than this |
| `native_eth_routes` | true | allow native-ETH V4 pools and ETH intermediates in routes |

Infrastructure:

| key | live value | meaning |
|---|---|---|
| `live` | true | false = paper: real quotes, simulated fills, nothing is sent |
| `router` | 0xc33046f9… | deployed CopyRouter address (paper instances leave it empty) |
| `rpc` / `fallback_rpc` | public RPC | primary and fallback endpoints (`RPC_URL` in `.env` overrides the primary) |
| `poll_seconds` / `fallback_poll_seconds` | 0.5 / 3 | poll interval on the primary and while failed over |
| `rpc_batching` | true | one HTTP request per poll tick instead of one per call |
| `log_chunk_blocks` / `log_chunk_blocks_open` | 10 / 300 | getLogs window on a capped provider (Alchemy) and on the public node |
| `max_catchup_blocks` | 3000 | after a restart, how far back to sweep |
| `ws` / `ws_backstop_seconds` / `ws_stale_seconds` | false / 20 / 90 | websocket detection with an HTTP backstop sweep; on for the paper bots |
| `ws_url` | — | override the websocket endpoint (defaults to the wss form of `rpc`) |
| `heartbeat_seconds` | 120 | `[beat]` line with head lag, open positions and gas |
| `holdings_scan_blocks` | 3000000 | how far back `bot.py holdings` scans |
| `require_fomo_payer` | false | legacy strict-router mode, superseded by `relay_gate`; leave off |

## What counts as a signal

- **Buy**: a watched wallet *receives* a non-stable token in a tx where it also
  sent something (a swap) or the sender is a contract (one-sided router fill),
  **and** its balance of that token one block earlier was zero. Adding to an
  existing bag is not a signal. Plain wallet-to-wallet transfers and airdrops
  from EOAs are ignored.
- **Origin exit**: the wallet that triggered the position *sends* that token
  into a swap or contract. Any amount counts as "starting to exit".

## The gates

In order, cheapest first. Every decision and every value behind it is written to
`data/signals.jsonl`, so the gates can be re-tuned from recorded data rather than memory.

1. already holding it / excluded / Robinhood stock token / re-entry cooldown / **ever rugged us**
2. the wallet's balance one block earlier was not zero (this is an add, not an entry)
3. **plant gate**: the origin tx carries ETH, so the operator paid for it, not fomo
4. signal age, max positions, dexscreener price, origin buy size, liquidity
5. **pool age**, fake-LP rules (fresh-and-rich, or rich-with-no-trades at any age)
6. **young-pool quarantine** for wallets whose recent snipes rugged
7. sell-ratio gates (young pools, and the 30-buy ratio gate at any age)
8. thin-pool rule: below `thin_liquidity_usd`, other people must have sold recently
9. route discovery and quote check (price impact, round trip)
10. **holder probe** and **bytecode fingerprint**, in a thread beside routing
11. **Relay check**: was this the trader's own fomo buy?
12. paper cash / gas reserve / USDG balance, then buy

## Blacklist honeypots and the holder probe

The "Blocked: cannot sell" family (PEZ, PENZ, PEZZED, PEZZEL, ZEP, MEGADUCK, RIP) is a
token whose owner runs a bot that blacklists every buyer within about a minute of their
buy, while the operator's own wallets keep selling so the chart shows sells. A sell
simulation at buy time passes (we are not on the list yet) and the +5 min sell reverts.
What is visible at buy time is the *previous* buyers: at the moment of every one of
those signals, the holders who had bought 30 s or more earlier were already blocked.
So the bot fetches the token's last few buyers (one address-indexed log query on the
public node), drops the ones that are contracts (arb bots buy every launch and anti-bot
tokens reject them), asks the chain in one batched call whether each can still transfer
1 wei to the pool and to a plain address, and skips the buy when they cannot. The signal
wallet, which bought seconds ago, is probed too: if it fails in the same way with a
bare custom error, the token simply forbids direct transfers (a token-wide rule, sells
through the router still work) and the probe stays quiet. It runs in a thread alongside
route discovery, so it adds no latency. `python bot.py route <token>` prints the verdict.

Every token in that family so far also shares one ~8.7KB contract build carrying the
constant in `bytecode_blocklist`, seen in 7 of 7 of them and in 0 of the other 603 tokens
the bots have traded. One `eth_getCode`, free, in the same thread. Operators can rebuild
without it, so the holder probe is the real defence and this is the cheap second layer.

## Planted buys and the Relay check

fomo funds its Robinhood Chain wallets through Relay (relay.link). A fomo buy is a Relay
request "take my USDC on Solana, deliver token X to my wallet"; Relay's solver keys submit
it and Relay's router settles it. Relay lets any user name any recipient, so a scammer can
buy their own coin *into* a famous wallet, and the transaction is byte-identical to the
whale buying it.

Relay's public index records each request, but `user`, `depositor` and `referrer` are all
parameters of the quote request: in the gateway flow the solver makes the deposit itself
and the requester writes any address it likes, which is how ZDOG, ENCRYPTED and HUH showed
up as "paid by" the traders' own wallets. The one thing a third party cannot write is a
Solana-origin deposit, because it has to be signed by the depositor. So a fill counts as
the trader's own only when **all three** hold: the request was the fomo app's
(`referrer: "fomo"`), the deposit came in on Solana, and the depositor is that wallet's
paired Solana wallet from `solana.json`. Anything else with a Relay record is planted.

Across the bots' history 806 of 808 genuine fomo-app fills pass this rule (the two misses
were a trader's second Solana wallet and one on-chain-origin deposit, −$3 between them),
while the other 39 Relay fills held 32 rugs and −$2.9K. Separating plants out also changed
the pool-age picture: once they are removed, fomo fills into 2–5 minute pools were 83
trades with 3 rugs and +$1.5K, which is why `min_pool_age_minutes` came down from 5 to 2.

The check runs in a thread next to routing. Relay does not always answer within the buy
window, so an unknown fill is bought and re-checked for `relay_watch_s`; if it comes back
planted the whole position is sold at once, before the pool is pulled. Fills that never
appear in Relay (other routers) are left alone. `python bot.py payer <txhash>` prints the
record and the verdict.

## Exits and failure handling

Timed tranches fire on `exits`, then anything left waits for the origin wallet to start
selling. If the schedule already adds to 100% and a remainder is still held (e.g. the
schedule changed while the position was open), it is sold instead of waiting.

Sells are defended in depth because most of what goes wrong goes wrong here: adaptive
slippage on each retry, a fresh quote when the stored route gets worse, reconciliation
against the chain before every retry (a "failed" sell may have landed and the response
was lost), local nonce and pre-computed tx hashes so a dropped receipt is recoverable,
and a ladder of write-offs — explicit sell blocks, drained pools, dust remainders, and
finally anything still failing after `unsellable_failures` attempts over `unsellable_hours`.

## Files

- `bot.py` — everything: watcher, routing, execution, exits, gates, CLI
- `dash.py`, `stats.py`, `backtest.py`, `notify.py` — dashboard, analytics, schedule backtest, Telegram
- `wallets.json` — wallets to copy; `solana.json` — their paired Solana wallets
- `contracts/src/CopyRouter.sol` — stateless swap executor (route passed per call)
- `deploy/` — `push.sh`, `setup.sh`, `remote.sh` and the four systemd units
- `data/state.json` — open/closed positions; `data/trades.jsonl`, `data/signals.jsonl`,
  `data/rpc_events.jsonl`, `data/commands/`

## Speed

Signal to fill runs about 1 second on the droplet: ~0.7s to detect, ~0.4s to route and
quote, ~0.1s to send, and the fill lands in the same block the sequencer is already
building. You always fill after the wallet you copy; there is no mempool on this chain,
so there is no way to be earlier.

The public RPC handles roughly one batched tick per second and answers address-indexed
`getLogs` from block 0 instantly. With an Alchemy key set
`RPC_URL=https://robinhood-mainnet.g.alchemy.com/v2/<KEY>` in `.env`; note the free and
PAYG tiers cap `eth_getLogs` at 10 blocks, which is what `log_chunk_blocks` is for. The
bot fails over to `fallback_rpc` after three consecutive primary errors and backs off
1 → 5 → 15 minutes if the primary keeps flapping; every such event lands in
`data/rpc_events.jsonl`. Websocket detection (`ws: true`) stayed up through provider HTTP
outages and is on for the paper bots.

## Running on a server (DigitalOcean droplet)

Three bots run side by side: `rh-copybot` (live), `rh-copybot-paper` (same wallet list,
paper bankroll) and `rh-copybot-paper2` (a separate cohort in its own `wallets.json`),
plus `rh-copybot-notify` for Telegram. 1GB of RAM and a swapfile is enough; 512MB will
thrash during pip installs.

1. Create an Ubuntu droplet with your SSH key.
2. **Stop any bot on your laptop** (Ctrl+C). Two copies must never trade with the same wallet.
3. From the laptop: `./deploy/push.sh root@DROPLET_IP` — copies the folders and installs
   the systemd units. It refuses to push if a laptop bot is running or if `bot.py` does
   not even import.
4. `ssh root@DROPLET_IP 'systemctl start rh-copybot rh-copybot-paper rh-copybot-paper2'`

**The droplet's `data/` and `.env` are the live truth.** They are seeded only on the first
push and excluded from every push after that, so positions, logs and keys are never
overwritten by a code update. Back them up from the droplet, not from the laptop.

`./deploy/remote.sh` wraps the usual jobs from the laptop: `logs`, `paperlogs`,
`paper2logs`, `notifylogs`, `dash`, `status`, `stats`, `restart`, `push`, `sell SYM`,
`adopt TOKEN USD`, `notify` (restart the notifier and print its pairing code).
On the droplet itself, `journalctl -fu rh-copybot` follows the live log and
`cd /opt/rh-copybot && .venv/bin/python dash.py` opens the dashboard (best inside `tmux`).

## Caveats

- You always fill *after* the wallet you copy. On thin pools that gap is real.
- The hot wallet key in `.env` controls the funds. Use a throwaway wallet.
- dexscreener lags on brand-new pools, and its `pairCreatedAt` is gameable: scammers
  pre-create pools days early. Liquidity against trading activity is the reliable tell.
- Every gate here was added after something cost money. Re-check them against
  `data/signals.jsonl` rather than trusting the numbers in this file forever.
- Unaudited prototype. Paper-trade it before it touches money.
