#!/bin/bash
#
# <bitbar.title>Claude Code Usage</bitbar.title>
# <bitbar.version>1.2.0</bitbar.version>
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

# Field separator between jq and the read loops. Deliberately NOT a tab: tab is
# an IFS whitespace character, so bash collapses runs of them and an empty field
# (a limits[] entry with no "group") would silently shift every later column.
SEP=$'\x1f'

# The menu bar title carries no colour below 80%, so macOS inverts it when the
# menu opens; the warn and crit shades below deliberately override that.
FONT="font=Menlo size=12"

# Dropdown rows carry an explicit colour, and not only for contrast: SwiftBar
# gives a line a click target only when it has an action *or* a colour
# (configureAction in MenuBarItem.swift), and AppKit greys out a menu item whose
# target is nil. A plain uncoloured text row therefore renders as a disabled
# item — washed out next to SwiftBar's own entries. Pairs are light,dark.
#
# trim=false is what makes the indentation below real: SwiftBar strips leading
# whitespace from a title unless asked not to (MenuBarItem.swift), so every
# padded row would otherwise collapse against the left margin and the columns
# would line up only in the source. Both sizes are 12 for the same reason — one
# monospace grid, or the padding means a different width on each row.
ROW="font=Menlo size=12 color=#1d1d1f,#f5f5f7 trim=false"
DIM="font=Menlo size=12 color=#5f5f66,#a8a8b0 trim=false"

# Amber and red at the menu bar, darkened for the light menu bar where the
# system shades are too pale to read.
WARN_COLOR="color=#b35a00,#ff9f0a"   # >= 80%
CRIT_COLOR="color=#bf2d24,#ff453a"   # >= 90%

# Everything under a window label starts in the same column as its meter:
# 18 for the label field, then the width of the " %3d%% " that precedes a bar.
PAD="                        "

mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
NOW=$(date +%s)

# ---- helpers ----------------------------------------------------------------

fetched_at=0; backoff_until=0; rl_fails=0; net_fails=0; last_error=""

# Parsed, never sourced: a truncated or tampered state file must not become
# shell code, and must not wedge the plugin under `set -u`.
if [[ -f "$STATE" ]]; then
  while IFS='=' read -r k v; do
    case "$k" in
      fetched_at|backoff_until|rl_fails|net_fails)
        [[ "$v" =~ ^[0-9]+$ ]] && printf -v "$k" '%s' "$v" ;;
      last_error)
        last_error="$v" ;;
    esac
  done < "$STATE"
fi

# A clock jump forward would otherwise persist a deadline we never reach; 1800s
# is the longest backoff this script ever sets, so anything beyond it is bogus.
(( backoff_until > NOW + 1800 )) && backoff_until=0

save_state() {
  printf 'fetched_at=%s\nbackoff_until=%s\nrl_fails=%s\nnet_fails=%s\nlast_error=%s\n' \
    "$fetched_at" "$backoff_until" "$rl_fails" "$net_fails" "${last_error//[$'\n'|]/ }" \
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
meter_row() {
  local label="${1//[|$'\n']/ }" pct="${2:-}"
  if [[ "$pct" =~ ^[0-9]+$ ]]; then
    printf '%-18s %3d%% %s | %s\n' "$label" "$pct" "$(meter "$pct")" "$ROW"
  else
    printf '%-18s   ?%% unreadable | %s\n' "$label" "$ROW"
  fi
}

window_row() {
  local epoch delta
  meter_row "$1" "$2"
  if epoch=$(iso_to_epoch "${3:-}"); then
    delta=$(( epoch - NOW ))
    printf '%sresets in %s  (%s) | %s\n' "$PAD" "$(human_delta "$delta")" \
      "$(date -r "$epoch" '+%a %H:%M')" "$DIM"
  else
    printf '%sno active window | %s\n' "$PAD" "$DIM"
  fi
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
first=1
while IFS="$SEP" read -r kind group pct reset model; do
  [[ -z "$kind" ]] && continue
  (( first )) || printf -- '---\n'
  first=0
  window_row "$(label_for "$kind" "$model")" "$pct" "$reset"
done <<< "$rows"

extra=$(jq -r '
  if (.extra_usage.is_enabled // false)
  then ((.extra_usage.utilization // 0) | floor | tostring)
  else empty end' "$CACHE" 2>/dev/null)
if [[ -n "$extra" ]]; then
  printf -- '---\n'
  meter_row "Extra usage" "$extra"
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
