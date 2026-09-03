# Claude Code usage in the macOS menu bar

A single [SwiftBar](https://swiftbar.app/) plugin showing Claude Code's rate-limit
utilization, kept deliberately narrow because the menu bar is crowded:

```
1·8
```

Short window first, then whichever long window is closest to biting. No percent
signs, no icon — three characters most of the time. The text turns amber at
80% and red at 90%, and a trailing `⋯` means the numbers are stale.

Clicking opens the full breakdown — one line per window, with meters and reset
countdowns, and any of them opens an interactive chart of that window's history.

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
good response, the backoff bookkeeping, the usage history and the generated
chart page — in a `0700` directory. The state file is parsed, never sourced, so
a corrupt or tampered one cannot become shell code or wedge the plugin.

## History and charts

The plugin polls on the interval in its filename whether or not you ever open
the menu — that is what keeps the menu bar number current — so it can keep a
record for free. Every successful fetch appends one row per window to
`history.tsv` in the state directory.

The dropdown stays one line per window:

```
Session             15% ██░░░░░░░░  resets in 3h 3m    (Thu 06:59)
Weekly (all)        21% ██░░░░░░░░  resets in 2d 11h   (Sat 14:59)
Weekly (Fable)       0% ░░░░░░░░░░  no active window
```

Clicking any of them opens a chart window, at that window's section. It is a
local HTML page in the state directory, opened in SwiftBar's WebView: inline
SVG, inline script, no network and no CDN. Moving the cursor across a chart
tracks the nearest sample and reads out its time and value.

Each window gets two charts, and **both axes are fixed rather than fitted to the
data**. That is the whole design:

- **Utilization runs 0–100%.** A chart scaled to its own range answers "what
  shape was my usage"; the question that matters is "how close am I to the
  limit". A quiet cycle therefore draws a flat line near the floor, which is the
  honest picture rather than a defect.
- **Time runs the full window, start to reset**, so the horizontal position
  shows how far through the window you are. The stretch before the first sample
  is left blank — that is where the plugin was not watching.
- **The rate chart is scaled against pace**, the burn rate that would exactly
  exhaust the window (`100% / length`), drawn as a dashed line. Above it, this
  window ends early; below it, there will be quota to spare. A rate chart cannot
  use a 0–100% axis, and pace is the fixed reference that replaces it.

A gap in the samples stays a gap: sleep, a 429 backoff and an expired token all
cost samples, and the line breaks rather than guessing across them. Rates are
differenced over a trailing window and not across a long gap, because the API
reports whole percents — consecutive samples differ by 0 or 1, so a per-sample
derivative is quantisation noise rather than a burn rate.

### Where the window starts

Charts need the window's start and the API reports only when it ends. The
length is measured from history once two of a window's resets have been seen,
using the **minimum** gap between them: a session window appears to start on
first use, so an idle stretch stretches the gap well past the window itself
(5.0h and 6.2h have both been observed for a 5h session). Until then it falls
back to the documented length for the kind — 5h, 7d, 30d.

### Today

A plan whose **longest** window runs two weeks or more — an enterprise monthly
window, say — also gets a **Today** section, local midnight to midnight, with a
cumulative chart and a rate chart. A day disappears inside a month, so it earns
its place there; against a weekly window it does not, and the five-hour session
window already answers "what have I been doing lately". The test is on the
longest window rather than the shortest, so a plan reporting *session and
monthly* still gets Today, and a weekly plan never does.

Today is *derived*, not reported: the API has no daily window, so it accumulates
the positive steps of the longest window since local midnight, counting a reset
only when the figure actually falls. Anything that costs samples — sleep,
backoff, an expired token — makes it a floor rather than a total, and it says
so. Its axes are the two exceptions to the fixed-axis rule above: the cumulative
chart is scaled to an even day's share of the window (`100% / 30` for a monthly
one) rather than to 0–100%, since a day is never a large fraction of a month,
and that share is drawn as the reference line.

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
  enterprise account — the author has none to test with. That includes the
  monthly window and the Today charts it unlocks, which are exercised against a
  synthetic response rather than a live plan. If the numbers don't match your
  Claude Code settings → usage page, the raw JSON will say why.
- Only utilization percentages are available. `limit_dollars` and `used_dollars`
  come back `null` on subscription plans, so there is no absolute "X of Y".
- The poll interval is encoded in the filename (`.180s.`). 180s is what the
  endpoint tolerates; faster invites 429s. It is also the best resolution the
  history can have, and the real resolution is coarser: sleep and backoff both
  cost samples.

## License

MIT — see [LICENSE](LICENSE).
