#!/usr/bin/env bash
# Apply the local fixes to jaxparrow07's Nothing KDE Widgets.
#
#   ./patches/apply-upstream-patches.sh            apply (idempotent)
#   ./patches/apply-upstream-patches.sh --revert   restore the unpatched files
#   ./patches/apply-upstream-patches.sh --check    report status, change nothing
#
# Why patches and not vendored files: step 2 (20-upstream) clones the widget
# pack from GitHub and installs it with kpackagetool6 on every run, so anything
# edited under ~/.local/share/plasma/plasmoids/com.jaxparrow07.* is replaced by
# the next install. These two fixes are upstream bugs, not rice customisation, so
# they are kept as unified diffs against upstream's main.qml and re-applied.
#
#   battery  The powermanagement data engine is push-based. On a machine with no
#            battery no Solid signal ever fires, onNewData never runs, and the
#            "Detecting Battery..." spinner never stops. A Timer now drives the
#            check instead of waiting for a signal. The 200x200 card also
#            collapses when there is nothing to show, instead of leaving an
#            empty black rectangle on the desktop.
#   weather  XMLHttpRequest had no timeout, so an unreachable API left the
#            widget on "Loading..." forever. Both requests now time out.
#            (The widget still does not render errorMessage; that is upstream's
#            gap and changing it would mean redesigning the card.)
set -euo pipefail

PLASMOIDS="$HOME/.local/share/plasma/plasmoids"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Upstream's own version of the file, kept next to the diff so --revert works
# without a network round-trip. Missing is not fatal; it only disables revert.
ORIG="$HERE/orig"
STATE="$PLASMOIDS"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
step() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m!! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
have patch || die "the 'patch' utility is missing (pacman -S patch / apt install patch)"

MODE=apply
case "${1:-}" in
    --revert) MODE=revert ;;
    --check)  MODE=check ;;
    "")       ;;
    *)        die "unknown option '$1' (try --revert or --check)" ;;
esac

# widget package name -> patch file. Both patches touch contents/ui/main.qml.
WIDGETS=(
    com.jaxparrow07.nothingkdewidgets.battery
    com.jaxparrow07.nothingkdewidgets.weather
)

# Already applied? Look for a comment each patch introduces, in the given
# main.qml. Checking a marker rather than "does patch --dry-run succeed" keeps
# this true after an upstream release changes the surrounding lines.
#   is_patched <package-name> <path-to-main.qml>
is_patched() {
    local pkg="$1" f="$2"
    case "$pkg" in
        *battery) grep -q 'Battery presence check' "$f" 2>/dev/null ;;
        *weather) grep -q 'Forecast request timed out' "$f" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

for pkg in "${WIDGETS[@]}"; do
    dir="$PLASMOIDS/$pkg"
    patchfile="$HERE/$pkg.qml.patch"
    target="$dir/contents/ui/main.qml"
    marker="$dir/.nothing-rice-patched"
    fm=contents/ui/main.qml

    say "$pkg"

    if [ ! -d "$dir" ]; then
        warn "not installed -- run ./install.sh 20 first"
        continue
    fi
    if [ ! -f "$target" ]; then
        warn "no $fm in $dir -- upstream layout changed, patch skipped"
        continue
    fi

    case "$MODE" in
        check)
            if is_patched "$pkg" "$target"; then
                step "patched"
            elif [ -f "$marker" ]; then
                warn "marked patched but the fix is absent -- upstream replaced the file; re-run without --check"
            else
                warn "NOT patched"
            fi
            continue
            ;;
        revert)
            if [ ! -f "$marker" ]; then
                step "not patched, nothing to revert"
                continue
            fi
            case "$pkg" in
                *battery) upstream="$ORIG/$pkg/contents/ui/main.qml" ;;
                *weather) upstream="$ORIG/$pkg/contents/ui/main.qml" ;;
            esac
            if [ -f "$upstream" ]; then
                cp "$upstream" "$target"
                rm -f "$marker"
                step "restored upstream $fm"
            elif patch -p1 -R --dry-run -d "$dir" <"$patchfile" >/dev/null 2>&1; then
                patch -p1 -R -d "$dir" <"$patchfile"
                rm -f "$marker"
                step "reversed the patch"
            else
                warn "cannot revert: no pristine copy at $upstream and the reverse patch does not apply."
                warn "Re-install the widget instead: ./install.sh 20"
            fi
            continue
            ;;
    esac

    # --- apply ---
    if is_patched "$pkg" "$target"; then
        step "already patched"
        touch "$marker"
        continue
    fi

    if ! patch -p1 --dry-run -d "$dir" <"$patchfile" >/dev/null 2>&1; then
        warn "patch does not apply to the installed $fm."
        warn "Upstream has probably changed it. Re-port patches/$pkg.qml.patch"
        warn "(it is a unified diff against the installed file) and try again."
        continue
    fi

    # Keep one pristine copy per package so --revert works offline.
    mkdir -p "$ORIG/$pkg/contents/ui"
    [ -f "$ORIG/$pkg/contents/ui/main.qml" ] || cp "$target" "$ORIG/$pkg/contents/ui/main.qml"

    patch -p1 -d "$dir" <"$patchfile" >/dev/null
    touch "$marker"
    step "patched $fm"
done

if [ "$MODE" != check ]; then
    cat <<'MSG'

Plasma caches QML per process, so reload the shell to see it:
    kquitapp6 plasmashell && setsid kstart plasmashell >/dev/null 2>&1 &
MSG
fi
