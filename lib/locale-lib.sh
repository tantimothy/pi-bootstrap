#!/usr/bin/env bash
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
#
# Sourced (not called in a subshell) so LANG/LC_ALL land in the caller's
# own shell — the one that actually goes on to invoke dialog/less/echo.
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
_ensure_utf8_locale
