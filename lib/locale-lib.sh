#!/usr/bin/env bash
# Shared guard for the two things every dialog/less-based entry point in
# this repo silently assumes about the environment it inherits, neither of
# which is reliably true: a UTF-8 locale, and an Escape key that responds
# in less than a second. Both are forced here, so sourcing this one file
# is all any entry point needs to do about either.
#
# Sourced (not called in a subshell) so the exports land in the caller's
# own shell — the one that actually goes on to invoke dialog/less/echo.

# --- 1. UTF-8 locale -------------------------------------------------------
#
# Every entry point in this repo prints emoji, arrows (→), and em-dashes
# (—) freely — in dialog forms, INFO output, and deploy progress text — on
# the assumption the terminal decodes UTF-8. That assumption breaks without
# a UTF-8 locale active: bash/less/dialog all fall back to interpreting
# each byte of a multi-byte character separately instead of as one glyph,
# which is exactly what produces raw hex-byte escapes (<F0><9F><93><81>) in
# paged output and dialog's own "Text has extra characters" complaint in
# --msgbox/--form text (confirmed directly: a real macOS deploy.sh session
# with no LANG/LC_ALL set hit both). Some shells genuinely don't have a
# UTF-8 locale set — a bare `sh script.sh` invocation, certain
# non-interactive/launchd/cron contexts, some SSH sessions without locale
# forwarding — rather than assume one is, force one here.
_ensure_utf8_locale() {
    # Already UTF-8 (either var set with that suffix, any case) — nothing to do.
    case "${LC_ALL:-}${LANG:-}" in
        *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return 0 ;;
    esac

    # `locale charmap` (not `locale -a`'s listing, whose exact string
    # format varies a lot more between macOS and Linux) is the portable way
    # to ask whether a given locale name actually resolves to a UTF-8
    # charmap on THIS system — try the common names in order until one does.
    local candidate
    for candidate in en_US.UTF-8 C.UTF-8 C.utf8; do
        if LC_ALL="$candidate" locale charmap 2>/dev/null | grep -qi '^utf-8$'; then
            export LANG="$candidate" LC_ALL="$candidate"
            return 0
        fi
    done

    # None of the candidates exist on this system (locale -a itself can be
    # missing on a stripped-down container) — leave LANG/LC_ALL untouched
    # rather than export a locale that doesn't actually exist, which would
    # just make every subsequent command print its own "locale: Cannot set
    # LC_ALL" warning on top of the original garbling.
    return 1
}

# --- 2. Escape key latency -------------------------------------------------
#
# Escape (0x1b) is also the first byte of every arrow key, function key,
# and other \e[... sequence, so a key parser that has just read a lone \e
# cannot yet tell "the user pressed Esc" from "the rest of an arrow key is
# still in flight" — it has to wait. dialog is an ncurses program, and
# ncurses waits ESCDELAY milliseconds, which defaults to a full 1000. That
# is the entire reason Esc in deploy.sh's menus feels broken while Ctrl-C
# feels instant: Ctrl-C is an unambiguous single byte handled by the tty
# line discipline as SIGINT, so nothing anywhere has to wait to see whether
# more of it is coming.
#
# tmux's own `escape-time` is a SEPARATE wait on the same keystroke, and
# setting it to 0 does not help on its own — tmux then just hands the \e
# through sooner and ncurses starts its own second-long timer. Both layers
# have to be lowered; the tmux half lives in every .tmux.conf this repo
# deploys — mac-terminal-setup's and pi-barebones' on the host, and the
# in-container ones for aider, claude-cli, codex-cli and nanoclaw-mnemon,
# whose tmux stacks its own wait on top of the host's. In-container menus need their
# own copy of this export (kali-pentest's entrypoint.sh, dragonos-sdr's
# sdr-menu.sh) because nothing under lib/ is copied into an image, and the
# host's environment doesn't cross the container boundary either.
#
# ncurses reads $ESCDELAY once at initscr() time and dialog exposes no
# command-line flag for it, so exporting it before dialog runs is both
# necessary and sufficient.
_ensure_fast_escape() {
    # An explicit value the caller already chose wins — including a
    # deliberate `ESCDELAY=1000 ./deploy.sh` to get the old behaviour back.
    [ -n "${ESCDELAY:-}" ] && return 0

    # 25ms, not 0. A real "\e[A" normally arrives in a single read, but over
    # ssh (or on a loaded Pi) its bytes genuinely can split across reads,
    # and a zero timeout turns every arrow key into Escape followed by a
    # literal "[A" typed into the menu. 25ms is well under the ~100ms at
    # which a delay starts to feel like lag, and well over the transit time
    # of the two bytes already on their way.
    export ESCDELAY=25
}

_ensure_utf8_locale
_ensure_fast_escape
