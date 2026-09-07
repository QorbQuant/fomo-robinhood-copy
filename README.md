# rh-copybot

Watches a list of wallets on **Robinhood Chain** and copies their new-token buys
with USDG. One Python process, one stateless router contract, no database.

```
watched wallet swaps into a token it did not hold
        │  (ERC-20 Transfer logs, all wallets in one eth_getLogs pair, ~1s poll)
        ▼
bot buys `buy_usd` of USDG worth via CopyRouter (Uniswap V3 / V4 legs, hooked pools ok)
        │
        ├─ +1h   sell 50%
        ├─ +24h  sell 25%
        └─ the ORIGINATING wallet starts selling → sell the rest
```

## Setup

```bash
pip install -r requirements.txt
cp .env.example .env          # PRIVATE_KEY of a fresh hot wallet (+ optional RPC_URL)
```

1. Put the wallets to copy in `wallets.json` (`{"address": "0x…", "label": "name"}`).
   Any count works; 50 wallets is the same RPC load as 1.
2. **Paper first.** `config.json` ships with `"live": false`:
   ```bash
   python bot.py
   ```
   Every detected buy is logged to `data/signals.jsonl` with the outcome
   (bought / why skipped). Paper positions use real on-chain quotes.
3. Go live:
   - fund the hot wallet with USDG and a little ETH for gas (~0.005 ETH is plenty)
   - deploy the router once (needs [Foundry](https://getfoundry.sh)):
     ```bash
     ./deploy.sh
     ```
     paste the printed `Deployed to:` address into `config.json` → `"router"`
   - set `"live": true` and run `python bot.py` again. The first run sends one
     USDG approval; every buy pre-approves its token so exits are one tx.

`python dash.py` opens a full-screen dashboard of the live and paper bots (auto-refresh).
Keys: up/down pick a position, `o` opens it on dexscreener, `f` opens the origin wallet's fomo profile, `s` sells it (confirm with `y`;
the request is handed to the bot via `data/commands/`, which executes it on its next tick), `q` quits.
`python stats.py` prints the analytics report: exit timing (return if sold N minutes after entry,
rebuilt from pool swap events), follower flow among watched wallets, wallet leaderboard, latency.
`python bot.py status` shows open/closed positions and PnL.
`python bot.py route <token>` dry-runs routing + quotes for any token.
`python bot.py holdings <wallet>` lists what a watched wallet holds.

## Config knobs (`config.json`)

| key | default | meaning |
|---|---|---|
| `buy_usd` | 25 | USDG per signal (one position per token, whichever wallet buys first) |
| `max_positions` | 20 | cap on concurrent open positions |
| `min_liquidity_usd` | 10000 | skip tokens with a shallower deepest pool |
| `thin_liquidity_usd` / `thin_min_sells_24h` | 50000 / 5 | below this liquidity, require this many sells by others in 24h |
| `max_round_trip_loss_pct` | 15 | skip if buying then selling straight back would lose more (thin pool / tax token) |
| `min_origin_usd` | 50 | ignore dust buys by the watched wallet |
| `max_price_impact_pct` | 10 | skip if our fill would be this far above market |
| `max_signal_age_s` | 120 | never chase a buy older than this (e.g. after a restart) |
| `slippage_pct` | 3 | minOut bound vs the on-chain quote |
| `exits` | 1h/50%, 24h/25% | timed tranches; the remainder waits for the origin wallet |
| `reentry_cooldown_hours` | 24 | don't re-buy a token closed within this window |
| `skip_stock_tokens` | true | ignore Robinhood tokenized stocks/ETFs (on-chain name ends "• Robinhood Token") |
| `exclude_tokens` | [] | extra symbols or addresses never to copy |
| `honeypot_check` | true | skip tokens with many buys and ~no sells on dexscreener |
| `holder_probe` | true | before buying, ask the chain whether the token's last few buyers can still move it (see below) |
| `holder_probe_count` / `holder_probe_min_age_s` | 8 / 30 | how many recent buyers to test, ignoring ones younger than this (the blocker has not reached them yet) |
| `holder_probe_min_trapped` | 2 | skip when this many probed holders are blocked (or one is and none is free) |
| `holder_probe_wait_s` | 1.0 | how long to wait for the probe after routing before buying without it |
| `bytecode_blocklist` | [0x109b1bd8…] | skip tokens whose bytecode carries one of these constants (the PEZ/MEGADUCK honeypot build) |
| `relay_gate` | true | ask Relay who paid for the origin buy; skip when a stranger who buys into other tracked wallets did (see below) |
| `relay_wait_s` / `relay_watch_s` | 2.5 / 180 | how long to wait for Relay before buying, and for how long after a fill an unknown payer is re-checked |
| `relay_min_funded` | 2 | a payer becomes a "stranger" once it has bought into this many tracked wallets |
| `relay_unknown` | buy | `buy` or `skip` when Relay has not named the payer in time |
| `requote_on_slippage` | true | when the buy reverts with "slippage", re-quote once and retry if the price is still within the impact cap |

## What counts as a signal

- **Buy**: a watched wallet *receives* a non-stable token in a tx where it also
  sent something (a swap) or the sender is a contract (one-sided router fill),
  **and** its balance of that token one block earlier was zero. Adding to an
  existing bag is not a signal. Plain wallet-to-wallet transfers and airdrops
  from EOAs are ignored.
- **Origin exit**: the wallet that triggered the position *sends* that token
  into a swap or contract. Any amount counts as "starting to exit".

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


## Planted buys and the Relay payer check

fomo funds its Robinhood Chain wallets through Relay (relay.link). A fomo buy is a Relay
request "take my USDC on Solana, deliver token X to my wallet"; Relay's solver keys submit
it and Relay's router settles it. Relay lets any user name any recipient, so a scammer can
buy their own coin *into* a famous wallet, and the transaction is byte-identical to the
whale buying it (MEGADUCK into runitbackghost was paid by an outside Solana wallet that
planted into 16 of our wallets; PEZ into unipcs was paid by PEZ's own deployer). Relay's
public index names the payer, so the bot asks it in a thread next to routing: the
trader's own paired Solana wallet (`solana.json`, from the scanner's traders.json) or the
EVM wallet itself means genuine; a payer that also buys into other tracked wallets means
planted and the signal is skipped. Relay does not always answer within the buy window, so
an unknown payer is bought and re-checked for three minutes after the fill; if it turns
out to be a stranger the whole position is sold at once, while the blacklister has not
reached us yet. `python bot.py payer <txhash>` prints the verdict for any fill. The old
`require_fomo_payer` option is meaningless (that "payer" is Relay's solver).

## Files

- `bot.py` — everything: watcher, routing, execution, exits, CLI
- `contracts/src/CopyRouter.sol` — stateless swap executor (route passed per call)
- `data/state.json` — open/closed positions; `data/trades.jsonl`, `data/signals.jsonl`

## Speed

Signal → fill is roughly one poll interval plus ~1.5s (quote + tx). The public
RPC throttles at about one batched tick per 2s (`poll_seconds: 2`, the default).
With an Alchemy key set `RPC_URL=https://robinhood-mainnet.g.alchemy.com/v2/<KEY>`
in `.env` and drop `poll_seconds` to `1` (free tier) or `0.5` (paid).

## Running on a server (DigitalOcean droplet)

1. Create an Ubuntu droplet with your SSH key. The smallest size is plenty.
2. **Stop both bots on your laptop** (Ctrl+C). Two copies must never trade with the same wallet.
3. From the laptop: `./deploy/push.sh root@DROPLET_IP` — copies both folders (including `.env` and
   `data/`, so open positions carry over) and installs the systemd services.
4. `ssh root@DROPLET_IP 'systemctl start rh-copybot rh-copybot-paper'`

On the droplet: `journalctl -fu rh-copybot` follows the live log, `journalctl -fu rh-copybot-paper`
the paper one; `cd /opt/rh-copybot && .venv/bin/python dash.py` is the dashboard (best inside `tmux`),
`.venv/bin/python bot.py status` / `stats.py` work the same. To push a code or config change later,
re-run `push.sh` (it refuses while a laptop bot is running) then `systemctl restart rh-copybot rh-copybot-paper`.
`.env` and `data/` are copied verbatim, so keep the laptop copies as your backup.

## Caveats

- You always fill *after* the wallet you copy. On thin pools that gap is real.
- The hot wallet key in `.env` controls the funds. Use a throwaway wallet.
- Unaudited prototype. Paper-trade it before it touches money.
