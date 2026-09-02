# Claude Code usage in the macOS menu bar

A single [SwiftBar](https://swiftbar.app/) plugin showing Claude Code's rate-limit
utilization, kept deliberately narrow because the menu bar is crowded:

```
1·8
```

Short window first, then whichever long window is closest to biting. No percent
signs, no icon — three characters most of the time. The text turns amber at
80% and red at 90%, and a trailing `⋯` means the numbers are stale.

Clicking opens the full breakdown — every window the account has, with meters
and reset countdowns. Only the menu bar item is constrained; the dropdown is not.

## Plans

The endpoint reports whichever windows an account actually has, and the plugin
renders all of them rather than looking for specific ones:

| Plan | Windows typically reported |
| --- | --- |
| Pro / Max | session (5h), weekly (all), weekly per-model |
| Enterprise | session, monthly |

The menu bar always shows `session·<highest other>`, so on a monthly plan the
second number is the monthly figure. An account with no session window shows a
single number. A window kind this plugin has never seen still appears in the
dropdown with a readable label derived from its name, so a future plan shape
degrades to "slightly awkward label" rather than "silently missing limit".

## Why a script instead of one of the menu bar apps

Every Claude usage app needs a credential that unlocks your Claude account, and
the popular ones take more than they need — several accept or extract a
`claude.ai` session cookie, which is full web-app access — and then auto-update
themselves, so auditing today's build says nothing about next week's.

This is one shell script you can read in a sitting. It reads the Claude Code
OAuth token from the login keychain, sends it to `api.anthropic.com` and nowhere
else, and never writes, refreshes, or rotates it.

## Install

```sh
brew install --cask swiftbar
git clone https://github.com/y1guo/claude-usage-swiftbar.git
cd claude-usage-swiftbar
./install.sh            # --dry-run to preview, --uninstall to remove
open -a SwiftBar
```

`install.sh` symlinks the plugin rather than copying it, so keep the clone where
it is — `git pull` then updates the running plugin in place.

On a machine with no plugin folder configured yet, `install.sh` preseeds
SwiftBar's `PluginDirectory` preference. **If SwiftBar still asks you to choose a
folder, pick the one `install.sh` prints** (press ⌘⇧G in the picker to type the
path). Either way SwiftBar records the folder afterwards and `install.sh` finds
it on subsequent runs.

macOS may then ask whether SwiftBar can read the `Claude Code-credentials`
keychain item. Choose **Always Allow**, or the plugin shows `⚠️ claude`.

## How it works

`GET https://api.anthropic.com/api/oauth/usage`, the same undocumented endpoint
behind Claude Code's own `/usage`, authorized with the `claudeAiOauth.accessToken`
from the keychain. Two request details are load-bearing:

- **`User-Agent: claude-cli/<version>`** — without a `claude-cli` agent the
  endpoint returns persistent 429s.
- **`anthropic-beta: oauth-2025-04-20`** — required for the OAuth surface.

The bearer token is fed to curl over **stdin** (`-H @-`), never as an argument,
so it does not appear in `ps` output to other processes running as you. `-q`
ignores `~/.curlrc` and there is no `-L`, so a redirect cannot replay the token
to another host.

Windows come from the response's `limits[]` array; the older `five_hour` /
`seven_day` fields are used as a fallback if that array ever disappears.

State lives in `${XDG_CACHE_HOME:-~/.cache}/claude-usage-swiftbar/` — the last
good response, the backoff bookkeeping and the usage history — in a `0700`
directory. The state file is parsed, never sourced, so a corrupt or tampered one
cannot become shell code or wedge the plugin.

## History

The plugin polls on the interval in its filename whether or not you ever open
the menu — that is what keeps the menu bar number current — so it can keep a
record for free. Every successful fetch appends one row per window to
`history.tsv` in the state directory, and the dropdown draws the current cycle
underneath each meter:

```
Weekly (all)        68% ███████░░░
                        resets in 3d 0h  (Sat 15:00)
                        ▁▁▁▁▁▂▂▂▃▃▃▄▄▄▅▅▅▆▆▆▇▇▇█  60→68%  over 6h 0m
                        ··▅▆██▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▅  0→1.8 %/h  now 1.0 · 100% in 1d 8h
```

The top sparkline is utilization, the bottom one is how fast it is climbing, and
each is labelled with the range it is drawn across — neither is scaled to a
fixed 0–100%, or a window sitting at 8% would be a flat line on the floor. The
tail is the burn rate over the last hour and what it implies: `100% in 1d 8h`,
or `resets first` when the window turns over before the quota runs out, or
`idle` for a window that has not moved in an hour, or `rate unknown` when the
last hour holds too few samples to say — which is what it says after a long
sleep, rather than averaging a fresh burn away across the gap.

Charts appear once an hour of the *current cycle* is on record, and read
`gathering history…` until then. That includes the first hour after every reset,
not just the first hour after install.

Four things the drawing is careful about, because the underlying data does not
support naivety:

- **Cycles are charted separately.** These windows reset, so one continuous line
  across a reset would be a sawtooth and its derivative would be all cliffs.
  Each chart covers the current cycle only, and `over 6h 0m` says how much of
  that cycle has actually been observed — a window that reset before you
  installed the plugin charts from first sample, not from the reset.
- **Gaps are drawn as gaps.** SwiftBar does not run while the Mac sleeps and the
  fetch backs off after a 429, so samples are unevenly spaced. Bins are by
  wall-clock time and never narrower than one poll, and a bin with no sample is
  `·` rather than a carried-forward flat line — quota can move while we are not
  looking. The rate row needs a real sample at *both* ends of its difference, so
  it stays blank across a gap and for a while after one instead of charging
  everything the gap hid to the first bin back.
- **Rates are differenced across a span of bins, then smoothed** — half an hour
  where bins are narrower than that, one bin where they are wider. The API
  reports whole percents, so consecutive 180s samples differ by 0 or 1 and a
  per-sample derivative is quantisation noise rather than a burn rate.
- **Both sparklines are scaled to their own series.** `60→68%` and `0→1.8 %/h`
  state the observed range, so a tall bar means "high for this cycle", not "near
  the limit" — the number beside the meter is the absolute one. A range narrower
  than 4 points is drawn over a 4-point span, so a 1% wobble is not stretched
  into a climb and does not reach the top of the chart.

`history.tsv` is tab-separated `epoch`, `window`, `percent`, `cycle` — plottable
with anything — pruned to 30 days (about 1.7 MB) and openable from **Reveal
usage history** in the dropdown. It holds a timestamp, the window name including
the model scope where the API reports one, the utilization percentage and which
reset it belongs to. No prompts, no content, no credentials.

## Failures

On a fetch failure the plugin keeps showing the last good numbers with a
trailing `⋯` and backs off, hard for 429s (this endpoint rate-limits aggressively) and
gently for network errors. Token problems (`token expired`, `token rejected`)
are fixed by running `claude` once — it refreshes the keychain token. If nothing
readable is cached it shows `⚠️` rather than inventing zeros, because a
confident `0` is the worst possible lie for a quota indicator. Missing
credentials or a missing dependency replace the menu bar with `⚠️` outright,
since those need action from you rather than patience. The exact backoff
schedules live in the `case` block in the script and are not repeated here.

The plugin deliberately does **not** refresh the OAuth token itself. The refresh
flow rotates the refresh token, so a second client doing it could invalidate
your Claude Code login.

## Caveats

- The endpoint is undocumented and does churn — the live response carries
  internal codenamed buckets (`tangelo`, `nimbus_quill`, …). The generic
  rendering above is the defence against that, but if something looks wrong,
  use **Reveal cached response** in the dropdown to inspect the raw JSON.
- Enterprise support is written against the response shape, not against a real
  enterprise account — the author has none to test with. If the numbers don't
  match your Claude Code settings → usage page, the raw JSON will say why.
- Only utilization percentages are available. `limit_dollars` and `used_dollars`
  come back `null` on subscription plans, so there is no absolute "X of Y".
- The poll interval is encoded in the filename (`.180s.`). 180s is what the
  endpoint tolerates; faster invites 429s. It is also the best resolution the
  history can have, and the real resolution is coarser: sleep and backoff both
  cost samples.

## License

MIT — see [LICENSE](LICENSE).
