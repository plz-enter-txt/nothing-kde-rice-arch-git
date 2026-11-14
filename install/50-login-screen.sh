#!/usr/bin/env bash
# Step 5 -- the SDDM login screen. MUST be run with sudo.
#     sudo ./install/50-login-screen.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "$(id -u)" -eq 0 ] || die "run this one with sudo"
USERHOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
THEMES=/usr/share/sddm/themes
DEST="$THEMES/Nothing"

say "Fonts, system-wide"
# SDDM runs as the unprivileged 'sddm' user and cannot read anyone's $HOME.
# A theme that references NType 82 from ~/.local renders in a fallback face.
if [ -d "$USERHOME/.local/share/fonts/nothing" ]; then
    install -d /usr/local/share/fonts/nothing
    # The source faces are listed first: --no-dereference would copy a symlink
    # as a symlink, and a dangling one in the system font directory is worse
    # than no font at all.
    cp --no-dereference "$USERHOME"/.local/share/fonts/nothing/*.otf \
       "$USERHOME"/.local/share/fonts/nothing/*.ttf /usr/local/share/fonts/nothing/ 2>/dev/null || true
    chmod 644 /usr/local/share/fonts/nothing/*
    fc-cache -f /usr/local/share/fonts >/dev/null
    step "$(ls /usr/local/share/fonts/nothing | wc -l) faces in /usr/local/share/fonts/nothing"
    # The login screen asks for the family "NType 82 Mono" by name, which the
    # widget pack does not necessarily ship under that name (it is often just
    # "NType 82" with a Bold). When the exact family is missing the monospace
    # labels fall back to whatever the system picks -- point it out instead of
    # letting the user hunt for it at the greeter.
    if have fc-list && ! fc-list : family 2>/dev/null | grep -q 'NType 82 Mono'; then
        warn "no installed font advertises the family 'NType 82 Mono':"
        warn "  the greeter's monospace labels will render in a system face."
    fi
else
    warn "no Nothing fonts found -- run step 2 first"
fi

say "Installing the theme"
[ -d "$DEST" ] && cp -a "$DEST" "$DEST.bak.$(date +%Y%m%d-%H%M%S)"
rm -rf "$DEST"
cp -r "$REPO/sddm/Nothing" "$DEST"

# The repo does not vendor a 4 MB wallpaper; take the one already installed.
WALL=$(find "$USERHOME/.local/share/wallpapers/Nothing2" -path '*/contents/images/*' -type f 2>/dev/null | sort | tail -1)
if [ -n "$WALL" ]; then
    cp "$WALL" "$DEST/background.png"
    step "background from $(basename "$WALL")"
else
    warn "Nothing2 wallpaper not found -- falling back to a flat colour"
    sed -i 's/^type=.*/type=color/' "$DEST/theme.conf"
fi

# SDDM wants an avatar directory to exist even when the theme shows no avatars.
install -d "$DEST/faces"
chown -R root:root "$DEST"
chmod -R a+rX "$DEST"

say "Validating the QML before it can lock you out"
# An unknown property anywhere in the theme makes SDDM silently swap in the
# stock greeter -- the theme just "doesn't apply" with no visible error.
# Kubuntu's qt6 tools live under /usr/lib/qt6/bin; Arch puts them in /usr/bin.
QMLLINT=$(ls /usr/lib/qt6/bin/qmllint 2>/dev/null || command -v qmllint 2>/dev/null || true)
if [ -z "$QMLLINT" ] && [ "$PKG" = pacman ]; then
    sudo pacman -S --needed --noconfirm qt6-declarative 2>/dev/null || true
    QMLLINT=$(ls /usr/lib/qt6/bin/qmllint 2>/dev/null || command -v qmllint 2>/dev/null || true)
fi
# The qmllint below runs as the invoking user (sudo -E keeps the umask and
# PATH, not the privilege). Re-assert the read bits so a restrictive umask on
# this machine cannot make the linter's EACCES read as a theme problem.
chmod -R a+rX "$DEST"
if [ -n "$QMLLINT" ]; then
    bad=0
    for f in "$DEST"/*.qml; do
        out=$("$QMLLINT" "$f" 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ] || grep -q '^Error' <<<"$out"; then
            warn "QML error in $(basename "$f")"; bad=1
        fi
    done
    [ "$bad" -eq 0 ] && step "no QML errors" || die "fix the theme before activating it"
else
    warn "qmllint not found (Arch: sudo pacman -S qt6-declarative) -- skipping validation"
fi

say "Checking the sddm user can resolve the fonts"
# fc-match runs as the greeter user from the greeter's own home directory:
# on Arch that is /var/lib/sddm, mode 0750, so a plain `sudo -u sddm fc-match`
# fails with EPERM on the working directory and says nothing about the fonts.
FCM_DIR=""
for d in '$HOME' /tmp; do     # literal: expanded by the sh -c below, by that user
    if sudo -u sddm sh -c "cd $d && exec fc-match --version" >/dev/null 2>&1; then
        FCM_DIR=$d; break
    fi
done
[ -n "$FCM_DIR" ] || warn "cannot run fc-match as the sddm user -- skipping"
for f in "NType 82" "NType 82 Mono" "Nothing Font (5x7)"; do
    [ -n "$FCM_DIR" ] || break
    got=$(sudo -u sddm sh -c "cd $FCM_DIR && exec fc-match --format='%{file}\n' \"\$1\"" _ "$f" 2>/dev/null)
    if [ -z "$got" ]; then
        got="(could not check)"
    elif ! grep -qiE 'ntype|nothing' <<<"$got"; then
        got="$got  <-- not a Nothing face"
    fi
    printf '    %-22s -> %s\n' "$f" "$got"
done

say "Activating"
CONF=/etc/sddm.conf.d/kde_settings.conf
install -d /etc/sddm.conf.d
if [ -f "$CONF" ] && grep -q '^\[Theme\]' "$CONF"; then
    grep -q '^Current=' "$CONF" && sed -i 's/^Current=.*/Current=Nothing/' "$CONF" \
                                || sed -i '/^\[Theme\]/a Current=Nothing' "$CONF"
else
    printf '[Theme]\nCurrent=Nothing\n' >> "$CONF"
fi
grep -A1 '^\[Theme\]' "$CONF" | sed 's/^/    /'

cat <<'MSG'

Done. The new login screen appears at your next reboot.
Apply it now with:  sudo systemctl restart sddm   (this ends your session)

If it ever misbehaves, switch to a TTY with Ctrl+Alt+F3 and run:
    sudo sed -i 's/^Current=Nothing/Current=breeze/' /etc/sddm.conf.d/kde_settings.conf
    sudo systemctl restart sddm

To confirm the theme really loaded (rather than silently falling back):
    journalctl -b -u sddm | grep -i "Fallback to embedded theme"
  Any hit there means SDDM rejected the theme and used the stock greeter.
MSG
