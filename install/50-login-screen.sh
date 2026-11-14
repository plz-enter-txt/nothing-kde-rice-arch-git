#!/usr/bin/env bash
# Step 5 -- the SDDM login screen. MUST be run with sudo.
#     sudo ./install/50-login-screen.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "$(id -u)" -eq 0 ] || die "run this one with sudo"
# Who owns the fonts and avatar to install. Under sudo that is SUDO_USER; under
# pkexec neither SUDO_USER nor $USER names a human ($USER is root), so fall back
# to the caller pkexec records in PKEXEC_UID, then to the first regular user.
if [ -z "${TARGET_USER:-}" ]; then
    for u in "${SUDO_USER:-}" "$(getent passwd "${PKEXEC_UID:-0}" 2>/dev/null | cut -d: -f1)" \
             "$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)"; do
        [ -n "$u" ] && [ "$u" != "root" ] && { TARGET_USER=$u; break; }
    done
fi
[ -n "${TARGET_USER:-}" ] || die "cannot tell which user's fonts/avatar to install; run with TARGET_USER=\$USER"
USERHOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
step "target user: $TARGET_USER ($USERHOME)"
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

# The theme draws one circular avatar above the username prompt. The crop is
# baked into the PNG rather than done with OpacityMask, because importing
# Qt5Compat.GraphicalEffects into a second QML file is one more way for the
# greeter to fail silently and fall back to the stock theme.
install -d "$DEST/faces"
FACESRC=""
for c in "/var/lib/AccountsService/icons/$TARGET_USER" \
         "$USERHOME/.face.icon" \
         "/var/lib/AccountsService/icons/$(id -nu 1000 2>/dev/null)"; do
    [ -f "$c" ] && { FACESRC="$c"; break; }
done
if [ -n "$FACESRC" ]; then
    if have magick || have convert; then
        IM=$(have magick && echo magick || echo convert)
        # 256x256 square crop, then a white circle as the alpha mask.
        "$IM" "$FACESRC" -resize 256x256^ -gravity center -extent 256x256 \
              \( +clone -alpha extract \
                 -draw 'fill black polygon 0,0 0,256 256,256 256,0 fill white circle 128,128 128,0' \
                 \( +clone -flip \) -compose Multiply -composite \
                 \( +clone -flop \) -compose Multiply -composite \) \
              -alpha off -compose CopyOpacity -composite "$DEST/faces/.face.icon" \
            && step "avatar: $(basename "$FACESRC") -> circular 256x256"
    else
        cp "$FACESRC" "$DEST/faces/.face.icon"
        warn "imagemagick missing -- avatar copied uncropped (the theme will square it)"
    fi
else
    warn "no avatar found for $TARGET_USER -- the login prompt shows a plain ring."
    warn "  set one in System Settings -> Users, then re-run this step"
fi

chown -R root:root "$DEST"
chmod -R a+rX "$DEST"

say "Validating the theme before it can lock you out"
# Measured on this machine, greeter --test-mode DOES catch the errors that
# actually break a theme: it printed "Login.qml:102: ReferenceError: faceSize is
# not defined" for a real broken build. What it cannot see is a theme file that
# is never instantiated, which is why every *.qml is compiled below, not just
# Main.qml. QT_FORCE_STDERR_LOGGING is what puts those lines on the terminal;
# without it there is no output at all and "no output" looks like success.
chmod -R a+rX "$DEST"

GREETER=$(command -v sddm-greeter-qt6 || command -v sddm-greeter || true)
glog=$(mktemp)
[ -n "$GREETER" ] || warn "sddm-greeter not found -- cannot verify the theme by loading it"

if [ -n "$GREETER" ]; then
    QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
        timeout 15 "$GREETER" --test-mode --theme "$DEST" >"$glog" 2>&1 || true
    # NB: a grep with no match exits 1, and an assignment whose command
    # substitution failed aborts the script under set -e -- hence `|| true`.
    bad=$(grep -iE 'ReferenceError|TypeError|is not defined|is not a type|Unable to assign|Expected token|SyntaxError|Failed to load|QQmlApplicationEngine failed' "$glog" \
          | grep -v 'diskcache' | sort -u | head -8 || true)
    if [ -n "$bad" ]; then
        printf '%s\n' "$bad" | sed 's/^/      /'
        rm -f "$glog"
        die "the greeter cannot load this theme -- not activating it"
    fi
    step "greeter loaded the theme with no QML errors"

    # sddm-greeter only builds what is on screen; Login.qml is created lazily
    # when the user interacts. Compile it explicitly so a broken login form
    # cannot slip through.
    probe=$(mktemp "$DEST/.probe-XXXXXX.qml")
    cat >"$probe" <<'EOF'
import QtQuick
Item {
    Component.onCompleted: {
        var files = []
        // every theme file except this probe
        for (var i = 0; i < 6; i++) files.push(["Main","Login","Background",
                                               "KeyboardButton","SessionButton","NothingClock"][i] + ".qml")
        for (var j = 0; j < files.length; j++) {
            var c = Qt.createComponent(files[j])
            if (c.status === Component.Error)
                console.log("PROBE-FAIL " + files[j] + " " + c.errorString())
        }
        Qt.exit(0)
    }
}
EOF
    plog=$(mktemp)
    QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
        timeout 20 qmlscene "$probe" >"$plog" 2>&1 || true
    rm -f "$probe"
    pbad=$(grep 'PROBE-FAIL' "$plog" | head -5 || true)
    if [ -n "$pbad" ]; then
        printf '%s\n' "$pbad" | sed 's/^/      /'
        rm -f "$glog" "$plog"
        die "a theme file fails to compile -- not activating it"
    fi
    step "all theme QML files compile"
    rm -f "$glog" "$plog"
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
