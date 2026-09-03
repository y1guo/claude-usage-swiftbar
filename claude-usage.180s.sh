#!/bin/bash
#
# <bitbar.title>Claude Code Usage</bitbar.title>
# <bitbar.version>1.4.0</bitbar.version>
# <bitbar.author>y1guo</bitbar.author>
# <bitbar.author.github>y1guo</bitbar.author.github>
# <bitbar.desc>Claude Code session and weekly/monthly rate-limit utilization in the menu bar.</bitbar.desc>
# <bitbar.dependencies>bash,curl,jq</bitbar.dependencies>
# <bitbar.abouturl>https://github.com/y1guo/claude-usage-swiftbar</bitbar.abouturl>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#
# Reads the Claude Code OAuth token from the login keychain and calls the same
# undocumented endpoint that Claude Code's own /usage command uses.
#
# The token is handed to curl over stdin, never as an argument, so it does not
# appear in `ps` output to other processes running as this user. The script
# never writes the token anywhere, and never refreshes or rotates it: the
# refresh flow rotates the refresh token, so a second client doing that could
# invalidate your Claude Code login.

set -uo pipefail

ENDPOINT="https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE="Claude Code-credentials"
UA_FALLBACK="2.1.258"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-usage-swiftbar"
CACHE="$STATE_DIR/usage.json"
STATE="$STATE_DIR/state"
# Tab-separated on purpose, unlike everything above: awk's FS="\t" does not
# collapse runs the way bash's IFS does, none of its four fields can be empty,
# and a tab keeps the file plottable with anything.
HISTORY="$STATE_DIR/history.tsv"
CHART_HTML="$STATE_DIR/chart.html"

# One row per window per successful fetch; 30 days at a 180s poll is ~1.7 MB.
HIST_KEEP=$(( 30 * 86400 ))
HIST_PRUNE_EVERY=86400

# Charts need the window's start, and the API only reports when it ends. These
# are the documented lengths per kind, used until the history has seen two
# resets of a window and can measure it (see win_len). Deliberately a fallback,
# not an assumption: an unknown kind gets the weekly length and a chart whose
# x-axis is merely wrong, rather than no chart.
WIN_LEN_SESSION=$(( 5 * 3600 ))
WIN_LEN_WEEKLY=$(( 7 * 86400 ))
WIN_LEN_MONTHLY=$(( 30 * 86400 ))

# Today is for plans whose only long window is so long that a day disappears
# inside it. Keyed on the longest window rather than the shortest: a monthly
# plan gets Today whether or not it also reports a session window, and a weekly
# plan never does, because its session window already shows recent detail.
TODAY_MIN_WINDOW=$(( 14 * 86400 ))

# Field separator between jq and the read loops. Deliberately NOT a tab: tab is
# an IFS whitespace character, so bash collapses runs of them and an empty field
# (a limits[] entry with no "group") would silently shift every later column.
SEP=$'\x1f'

# The menu bar title carries no colour below 80%, so macOS inverts it when the
# menu opens; the warn and crit shades below deliberately override that.
FONT="font=Menlo size=12"
# A dropdown row needs a colour or an action, or SwiftBar gives it no click
# target (configureAction in MenuBarItem.swift) and AppKit greys it out — a
# plain uncoloured row renders as a disabled item, washed out next to SwiftBar's
# own entries. DIM is for the rows that have no action; POOL_ROW below is for
# the ones that do. Colour pairs are light,dark.
#
# trim=false keeps the leading spaces SwiftBar would otherwise strip
# (MenuBarItem.swift), which is what lets a padded row hold its column.
DIM="font=Menlo size=12 color=#5f5f66,#a8a8b0 trim=false"

# Amber and red at the menu bar, darkened for the light menu bar where the
# system shades are too pale to read.
WARN_COLOR="color=#b35a00,#ff9f0a"   # >= 80%
CRIT_COLOR="color=#bf2d24,#ff453a"   # >= 90%

# A pool row carries an action (it opens the chart popover) rather than a
# colour. Either one stops SwiftBar drawing the row as disabled, but a colour
# also makes menu(_:willHighlight:) rebuild the row's attributedTitle as bare
# text the moment the highlight touches it — harmless for text, fatal for any
# row holding an image. Carrying the action instead keeps that path away from
# us and lets macOS pick the label colour, which is more correct anyway.
POOL_ROW="font=Menlo size=12 trim=false"

# Sized to fit a 13" MacBook (1440x900 points) under the menu bar without the
# popover itself being clipped; past three pools the page scrolls, which is the
# right trade — a per-model weekly window can push a subscription to four.
POPOVER_W=620
POPOVER_H=720

mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
NOW=$(date +%s)

# ---- helpers ----------------------------------------------------------------

fetched_at=0; backoff_until=0; rl_fails=0; net_fails=0; last_error=""
pruned_at=0; did_fetch=0

# Parsed, never sourced: a truncated or tampered state file must not become
# shell code, and must not wedge the plugin under `set -u`.
if [[ -f "$STATE" ]]; then
  while IFS='=' read -r k v; do
    case "$k" in
      fetched_at|backoff_until|rl_fails|net_fails|pruned_at)
        [[ "$v" =~ ^[0-9]+$ ]] && printf -v "$k" '%s' "$v" ;;
      last_error)
        last_error="$v" ;;
    esac
  done < "$STATE"
fi

# A clock jump forward would otherwise persist a deadline we never reach; 1800s
# is the longest backoff this script ever sets, so anything beyond it is bogus.
(( backoff_until > NOW + 1800 )) && backoff_until=0

# Same class of bogus persisted deadline, and this one never self-heals: the
# script only ever stamps pruned_at with its own NOW, so a value in the future
# came from a wrong clock and would otherwise hold off pruning until real time
# caught up — leaving the history file to grow without bound in the meantime.
(( pruned_at > NOW )) && pruned_at=0

save_state() {
  printf 'fetched_at=%s\nbackoff_until=%s\nrl_fails=%s\nnet_fails=%s\npruned_at=%s\nlast_error=%s\n' \
    "$fetched_at" "$backoff_until" "$rl_fails" "$net_fails" "$pruned_at" \
    "${last_error//[$'\n'|]/ }" \
    > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
}

# This endpoint hands out persistent 429s to requests without a claude-cli
# User-Agent, so mirror the installed version.
ua_version() {
  local v
  v=$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
  printf '%s' "${v:-$UA_FALLBACK}"
}

# Accepts "...THH:MM:SS" with an optional fraction and an optional UTC offset.
# The offset is applied rather than ignored: dropping it fails silently, which
# would put the reset countdown hours out without any visible error.
iso_to_epoch() {
  local t="${1:-}" base adj=0 e
  [[ -z "$t" || "$t" == "null" ]] && return 1
  base="${t:0:19}"
  [[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 1
  if [[ "$t" =~ ([+-])([0-9]{2}):?([0-9]{2})$ ]]; then
    adj=$(( 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 ))
    [[ "${BASH_REMATCH[1]}" == "+" ]] && adj=$(( -adj ))
  fi
  e=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$base" +%s 2>/dev/null) || return 1
  [[ -n "$e" ]] || return 1
  printf '%s' $(( e + adj ))
}

human_delta() {
  local s=${1:-0}
  (( s < 0 )) && s=0
  local d=$(( s / 86400 )) h=$(( (s % 86400) / 3600 )) m=$(( (s % 3600) / 60 ))
  if   (( d > 0 )); then printf '%dd %dh' "$d" "$h"
  elif (( h > 0 )); then printf '%dh %dm' "$h" "$m"
  else                   printf '%dm' "$m"
  fi
}

meter() {
  local pct=${1:-0} i filled out=""
  filled=$(( (pct + 5) / 10 ))
  (( filled > 10 )) && filled=10
  (( filled < 0 ))  && filled=0
  for (( i = 0; i < 10; i++ )); do
    (( i < filled )) && out+="█" || out+="░"
  done
  printf '%s' "$out"
}

# Plans differ in which windows they have (Max has 5h + weekly + per-model
# weekly; enterprise plans report a monthly window instead), and the endpoint
# is undocumented, so unknown kinds get a readable label rather than dropped.
label_for() {
  local kind="${1:-limit}" model="${2:-}" base
  case "$kind" in
    session)                 base="Session" ;;
    weekly_all)              base="Weekly (all)" ;;
    monthly_all)             base="Monthly (all)" ;;
    weekly_scoped)           base="Weekly" ;;
    monthly_scoped)          base="Monthly" ;;
    *)  base="${kind//_/ }"
        base="$(printf '%s' "${base:0:1}" | tr '[:lower:]' '[:upper:]')${base:1}" ;;
  esac
  if [[ -n "$model" && "$model" != "null" ]]; then
    printf '%s (%s)' "$base" "$model"
  else
    printf '%s' "$base"
  fi
}

# SwiftBar treats "|" as its parameter separator and honours bash=/param= on any
# line, so labels that came from the API are stripped of it before rendering.
# A percentage that did not survive parsing is shown as unknown, never as 0%.
#
# One line per pool: label, percentage, bar, and when it resets. Clicking it
# opens the chart popover at that pool's section.
pool_row() {  # $1 label, $2 pct, $3 resets_at ("none" = not a window), $4 anchor
  local label="${1//[|$'\n']/ }" pct="${2:-}" bar tail epoch action
  if [[ "$pct" =~ ^[0-9]+$ ]]; then
    bar=$(printf '%3d%% %s' "$pct" "$(meter "$pct")")
  else
    bar='  ?% unreadable'
  fi
  if [[ "${3:-}" == "none" ]]; then
    # Extra usage is a spending pool, not a rate-limit window; it has no reset
    # and saying "no active window" about it would be a plain falsehood.
    tail=""
  elif epoch=$(iso_to_epoch "${3:-}"); then
    tail=$(printf 'resets in %-8s (%s)' "$(human_delta "$(( epoch - NOW ))")" \
      "$(date -r "$epoch" '+%a %H:%M')")
  else
    tail="no active window"
  fi
  # Every window row is clickable, including one with nothing to plot: the
  # popover gives it a section saying why, which beats a row that looks broken.
  # Extra usage has no history series, so it gets no anchor and no link.
  if [[ -n "${4:-}" && -s "$CHART_HTML" ]]; then
    action="href=file://$CHART_HTML#$4 webview=true webvieww=$POPOVER_W webviewh=$POPOVER_H $POOL_ROW"
  else
    action="$DIM"
  fi
  printf '%-18s %s  %s | %s\n' "$label" "$bar" "$tail" "$action"
}

die() {  # menu-bar text as $1, explanation lines on stdin
  printf '%s | %s\n---\n' "$1" "$FONT"
  cat
  printf -- '---\nRefresh now | refresh=true\n'
  exit 0
}

# SwiftBar does not source a login shell, so a Homebrew-only dependency can be
# missing here while working fine in a terminal. Say so instead of blaming auth.
for dep in curl jq security; do
  command -v "$dep" >/dev/null 2>&1 || die "⚠️ deps" <<< "$dep not found on PATH | $DIM"
done

# How long this window runs. The API says only when it ends, so measure it when
# the history holds two of its resets and fall back to the documented length
# otherwise. The *minimum* gap is the measurement: a session window appears to
# start on first use, so an idle stretch stretches the gap between resets well
# past the window itself (5.0h and 6.2h both observed for a 5h session).
win_len() {  # $1 id, $2 kind
  local measured fallback
  case "$2" in
    session*) fallback=$WIN_LEN_SESSION ;;
    monthly*) fallback=$WIN_LEN_MONTHLY ;;
    *)        fallback=$WIN_LEN_WEEKLY ;;
  esac
  # Cycle 0 is the marker for "no resets_at", not a reset time. Left in, the
  # smallest "gap" becomes 0 -> a real epoch and the window measures ~56 years,
  # which then poisons the axis, the pace line and the pick of the longest
  # window. So: positive cycles only, and the answer has to be the right order
  # of magnitude for the kind or it is not an answer.
  measured=$(awk -F'\t' -v id="$1" '
    $2 == id && $4 + 0 > 0 && !($4 in seen) { seen[$4] = 1; c[++n] = $4 + 0 }
    END {
      if (n < 2) exit 1
      for (i = 1; i < n; i++) for (j = i + 1; j <= n; j++)
        if (c[j] < c[i]) { t = c[i]; c[i] = c[j]; c[j] = t }
      best = 0
      for (i = 2; i <= n; i++) { d = c[i] - c[i - 1]; if (d > 0 && (best == 0 || d < best)) best = d }
      if (best <= 0) exit 1
      print best
    }' "$HISTORY" 2>/dev/null)
  if [[ "$measured" =~ ^[0-9]+$ ]] \
     && (( measured >= 600 && measured >= fallback / 4 && measured <= fallback * 4 )); then
    printf '%s' "$measured"
  else
    printf '%s' "$fallback"
  fi
}

# "[t,pct],[t,pct],..." for one window's current cycle; fails if too few points.
samples_json() {  # $1 id, $2 cycle
  awk -F'\t' -v id="$1" -v cyc="$2" '
    $1 ~ /^[0-9]+$/ && $2 == id && ($4 + 0) == cyc { n++; printf "%s[%d,%d]", (n > 1 ? "," : ""), $1, $3 }
    END { if (n < 2) exit 1 }' "$HISTORY" 2>/dev/null
}

# Today, derived rather than reported: the API has no daily window, so this
# accumulates the positive steps of a long window since local midnight. A step
# is only counted within one cycle; when the cycle changes the window reset
# today, so everything it has accrued since is today's. Sleep, a 429 backoff or
# an expired token all cost samples here, which makes this a floor, not a total.
today_json() {  # $1 id, $2 midnight epoch
  awk -F'\t' -v id="$1" -v t0="$2" '
    $1 ~ /^[0-9]+$/ && $2 == id && $1 + 0 >= t0 {
      t = $1 + 0; v = $3 + 0; c = $4 + 0
      if (seen) {
        # A changed cycle key only means a reset if the value actually fell.
        # resets_at can shift for other reasons, and adding the whole current
        # figure then would invent usage — the one direction the caption on
        # this section ("gaps under-count") promises cannot happen.
        if (c != pc && v < pv) cum += v
        else if (v > pv) cum += v - pv
      }
      seen = 1; pv = v; pc = c
      printf "%s[%d,%.2f]", (n++ ? "," : ""), t, cum
    }
    END { if (n < 2) exit 1 }' "$HISTORY" 2>/dev/null
}

# The chart popover: a self-contained local page, no network and no CDN, opened
# by SwiftBar in a WKWebView when a pool row is clicked.
#
# Both axes are fixed rather than fitted to the data, which is the whole point:
# a chart scaled to its own range answers "what shape was my usage", and the
# question that actually matters is "how close am I to the limit, and how far
# through the window". So utilisation runs 0-100% and time runs the full window,
# start to reset. A low cycle therefore draws a flat line near the floor — that
# is the honest picture, not a defect.
#
# Every pool row in the menu links here, so every pool needs a section. Returns
# non-zero when there was nothing to chart at all, which is not an error.
write_chart_html() {
  local kind group pct reset model id cycle epoch len label pts note
  local pools="" primary="" plen=0 today="" today_js="null" midnight tomorrow
  while IFS="$SEP" read -r kind group pct reset model; do
    [[ -z "$kind" ]] && continue
    id=$(win_id "$kind" "$model")
    label=$(label_for "$kind" "$model")
    # This lands in a JS string literal *and* in innerHTML, so it has to survive
    # both: quotes and backslashes would break the literal, angle brackets and
    # ampersands would inject markup into the page. The model name comes from an
    # undocumented API, so it is whitelisted down rather than trusted.
    label="${label//[\"\\<>\&$'\n'$'\r']/ }"
    # Every pool gets a section, charted or not, so that every row in the menu
    # opens something rather than appearing dead when it has nothing to draw.
    if ! cycle=$(cycle_key "$reset") || ! epoch=$(iso_to_epoch "$reset"); then
      note="No active window on this plan right now, so there is nothing to chart."
    elif ! pts=$(samples_json "$id" "$cycle"); then
      note="Gathering history. This window reset recently, and a chart needs a few samples."
    else
      note=""
    fi
    if [[ -n "$note" ]]; then
      pools+="${pools:+,}{\"id\":\"$id\",\"label\":\"$label\",\"note\":\"$note\"}"
      continue
    fi
    len=$(win_len "$id" "$kind")
    pools+="${pools:+,}{\"id\":\"$id\",\"label\":\"$label\",\"reset\":$epoch,\"len\":$len,\"p\":[$pts]}"
    if (( len > plen )); then primary="$id"; plen=$len; fi
  done <<< "$rows"
  [[ -n "$pools" ]] || return 1

  # Today is only built when nothing shorter than a day is already charted: a
  # A day is a meaningful slice of a month and not of a week, and the scan is not
  # free. The page applies the same rule, so the two cannot disagree.
  midnight=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date '+%Y-%m-%d') 00:00:00" +%s 2>/dev/null) || midnight=0
  # Tomorrow's local midnight rather than midnight+86400: a DST day is 23 or 25
  # hours long, and the fixed axis would clip or overrun by an hour.
  tomorrow=$(date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$(date '+%Y-%m-%d') 00:00:00" +%s 2>/dev/null) \
    || tomorrow=$(( midnight + 86400 ))
  if [[ -n "$primary" ]] && (( midnight > 0 && plen >= TODAY_MIN_WINDOW )); then
    today=$(today_json "$primary" "$midnight") || today=""
    [[ -n "$today" ]] && today_js="[$today]"
  fi

  {
    cat <<'HEAD'
<!doctype html><meta charset="utf-8"><title>Claude usage</title>
<style>
:root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--dim:#6e6e73;--grid:#dcdce1;
      --line:#0a6cff;--fill:#0a6cff1f;--ref:#c2610a}
@media(prefers-color-scheme:dark){:root{--bg:#1e1e1e;--fg:#f5f5f7;--dim:#9a9aa0;
      --grid:#3a3a3c;--line:#64a8ff;--fill:#64a8ff26;--ref:#ff9f0a}}
*{box-sizing:border-box}
body{margin:0;padding:4px 14px 14px;background:var(--bg);color:var(--fg);
     font:12px -apple-system,BlinkMacSystemFont,sans-serif}
section{padding-top:10px}
h2{font-size:13px;font-weight:600;margin:0}
.sub{color:var(--dim);font-size:11px;margin:1px 0 3px}
.rd{color:var(--dim);font-size:11px;height:14px;margin-top:1px;font-variant-numeric:tabular-nums}
.note{color:var(--dim);font-size:11px;padding:10px 0 4px}
svg{display:block;width:100%}
text{fill:var(--dim);font-size:9px;font-family:-apple-system,sans-serif}
</style><div id=c></div><script>
HEAD
    # "null", never the empty string: an unset TODAY would emit `const TODAY=;`
    # and a single syntax error takes the whole page down, charts included.
    printf 'const POOLS=[%s];\nconst TODAY=%s;\nconst NOW=%d;\nconst DAY0=%d;\nconst DAY1=%d;\nconst PRIMARY=%s;\nconst TODAY_MIN=%d;\n' \
      "$pools" "$today_js" "$NOW" "$midnight" "$tomorrow" "\"${primary:-}\"" "$TODAY_MIN_WINDOW"
    cat <<'TAIL'
const host = document.getElementById('c');
const clock = t => new Date(t*1000).toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'});
const stamp = t => new Date(t*1000).toLocaleString([], {weekday:'short', hour:'2-digit', minute:'2-digit'});
const GAP = 600;   // seconds without a sample that count as "not observed"

// One chart. Axes are given, never fitted; a series is drawn as separate
// subpaths so a gap in the samples stays a gap on the page.
function chart(parent, o) {
  const W = 560, H = o.h || 96, L = 38, R = 8, T = 8, B = 16;
  const px = t => L + (t - o.x0) / (o.x1 - o.x0) * (W - L - R);
  const py = v => T + (1 - v / o.y1) * (H - T - B);
  let d = '', area = '', run = [];
  const flush = () => {
    if (!run.length) return;
    const pts = run.map(q => px(q[0]).toFixed(1) + ' ' + py(q[1]).toFixed(1)).join('L');
    d += 'M' + pts + ' ';
    if (o.fill) area += 'M' + px(run[0][0]).toFixed(1) + ' ' + py(0) + 'L' + pts +
                        'L' + px(run[run.length-1][0]).toFixed(1) + ' ' + py(0) + 'Z';
    run = [];
  };
  let prev = null;
  for (const q of o.series) { if (prev !== null && q[0] - prev > GAP) flush(); run.push(q); prev = q[0]; }
  flush();

  const bits = [];
  for (const g of o.yticks) bits.push(
    '<line x1="'+L+'" x2="'+(W-R)+'" y1="'+py(g).toFixed(1)+'" y2="'+py(g).toFixed(1)+
    '" stroke="var(--grid)" stroke-width="1"/>' +
    '<text x="'+(L-5)+'" y="'+(py(g)+3).toFixed(1)+'" text-anchor="end">'+o.fmt(g)+'</text>');
  if (o.ref != null && o.ref <= o.y1) bits.push(
    '<line x1="'+L+'" x2="'+(W-R)+'" y1="'+py(o.ref).toFixed(1)+'" y2="'+py(o.ref).toFixed(1)+
    '" stroke="var(--ref)" stroke-width="1" stroke-dasharray="4 3"/>' +
    '<text x="'+(W-R)+'" y="'+(py(o.ref)-3).toFixed(1)+'" text-anchor="end" fill="var(--ref)">'+o.refLabel+'</text>');
  if (o.fill) bits.push('<path d="'+area+'" fill="var(--fill)"/>');
  bits.push('<path d="'+d+'" fill="none" stroke="var(--line)" stroke-width="1.7" stroke-linejoin="round"/>');
  if (NOW >= o.x0 && NOW <= o.x1) bits.push(
    '<line x1="'+px(NOW).toFixed(1)+'" x2="'+px(NOW).toFixed(1)+'" y1="'+T+'" y2="'+(H-B)+
    '" stroke="var(--dim)" stroke-width="1" stroke-dasharray="1 3"/>');
  for (const [t, anchor] of [[o.x0,'start'],[o.x1,'end']]) bits.push(
    '<text x="'+px(t).toFixed(1)+'" y="'+(H-4)+'" text-anchor="'+anchor+'">'+o.xfmt(t)+'</text>');
  bits.push('<line class=cx y1="'+T+'" y2="'+(H-B)+'" stroke="var(--dim)" stroke-dasharray="3 3" style="display:none"/>');
  bits.push('<circle class=dot r="2.8" fill="var(--line)" style="display:none"/>');

  const el = document.createElement('div');
  el.innerHTML = '<svg viewBox="0 0 '+W+' '+H+'">'+bits.join('')+'</svg><div class=rd>&nbsp;</div>';
  parent.appendChild(el);
  if (!o.series.length) return;
  const svg = el.querySelector('svg'), cx = el.querySelector('.cx'),
        dot = el.querySelector('.dot'), rd = el.querySelector('.rd');
  svg.addEventListener('mousemove', e => {
    const r = svg.getBoundingClientRect(), fx = (e.clientX - r.left) / r.width * W;
    let best = null, bd = 1e9;
    for (const q of o.series) { const dd = Math.abs(px(q[0]) - fx); if (dd < bd) { bd = dd; best = q; } }
    if (!best) return;
    cx.setAttribute('x1', px(best[0])); cx.setAttribute('x2', px(best[0])); cx.style.display = '';
    dot.setAttribute('cx', px(best[0])); dot.setAttribute('cy', py(best[1])); dot.style.display = '';
    rd.textContent = stamp(best[0]) + ' — ' + o.read(best[1]);
  });
  svg.addEventListener('mouseleave', () => {
    cx.style.display = 'none'; dot.style.display = 'none'; rd.innerHTML = '&nbsp;';
  });
}

// Burn rate over a trailing window, never across a gap: without both ends being
// real samples the "rate" is just the gap's total charged to one instant.
function rates(p, win) {
  const out = []; let a = 0;
  for (let i = 0; i < p.length; i++) {
    while (a + 1 < i && p[i][0] - p[a + 1][0] >= win) a++;
    const dt = p[i][0] - p[a][0];
    if (dt < win || dt > win * 3) continue;
    out.push([p[i][0], Math.max(0, (p[i][1] - p[a][1]) * 3600 / dt)]);
  }
  return out;
}

function section(id, title, sub) {
  const s = document.createElement('section');
  s.id = id;
  s.innerHTML = '<h2>' + title + '</h2>' + (sub ? '<div class=sub>' + sub + '</div>' : '');
  host.appendChild(s);
  return s;
}

let longest = 0;
for (const s of POOLS) {
  if (s.note) { section(s.id, s.label, '').innerHTML += '<div class=note>' + s.note + '</div>'; continue; }
  longest = Math.max(longest, s.len);
  const start = s.reset - s.len, pace = 100 / (s.len / 3600);
  const through = Math.min(100, Math.max(0, (NOW - start) / s.len * 100));
  const sec = section(s.id, s.label,
    s.p[s.p.length-1][1] + '% used · ' + through.toFixed(0) + '% through the window · resets ' + stamp(s.reset));

  chart(sec, {
    x0: start, x1: s.reset, y1: 100, series: s.p, fill: true,
    yticks: [0, 50, 100], fmt: v => v + '%', xfmt: clock,
    read: v => v + '% of the window',
  });
  const rr = rates(s.p, Math.max(1800, s.len / 48));
  chart(sec, {
    x0: start, x1: s.reset, h: 70,
    y1: Math.max(pace * 2, rr.reduce((m, q) => Math.max(m, q[1]), 0) * 1.15, 0.01),
    series: rr, ref: pace, refLabel: 'pace to use it all',
    yticks: [0], fmt: () => '%/h', xfmt: clock,
    read: v => v.toFixed(2) + ' %/h',
  });
}

// Today earns its place only when the long window is long enough for a day to
// vanish inside it. Same threshold the shell used to decide whether to gather
// the data, so the two cannot disagree.
if (TODAY && TODAY.length > 1 && longest >= TODAY_MIN) {
  const pool = POOLS.find(p => p.id === PRIMARY) || POOLS[0];
  const share = 100 / (pool.len / (DAY1 - DAY0));   // an even day of this window
  const pace = 100 / (pool.len / 3600);
  const used = TODAY[TODAY.length - 1][1];
  const sec = section('today', 'Today',
    used.toFixed(1) + '% of ' + pool.label + ' used since midnight · observed only, gaps under-count');
  chart(sec, {
    x0: DAY0, x1: DAY1, y1: Math.max(share * 1.25, used * 1.15, 0.01),
    series: TODAY, fill: true, ref: share, refLabel: 'an even day',
    yticks: [0], fmt: () => '%', xfmt: clock,
    read: v => v.toFixed(1) + '% of ' + pool.label,
  });
  const tr = rates(TODAY, 1800);
  chart(sec, {
    x0: DAY0, x1: DAY1, h: 70,
    y1: Math.max(pace * 2, tr.reduce((m, q) => Math.max(m, q[1]), 0) * 1.15, 0.01),
    series: tr, ref: pace, refLabel: 'pace to use it all',
    yticks: [0], fmt: () => '%/h', xfmt: clock,
    read: v => v.toFixed(2) + ' %/h',
  });
}
</script>
TAIL
  } > "$CHART_HTML.$$" && mv -f "$CHART_HTML.$$" "$CHART_HTML"
}

# ---- history ----------------------------------------------------------------

# History is keyed by window, and a window is only the same window if the model
# scope matches too: "Weekly" and "Weekly (Fable)" are different series.
win_id() {
  local id="${1:-limit}"
  [[ -n "${2:-}" && "$2" != "null" ]] && id="$1:$2"
  printf '%s' "${id//[^A-Za-z0-9_:.-]/_}"
}

# Which reset a sample belongs to, rounded to the nearest 5 minutes. The API
# jitters resets_at by a fraction of a second between fetches (21:00:00.234 one
# minute, 20:59:59.622 the next), and keying history on the raw epoch would
# start a fresh "cycle" on almost every sample. Real cycles are hours apart, so
# a 5-minute bucket cannot merge two of them.
cycle_key() {
  local e
  e=$(iso_to_epoch "${1:-}") || return 1
  printf '%s' $(( (e + 150) / 300 * 300 ))
}

# ---- fetch ------------------------------------------------------------------

if (( NOW >= backoff_until )); then
  creds=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)
  if [[ -z "$creds" ]]; then
    die "⚠️ claude" <<-EOF
	No Claude Code credentials in the login keychain. | $DIM
	Run 'claude' once to sign in, and allow keychain access. | $DIM
	EOF
  fi

  token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  expires=$(printf '%s' "$creds" | jq -r '(.claudeAiOauth.expiresAt // 0) | floor' 2>/dev/null)

  if [[ -z "$token" ]]; then
    die "⚠️ claude" <<-EOF
	Keychain entry found but it holds no OAuth access token. | $DIM
	You may be authenticated by API key rather than subscription. | $DIM
	EOF
  fi

  # expiresAt is milliseconds since the epoch. Only Claude Code may refresh it.
  if [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > 0 && expires / 1000 < NOW )); then
    last_error="token expired — run claude once"
    backoff_until=$(( NOW + 60 ))
  else
    # -H @- keeps the bearer token out of argv; -q ignores ~/.curlrc, and no -L
    # means a redirect can never replay the token to another host.
    response=$(printf 'Authorization: Bearer %s\n' "$token" \
      | curl -q -sS -H @- --proto '=https' --max-time 10 -w '\n%{http_code}' "$ENDPOINT" \
          -H "anthropic-beta: oauth-2025-04-20" \
          -H "User-Agent: claude-cli/$(ua_version) (external, cli)" 2>/dev/null)
    code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    case "$code" in
      200)
        if printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
          # Atomic: SwiftBar kills slow plugins, and a half-written cache would
          # otherwise parse as zeros and read as "plenty of quota left".
          printf '%s' "$body" > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
          fetched_at=$NOW; rl_fails=0; net_fails=0; backoff_until=0; last_error=""
          did_fetch=1
        else
          last_error="malformed response"
          backoff_until=$(( NOW + 60 ))
        fi
        ;;
      401|403)
        last_error="token rejected — run claude once"
        backoff_until=$(( NOW + 60 ))
        ;;
      429)
        # This endpoint rate-limits hard; 5 -> 10 -> 20 -> 30 min, then holds.
        (( rl_fails < 8 )) && rl_fails=$(( rl_fails + 1 ))
        step=$(( 300 * (1 << (rl_fails - 1)) ))
        (( step > 1800 )) && step=1800
        backoff_until=$(( NOW + step ))
        last_error="rate limited — retrying in $(human_delta "$step")"
        ;;
      *)
        # curl always writes the -w line, printing 000 when it never connected.
        (( net_fails < 10 )) && net_fails=$(( net_fails + 1 ))
        step=$(( 60 * net_fails ))
        (( step > 600 )) && step=600
        backoff_until=$(( NOW + step ))
        if [[ -z "$code" || "$code" == "000" ]]; then
          last_error="network error"
        else
          last_error="HTTP $code"
        fi
        ;;
    esac
  fi
  save_state
fi

# ---- render -----------------------------------------------------------------

# Non-empty is not the same as parseable: refuse to invent zeros from a corrupt
# cache, because 0% is the most reassuring thing this plugin can possibly say.
if [[ ! -s "$CACHE" ]] || ! jq -e . "$CACHE" >/dev/null 2>&1; then
  die "⚠️ usage" <<-EOF
	No readable usage data cached yet. | $DIM
	${last_error:-no successful fetch so far} | $DIM
	EOF
fi

# Every window the account actually has, in the order the API lists them, so a
# plan with buckets this script has never seen still renders. limits[] is the
# current shape; five_hour/seven_day is the older one kept as a fallback. The
# expression is kept total — an unexpected type yields -1 (rendered as unknown)
# rather than aborting jq part-way and truncating the window list silently.
rows=$(jq -r --arg sep "$SEP" '
  def pct: if type == "number" then floor else -1 end;
  if ((.limits // []) | length) > 0 then
    (.limits // [])[] | objects
    | [ ((.kind // "") | if . == "" then "limit" else . end),
        (.group // ""),
        (.percent | pct),
        (.resets_at // ""),
        (((.scope // {}) | objects | .model.display_name) // "") ]
  else
    ( {k: "session",    g: "session", p: (.five_hour.utilization? // null), r: (.five_hour.resets_at? // "")},
      {k: "weekly_all", g: "weekly",  p: (.seven_day.utilization? // null), r: (.seven_day.resets_at? // "")} )
    | [ .k, .g, (.p | pct), (.r // ""), "" ]
  end | map(tostring) | join($sep)' "$CACHE" 2>/dev/null)
jq_rc=$?

if [[ -z "$rows" ]]; then
  die "⚠️ usage" <<-EOF
	Response contained no recognisable limits. | $DIM
	Inspect $CACHE | $DIM
	EOF
fi

# One pass over the windows for both the write and the read: history is only
# useful if the key it is written under is the key it is looked up by, and two
# passes computing that key independently are how they drift apart.
#
# A window with no resets_at is skipped rather than filed under cycle 0. There
# is no cycle to chart it against, so a row for it would be dead weight in the
# file forever. Tabs are spelled out because they are the history file's field
# separator and an invisible one in a string literal is a trap.
samples=""
while IFS="$SEP" read -r kind group pct reset model; do
  [[ -z "$kind" ]] && continue
  [[ "$pct" =~ ^[0-9]+$ ]] || continue
  cycle=$(cycle_key "$reset") || continue
  id=$(win_id "$kind" "$model")
  samples+="$NOW"$'\t'"$id"$'\t'"$pct"$'\t'"$cycle"$'\n'
done <<< "$rows"

# Only on a fetch. SwiftBar re-renders on wake, on click and on every backed-off
# tick; stamping the cached numbers again with a fresh timestamp would flatten
# every rate that follows. The 0700 state directory is what keeps this private,
# same as the cache and the state file.
if (( did_fetch )) && [[ -n "$samples" ]]; then
  printf '%s' "$samples" >> "$HISTORY" 2>/dev/null

  # Same atomic dance as the cache: a half-written prune must never become the
  # history file. The temp name carries the pid because this one is a
  # read-modify-write — two overlapping runs sharing a temp path could
  # interleave their output, where the cache's whole-file writes cannot.
  if (( NOW - pruned_at > HIST_PRUNE_EVERY )); then
    awk -F'\t' -v c=$(( NOW - HIST_KEEP )) '$1 ~ /^[0-9]+$/ && $1 + 0 >= c' \
      "$HISTORY" > "$HISTORY.$$" 2>/dev/null && mv -f "$HISTORY.$$" "$HISTORY"
    pruned_at=$NOW
    save_state
  fi
fi

# The popover is rebuilt every render, because the click has to find it
# already there. Its return value is the set of pools it could chart.
write_chart_html || true

# Menu bar shows the short window and whichever long window is closest to
# biting — that is the number that will actually stop you, whether the plan
# calls it weekly, monthly, or something this script has not seen.
session_pct=""; long_pct=""; worst=0
while IFS="$SEP" read -r kind group pct reset model; do
  [[ -z "$kind" ]] && continue
  [[ "$pct" =~ ^[0-9]+$ ]] || continue
  (( pct > worst )) && worst=$pct
  if [[ "$group" == "session" || "$kind" == "session" ]]; then
    [[ -z "$session_pct" ]] && session_pct="$pct"
  elif [[ -z "$long_pct" ]] || (( pct > long_pct )); then
    long_pct="$pct"
  fi
done <<< "$rows"

age=$(( NOW - fetched_at ))
stale=""
{ (( fetched_at > 0 && age > 600 )) || [[ -n "$last_error" ]] || (( jq_rc != 0 )); } && stale="⋯"

color=""
(( worst >= 80 )) && color=" $WARN_COLOR"
(( worst >= 90 )) && color=" $CRIT_COLOR"

# Kept as narrow as the menu bar allows: bare numbers, no icon, no percent sign.
mb="$session_pct"
[[ -n "$session_pct" && -n "$long_pct" ]] && mb="${session_pct}·${long_pct}"
[[ -z "$session_pct" ]] && mb="$long_pct"
printf '%s%s | %s%s\n' "${mb:-?}" "$stale" "$FONT" "$color"

printf -- '---\n'
while IFS="$SEP" read -r kind group pct reset model; do
  [[ -z "$kind" ]] && continue
  pool_row "$(label_for "$kind" "$model")" "$pct" "$reset" "$(win_id "$kind" "$model")"
done <<< "$rows"

extra=$(jq -r '
  if (.extra_usage.is_enabled // false)
  then ((.extra_usage.utilization // 0) | floor | tostring)
  else empty end' "$CACHE" 2>/dev/null)
if [[ -n "$extra" ]]; then
  pool_row "Extra usage" "$extra" none ""
fi

printf -- '---\n'
# jq streams, so a mid-array error truncates the window list. Say so rather than
# presenting a short list as if it were complete.
(( jq_rc != 0 )) && printf '⚠️ some windows could not be read | %s\n' "$DIM"
if (( fetched_at == 0 )); then
  printf 'No successful fetch yet | %s\n' "$DIM"
elif [[ -n "$last_error" ]]; then
  printf '%s (data from %s ago) | %s\n' "$last_error" "$(human_delta "$age")" "$DIM"
else
  printf 'Updated %s ago | %s\n' "$(human_delta "$age")" "$DIM"
fi
printf 'Refresh now | refresh=true\n'
printf 'Reveal cached response | bash=/usr/bin/open param1=-R param2="%s" terminal=false\n' "$CACHE"
# An `if` rather than a `&&` chain: this is the last command in the script, and
# a false test would otherwise make the plugin exit non-zero on a first run.
if [[ -s "$HISTORY" ]]; then
  printf 'Reveal usage history | bash=/usr/bin/open param1=-R param2="%s" terminal=false\n' "$HISTORY"
fi
if [[ -s "$CHART_HTML" ]]; then
  printf 'Usage history charts | href=file://%s webview=true webvieww=%s webviewh=%s %s\n' \
    "$CHART_HTML" "$POPOVER_W" "$POPOVER_H" "$POOL_ROW"
fi
