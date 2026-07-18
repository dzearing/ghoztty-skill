#!/bin/bash
# ghoztty-banner.sh — keep a Ghoztty pane banner current for a Claude Code session.
#
# Banner layout: the title as an h4 heading on its own line (rendered
# slightly larger than the rows by a heading-aware Ghoztty), then the
# remaining fields as a key/value table (empty header row so the label
# column stays narrow) with bold labels below it:
#   #### <title>
#   |  |  |
#   |---|---|
#   | **Goal** | <goal> |
#   | **Status** | <status> · <activity> |
#   | **You asked** | <asked> |
#   | **What I did** | <did> |
#   | **PR** | [<url>](<url>) |
#
# "You asked"/"What I did" are model-provided paraphrases (set --asked/--did);
# each is auto-seeded from the raw prompt / last tool action as a fallback.
# The PR cell is a clickable markdown link. Fields persist in a per-tty state
# file, so each call only passes what changed.
# Delivery: ghoztty +set-banner CLI (multi-line + tables) targeting the
# cached/resolved pane name; falls back to a single-line OSC 7778 write to the
# tty device when the pane can't be resolved (the OSC parser drops newlines, so
# the table/multi-line form is CLI-only).
#
# Usage:
#   ghoztty-banner.sh set [--title T] [--goal G] [--status S] [--asked A] [--did D] [--pr URL]
#   ghoztty-banner.sh status <text>     # shorthand for set --status
#   ghoztty-banner.sh activity <text>   # hook-owned suffix (working/idle)
#   ghoztty-banner.sh prompt-hook       # UserPromptSubmit: seed "You asked", clear "What I did", activity=working
#   ghoztty-banner.sh stop-hook         # Stop: activity=idle + drop closed/merged PR
#   ghoztty-banner.sh posttool-hook     # PostToolUse: auto-seed "What I did" from stdin JSON
#   ghoztty-banner.sh clear
#
# Silently no-ops when not running inside Ghoztty.

set -u

[ "${TERM_PROGRAM:-}" = "ghostty" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

STATE_DIR="$HOME/.claude/ghoztty-banner"
mkdir -p "$STATE_DIR"

# Walk up the process tree until we find an ancestor with a controlling tty.
# (The hook shell and the Bash-tool shell have no tty; the claude process does.)
find_tty() {
    local pid=$$ t
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$t" ] && [ "$t" != "??" ]; then
            echo "$t"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    return 1
}

TTY_NAME=$(find_tty) || exit 0
STATE_FILE="$STATE_DIR/$TTY_NAME.json"

read_field() { # field
    [ -f "$STATE_FILE" ] && jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null
}

# Merge key/value pairs into the state file with a single jq call.
jq_merge() { # k1 v1 [k2 v2 ...]
    local cur='{}'
    [ -f "$STATE_FILE" ] && cur=$(cat "$STATE_FILE" 2>/dev/null) && [ -n "$cur" ] || cur='{}'
    local prog='.' i=0 jqargs=()
    while [ $# -ge 2 ]; do
        i=$((i + 1))
        prog="$prog | .[\$k$i] = \$v$i"
        jqargs+=(--arg "k$i" "$1" --arg "v$i" "$2")
        shift 2
    done
    echo "$cur" | jq "${jqargs[@]}" "$prog" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# Strip control characters that would corrupt an OSC sequence or IPC payload.
sanitize() {
    printf '%s' "$1" | tr -d '\000-\037' | tr -d '\177'
}

# Escape unescaped pipes so a value can't break out of its table cell.
esc_cell() {
    printf '%s' "$1" | sed 's/|/\\|/g'
}

# Render a PR URL as a clickable markdown link whose visible text is the URL.
pr_link() {
    printf '[%s](%s)' "$1" "$1"
}

send_osc() { # single-line text
    printf '\033]7778;%s\007' "$1" > "/dev/$TTY_NAME" 2>/dev/null
}

# Resolve this tty to a registered pane name. Order: cached name (validated
# against the live pane list), then +list --tty (works for non-persistence
# panes; session-persistence panes report an empty tty until the
# Remote.zig getProcessInfo TODO is fixed). Caches on success.
resolve_pane() {
    command -v ghoztty >/dev/null 2>&1 || return 1
    local cached pane list
    cached=$(read_field pane)
    list=$(ghoztty +list --json 2>/dev/null) || return 1
    if [ -n "$cached" ] && echo "$list" | jq -e --arg n "$cached" \
        'any(.. | objects; .name? == $n)' >/dev/null 2>&1; then
        echo "$cached"
        return 0
    fi
    pane=$(ghoztty +list --tty="$TTY_NAME" 2>/dev/null) && [ -n "$pane" ] || return 1
    jq_merge pane "$pane"
    echo "$pane"
}

render() {
    local title goal status activity asked did pr
    title=$(read_field title)
    goal=$(read_field goal)
    status=$(read_field status)
    activity=$(read_field activity)
    asked=$(read_field asked)
    did=$(read_field did)
    pr=$(read_field pr)

    # Nothing meaningful set yet (only activity): don't paint a banner.
    if [ -z "$title$goal$status$asked$did$pr" ]; then
        return 0
    fi

    local statline="$status"
    if [ -n "$activity" ]; then
        [ -n "$statline" ] && statline="$statline · $activity" || statline="$activity"
    fi

    local pane
    if pane=$(resolve_pane) && [ -n "$pane" ]; then
        # CLI path ("\n" converted to newlines by the IPC server): the title
        # is the table's bold header cell so its divider sits flush beneath
        # it — no blank header row, no paragraph gap.
        local rows=""
        add_row() { # label value
            [ -n "$2" ] || return 0
            rows="$rows\n| **$1** | $(esc_cell "$2") |"
        }
        add_row "Goal" "$goal"
        add_row "Status" "$statline"
        add_row "You asked" "$asked"
        add_row "What I did" "$did"
        [ -n "$pr" ] && rows="$rows\n| **PR** | $(pr_link "$pr") |"

        # Title as an h4 heading on its own line above the table (a
        # heading-aware Ghoztty renders it slightly larger than the rows).
        # The table keeps an empty header row so its label column stays as
        # narrow as the labels.
        local text=""
        [ -n "$title" ] && text="#### $title"
        if [ -n "$rows" ]; then
            [ -n "$text" ] && text="$text\n"
            text="$text|  |  |\n|---|---|$rows"
        fi
        ghoztty +set-banner --target="$pane" "$text" >/dev/null 2>&1 && return 0
    fi

    # OSC fallback: single line (no newlines/tables), bold title + labels.
    local line="" sep=" · "
    [ -n "$title" ] && line="**$title**"
    add_seg() { # label value
        [ -n "$2" ] || return 0
        [ -n "$line" ] && line="$line$sep"
        line="$line**$1:** $2"
    }
    add_seg "Goal" "$goal"
    add_seg "Status" "$statline"
    add_seg "You asked" "$asked"
    add_seg "What I did" "$did"
    [ -n "$pr" ] && { [ -n "$line" ] && line="$line$sep"; line="$line**PR:** $(pr_link "$pr")"; }
    send_osc "$line"
}

cmd="${1:-}"
shift 2>/dev/null || true

case "$cmd" in
set)
    pairs=()
    newtitle=""; newtitle_set=0; pr_set=0; did_set=0
    while [ $# -gt 0 ]; do
        case "$1" in
        --title)  newtitle=$(sanitize "${2:-}"); newtitle_set=1; pairs+=(title "$newtitle"); shift 2 ;;
        --goal)   pairs+=(goal "$(sanitize "${2:-}")"); shift 2 ;;
        --status) pairs+=(status "$(sanitize "${2:-}")"); shift 2 ;;
        --asked)  pairs+=(asked "$(sanitize "${2:-}")"); shift 2 ;;
        --did)    did_set=1; pairs+=(did "$(sanitize "${2:-}")"); shift 2 ;;
        --pr)     pr_set=1; pairs+=(pr "$(sanitize "${2:-}")"); shift 2 ;;
        --title=*)  newtitle=$(sanitize "${1#*=}"); newtitle_set=1; pairs+=(title "$newtitle"); shift ;;
        --goal=*)   pairs+=(goal "$(sanitize "${1#*=}")"); shift ;;
        --status=*) pairs+=(status "$(sanitize "${1#*=}")"); shift ;;
        --asked=*)  pairs+=(asked "$(sanitize "${1#*=}")"); shift ;;
        --did=*)    did_set=1; pairs+=(did "$(sanitize "${1#*=}")"); shift ;;
        --pr=*)     pr_set=1; pairs+=(pr "$(sanitize "${1#*=}")"); shift ;;
        *) shift ;;
        esac
    done
    # A changed title means a new task: drop fields that would otherwise
    # linger from the previous one (a stale PR link, the old "What I did"),
    # but never clobber a value passed explicitly in this same call.
    if [ "$newtitle_set" = 1 ] && [ "$newtitle" != "$(read_field title)" ]; then
        [ "$pr_set" = 1 ]  || pairs+=(pr "")
        [ "$did_set" = 1 ] || pairs+=(did "")
    fi
    [ ${#pairs[@]} -gt 0 ] && jq_merge "${pairs[@]}"
    render
    ;;
status)
    jq_merge status "$(sanitize "${1:-}")"
    render
    ;;
activity)
    jq_merge activity "$(sanitize "${1:-}")"
    render
    ;;
prompt-hook)
    # Seed "You asked" with the raw prompt (first line, truncated) as a
    # default the model refines into a paraphrase during the turn.
    input=$(cat)
    asked=$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null | head -n1)
    asked=$(sanitize "$asked")
    [ ${#asked} -gt 100 ] && asked="${asked:0:97}..."
    # A new ask starts fresh: clear "What I did" so the previous turn's work
    # isn't shown until something new actually happens this turn.
    if [ -n "$asked" ]; then
        jq_merge activity "working" did "" asked "$asked"
    else
        jq_merge activity "working" did ""
    fi
    render
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"This session runs in a Ghoztty pane with a persistent status banner. Keep it current: run `~/.claude/scripts/ghoztty-banner.sh set --title '<short task title>' --goal '<current goal>' --status '<one-line progress note>' [--asked '<paraphrase of what the user last asked>'] [--did '<paraphrase of the last thing you did>'] [--pr <url>]` when a task starts, whenever the goal/status meaningfully changes, and when a PR is created. Keep --asked and --did as short human-readable paraphrases (not raw tool names); refresh --did as you finish meaningful steps. Fields persist between calls — pass only what changed (e.g. `... set --status 'tests passing' --did 'wrote the docs'`)."}}
EOF
    ;;
stop-hook)
    jq_merge activity "idle"
    render
    # Best-effort: drop a PR link once it's no longer open (closed/merged),
    # so the banner never shows a stale PR. GitHub + gh only; silent on any
    # failure (no gh, not authed, non-GitHub host, network error).
    pr=$(read_field pr)
    if [ -n "$pr" ] && command -v gh >/dev/null 2>&1; then
        case "$pr" in
        *github.com*)
            state=$(gh pr view "$pr" --json state -q .state 2>/dev/null)
            if [ -n "$state" ] && [ "$state" != "OPEN" ]; then
                jq_merge pr ""
                render
            fi
            ;;
        esac
    fi
    ;;
posttool-hook)
    input=$(cat)
    # Never let our own banner update overwrite a paraphrase just set.
    case "$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)" in
        *ghoztty-banner.sh*) exit 0 ;;
    esac
    # Auto-seed "What I did" with the raw tool action; the model refines it
    # into a paraphrase via `set --did` at meaningful checkpoints.
    did=$(echo "$input" | jq -r '
        .tool_name as $t
        | if $t == "Bash" then
            ($t + ": " + (.tool_input.description // .tool_input.command // ""))
          elif (.tool_input.file_path // "") != "" then
            ($t + ": " + (.tool_input.file_path | split("/") | last))
          else
            $t
          end' 2>/dev/null)
    [ -n "$did" ] || exit 0
    did=$(sanitize "$did")
    [ ${#did} -gt 80 ] && did="${did:0:77}..."
    jq_merge did "$did"
    render
    ;;
clear)
    pane=$(resolve_pane)
    rm -f "$STATE_FILE"
    [ -n "$pane" ] && ghoztty +set-banner --target="$pane" --clear >/dev/null 2>&1
    send_osc ""
    ;;
*)
    echo "usage: ghoztty-banner.sh set|status|activity|prompt-hook|stop-hook|posttool-hook|clear" >&2
    exit 2
    ;;
esac
exit 0
