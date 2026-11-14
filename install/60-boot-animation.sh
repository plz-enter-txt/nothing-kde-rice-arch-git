#!/usr/bin/env bash
# Step 6 -- Plymouth boot + shutdown animation. MUST be run with sudo.
#     sudo ./install/60-boot-animation.sh
#
# Ubuntu picks its theme with update-alternatives and rebuilds the initramfs
# with update-initramfs. Arch has neither: plymouth-set-default-theme writes
# /etc/plymouth/plymouthd.conf, and mkinitcpio bakes the theme in with its own
# `plymouth` hook, which is why the hook list has to be touched here.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "$(id -u)" -eq 0 ] || die "run this one with sudo"
SRC="$REPO/plymouth/nothing"
THEME=/usr/share/plymouth/themes/nothing

say "Installing the theme"
rm -rf "$THEME"
install -d -m 755 "$THEME"
install -m 644 "$SRC"/dot-*.png "$THEME/"
install -m 644 "$SRC"/nothing.script "$SRC"/nothing.plymouth "$SRC"/nothing.grub "$THEME/"
[ -f "$SRC/LICENSE" ] && install -m 644 "$SRC/LICENSE" "$THEME/"
step "$(ls "$THEME"/dot-*.png | wc -l) frames (expect 60)"

# Print the contents of an initramfs, whichever tool this distro has.
# lsinitcpio takes NO --keep option: an unknown option there is reported on
# stdout and exits 0, so the listing looked empty and every check failed.
list_initramfs() {
    if have lsinitcpio; then
        lsinitcpio --nocolor "$1" 2>/dev/null
    elif have lsinitramfs; then
        lsinitramfs "$1" 2>/dev/null
    else
        return 1
    fi
}

if [ "$PKG" = pacman ]; then
    #------------------------------------------------------------------ Arch --
    say "The mkinitcpio plymouth hook"
    # Without it the theme directory never reaches the initramfs and the splash
    # is missing until late boot, when the real root's copy becomes visible.
    #
    # mkinitcpio >= 40 reads /etc/mkinitcpio.*.d/*.conf after the main config
    # and lets a drop-in REPLACE a variable, so HOOKS is rewritten here in one
    # place -- /etc/mkinitcpio.conf is never edited. Appending plymouth moves it
    # to the very end, which is fine: it only needs base and udev/systemd ahead
    # of it, not keyboard/block/filesystems.
    HOOK_FIX=""
    # Drop-ins arrived in mkinitcpio 40; before that only the main file is read,
    # so a drop-in there would be written and silently ignored.
    MK_HAS_DROPINS=0
    if [ -d /etc/mkinitcpio.conf.d ]; then
        MK_HAS_DROPINS=1
    elif have zgrep && zgrep -q 'mkinitcpio\.conf\.d' /usr/share/man/man5/mkinitcpio.conf.5.gz 2>/dev/null; then
        MK_HAS_DROPINS=1
    fi
    if ! grep -Eq '^[[:space:]]*HOOKS=.*\bplymouth\b' /etc/mkinitcpio.conf; then
        if [ "$MK_HAS_DROPINS" -eq 0 ]; then
            warn "this mkinitcpio predates drop-in configs -- editing HOOKS in place"
            cp /etc/mkinitcpio.conf "/etc/mkinitcpio.conf.bak.$(date +%Y%m%d-%H%M%S)"
            sed -ri 's/^([[:space:]]*HOOKS=\(.*)\)/\1 plymouth)/' /etc/mkinitcpio.conf
            HOOK_FIX="/etc/mkinitcpio.conf"
        else
            install -d /etc/mkinitcpio.conf.d
            # Pull the effective HOOKS line out of the main config first, so a
            # hook added to it earlier is carried over rather than dropped.
            existing=$(grep -E '^[[:space:]]*HOOKS=' /etc/mkinitcpio.conf | tail -1)
            existing=${existing#*=}
            existing=${existing#\"}; existing=${existing%\"}
            inner=$(sed -E 's/^\(//; s/\)$//' <<<"$existing")
            if grep -q 'plymouth' <<<"$inner"; then
                new_hooks="$inner"
            else
                new_hooks="$inner plymouth"
            fi
            HOOK_FIX=/etc/mkinitcpio.conf.d/nothing-plymouth.conf
            cat > "$HOOK_FIX" <<EOF
# Nothing rice: add plymouth so the theme is baked into the initramfs.
# This drop-in replaces HOOKS wholesale -- keep it in sync if you edit HOOKS.
HOOKS=($new_hooks)
EOF
            step "wrote $HOOK_FIX"
        fi
    else
        step "already in HOOKS"
    fi
    echo "    HOOKS now: ${new_hooks:-$(sed -n 's/^[[:space:]]*HOOKS=//p' /etc/mkinitcpio.conf | tail -1)}"
    [ -n "$HOOK_FIX" ] && echo "    via:       $HOOK_FIX"

    say "Selecting the theme"
    # A preset whose kernel image is not readable (/boot not mounted, or only a
    # subset of the linux packages installed) makes `mkinitcpio -P` exit
    # non-zero, and plymouth-set-default-theme -R forwards that -- under set -e
    # that would abort the step AFTER the theme was already selected. So the
    # write and the rebuild are separated, and the rebuild's result is checked
    # against the actual initramfs below rather than trusted.
    CONF=/etc/plymouth/plymouthd.conf
    SET_TERM_RC=0
    if have plymouth-set-default-theme; then
        # -R rebuilds every preset itself; mkinitcpio must not run again after.
        plymouth-set-default-theme -R nothing || SET_TERM_RC=$?
        step "plymouthd.conf Theme=$(plymouth-set-default-theme 2>/dev/null || echo nothing)"
        [ "$SET_TERM_RC" -eq 0 ] || warn "plymouth-set-default-theme exited $SET_TERM_RC -- rebuild status checked below"
    else
        warn "plymouth-set-default-theme missing -- writing plymouthd.conf by hand"
        install -d /etc/plymouth
        [ -f "$CONF" ] || : > "$CONF"
        if grep -q '^\[Daemon\]' "$CONF"; then
            if grep -q '^#\?[[:space:]]*Theme[[:space:]]*=' "$CONF"; then
                sed -i 's/^#\?[[:space:]]*Theme[[:space:]]*=.*/Theme=nothing/' "$CONF"
            else
                sed -i '/^\[Daemon\]/a Theme=nothing' "$CONF"
            fi
        else
            printf '[Daemon]\nTheme=nothing\n' >> "$CONF"
        fi
        mkinitcpio -P || warn "mkinitcpio -P reported errors -- see the rebuild check"
    fi

    say "Kernel command line (Arch has no console hand-over patch)"
    # Ubuntu's initramfs-tools plymouth hook is built with no_console_handoff=1,
    # which is what lets the splash start before userspace. Arch's
    # plymouth-start.service has no equivalent, so with `quiet` the console sits
    # blank until init's point in the boot. Dropping `quiet` (leaving kernel
    # loglevel 3) means the screen is never empty before the splash appears.
    # GRUB_PARAMS=quiet opts out; no GRUB on this machine just skips the step.
    if [ "${GRUB_PARAMS:-}" = "quiet" ]; then
        step "GRUB_PARAMS=quiet -- leaving the kernel command line alone"
    elif have grub-mkconfig && [ -r /etc/default/grub ]; then
        mkdir -p /etc/default/grub.d
        OVR=/etc/default/grub.d/99-nothing-splash.cfg

        # A drop-in REPLACES GRUB_CMDLINE_LINUX_DEFAULT, it does not append to
        # it: whatever else was on that line goes away. So the new value is
        # derived from the current one -- every parameter kept except `quiet`,
        # and loglevel=3 added only if the user had no loglevel of their own.
        # This machine's line carried lsm=landlock,lockdown,yama,integrity,
        # apparmor,bpf, which an earlier version of this script silently dropped.
        # Always start from /etc/default/grub -- the authoritative line. Reading
        # the existing drop-in back first (an earlier version of this script did)
        # makes a stale drop-in look "already correct" and it is never repaired.
        cur=$(. /etc/default/grub && printf '%s' "${GRUB_CMDLINE_LINUX_DEFAULT:-}")
        # Tokens the existing drop-in adds on top of the main line are kept too,
        # unless this script wrote it -- then it is just a stale copy of a value
        # that is no longer true.
        if [ -f "$OVR" ] && ! grep -q '^# Nothing rice' "$OVR"; then
            prev=$(. "$OVR" && printf '%s' "${GRUB_CMDLINE_LINUX_DEFAULT:-}")
            for t in $prev; do
                case " $cur " in
                    *" $t "*) ;;
                    *) cur="$cur $t" ;;
                esac
            done
        fi

        new_params=""
        for t in $cur; do
            [ "$t" = "quiet" ] && continue
            new_params="$new_params $t"
        done
        case " $new_params " in
            *" loglevel="*) ;;
            *) new_params="$new_params loglevel=3" ;;
        esac
        new_params=${new_params# }

        # Compare against what the file currently says, not against $cur:
        # $cur is the /etc/default/grub line plus any preserved extras, so it
        # differs from the drop-in's value whenever `quiet` was dropped.
        have_now=""
        [ -f "$OVR" ] && have_now=$(. "$OVR" && printf '%s' "${GRUB_CMDLINE_LINUX_DEFAULT:-}")
        if [ -f "$OVR" ] && [ "$new_params" = "$have_now" ]; then
            step "$OVR already correct -- nothing to change"
        else
            [ -f "$OVR" ] && cp "$OVR" "$OVR.bak.$(date +%Y%m%d-%H%M%S)"
            cat > "$OVR" <<EOF
# Nothing rice: start plymouth without \`quiet\`, so the console is not blank
# while the kernel boots and before userspace hands over to the splash.
# NOTE: a drop-in REPLACES this variable rather than appending to it. If you
# change GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub, carry the change here
# too, or delete this file and re-run the step to regenerate it.
GRUB_CMDLINE_LINUX_DEFAULT="$new_params"
GRUB_GFXPAYLOAD_LINUX=keep
EOF
            step "wrote $OVR"
            step "  was: $cur"
            step "  now: $new_params"
        fi

        gm_out=$(grub-mkconfig -o /boot/grub/grub.cfg 2>&1)
        if [ $? -eq 0 ] && [ -s /boot/grub/grub.cfg ]; then
            step "grub.cfg regenerated"
        else
            warn "grub-mkconfig failed -- check /boot"
            printf '%s\n' "$gm_out" | tail -5 | sed 's/^/    /'
        fi

        # grub.cfg stores the line inside a menuentry, not as a shell variable,
        # so read the real linux line back rather than grepping for the override.
        # (Tokenise whole words: matching `lsm=` followed by [^ ]* truncates at
        # the first letter, since [^ ] excludes nothing else in the value.)
        eff=$(grep -m1 -E "^[[:space:]]*linux[[:space:]]" /boot/grub/grub.cfg 2>/dev/null \
              | sed -E 's/^[[:space:]]*linux[[:space:]]+[^[:space:]]+[[:space:]]*//; s/[[:space:]]+/ /g')
        show=$(tr ' ' '\n' <<<"$eff" | grep -vE '^(rw|ro)$' | tr '\n' ' ')
        step "effective on the default entry: ${show:-<could not read grub.cfg>}"
        for t in $cur; do
            [ "$t" = "quiet" ] && continue
            case " $eff " in
                *" $t "*) ;;
                *) warn "parameter '$t' is NOT in the generated grub.cfg -- check the boot entry" ;;
            esac
        done
        case " $eff " in
            *" quiet "*) warn "'quiet' is still on the kernel command line -- another grub.d drop-in may be setting it" ;;
        esac
    elif have grub-mkconfig; then
        warn "/etc/default/grub missing -- kernel command line left as it is"
    else
        warn "no GRUB here -- kernel command line left as it is"
    fi

    INIT=$(find /boot -maxdepth 1 -name 'initramfs-*.img' ! -name '*fallback*' -printf '%T@ %p\n' 2>/dev/null \
           | sort -nr | head -1 | cut -d' ' -f2-)
    CONF=/etc/plymouth/plymouthd.conf
else
    #---------------------------------------------------------------- Ubuntu --
    say "Registering as the default theme"
    update-alternatives --install \
      /usr/share/plymouth/themes/default.plymouth default.plymouth \
      "$THEME/nothing.plymouth" 200 \
      --slave /usr/share/plymouth/themes/default.grub default.plymouth.grub "$THEME/nothing.grub"
    update-alternatives --set default.plymouth "$THEME/nothing.plymouth"
    step "default.plymouth -> $(readlink -f /usr/share/plymouth/themes/default.plymouth)"

    # plymouthd.conf OUTRANKS update-alternatives wherever the named theme exists.
    # Leave it pointing elsewhere and boot may still show this theme (because the
    # named one is absent from the initramfs and plymouth falls through), while
    # SHUTDOWN -- which runs from the real root, where it does exist -- shows the
    # other one. Name it explicitly so both ends match.
    say "Pinning the theme in plymouthd.conf"
    CONF=/etc/plymouth/plymouthd.conf
    install -d /etc/plymouth
    if [ -f "$CONF" ] && grep -q '^Theme=' "$CONF"; then
        sed -i 's/^Theme=.*/Theme=nothing/' "$CONF"
    else
        grep -q '^\[Daemon\]' "$CONF" 2>/dev/null || echo '[Daemon]' >> "$CONF"
        echo 'Theme=nothing' >> "$CONF"
    fi
    step "$(grep '^Theme=' "$CONF")"

    say "Rebuilding the initramfs"
    update-initramfs -u

    INIT=/boot/initrd.img-$(uname -r)
fi

say "Verification"
printf '    %-22s %s\n' "frames installed" "$(ls "$THEME"/dot-*.png 2>/dev/null | wc -l)  (expect 60)"
printf '    %-22s %s\n' "configured theme" \
    "$(grep -E '^[[:space:]]*(#?[[:space:]]*)?Theme[[:space:]]*=' "${CONF:-/etc/plymouth/plymouthd.conf}" 2>/dev/null | grep -v '^#' | head -1 || true)"
[ "$PKG" = pacman ] && printf '    %-22s %s\n' "HOOKS" "${new_hooks:-$(sed -n 's/^[[:space:]]*HOOKS=//p' /etc/mkinitcpio.conf | tail -1)}"

# Check EVERY initramfs on disk, not just the newest. On a box whose presets
# cover kernels it does not actually have (or whose /boot is not mounted),
# mkinitcpio fails per preset; the images that did get written are the ones
# that will boot and need to be right.
CHECKED=""; STALE=""
for img in "${INIT:-}" /boot/initramfs-*.img; do
    [ -r "$img" ] || continue
    case " $CHECKED " in *" $img "*) continue ;; esac
    CHECKED="$CHECKED $img"
    n_frames=$(list_initramfs "$img" | grep -c 'themes/nothing/dot-')
    n_script=$(list_initramfs "$img" | grep -c 'themes/nothing/nothing.script')
    if [ "${n_frames:-0}" -ge 60 ] && [ "${n_script:-0}" -ge 1 ]; then
        printf '    %-22s %s  (%s frames, script ok)\n' "$(basename "$img")" "OK" "${n_frames}"
    else
        printf '    %-22s %s\n' "$(basename "$img")" "MISSING  (frames=${n_frames:-0}, script=${n_script:-0})"
        STALE="$STALE $img"
    fi
done
CHECKED=${CHECKED# }

if [ -z "$CHECKED" ]; then
    warn "no initramfs images found under /boot -- nothing was baked in."
    warn "If /boot is on a separate partition, it may not be mounted."
elif [ -n "$STALE" ]; then
    warn "the theme is not in:$STALE"
    warn "Those images predate this install (or their preset failed)."
    warn "Rebuild once /boot is in order:  sudo mkinitcpio -P"
fi

# A stale recordfail flag makes the next boot sit at the GRUB menu forever.
# update-grub races grub2-common.service and can leave it set, so always check.
if have grub-editenv; then
    say "GRUB recordfail (must be clear before you reboot)"
    if [ -f /boot/grub/grubenv ] && grub-editenv /boot/grub/grubenv list 2>/dev/null | grep -q recordfail; then
        warn "recordfail was set -- clearing it"
        grub-editenv /boot/grub/grubenv unset recordfail
        systemctl reset-failed grub2-common.service 2>/dev/null || true
        step "cleared"
    else
        step "clean"
    fi
fi

if [ "$PKG" = pacman ]; then
    cat <<MSG

Done -- reboot to see it.

Arch picks the theme from /etc/plymouth/plymouthd.conf, which the plymouth
hook copies into the initramfs; there is no update-alternatives in play.

Rollback:
    sudo plymouth-set-default-theme -R breeze      # or: spinner, bgrt
    # kernel command line, only if this script changed it:
    sudo rm /etc/default/grub.d/99-nothing-splash.cfg
    sudo grub-mkconfig -o /boot/grub/grub.cfg
    # the hook, if you want it gone entirely:
    sudo \$EDITOR /etc/mkinitcpio.conf              # drop 'plymouth' from HOOKS
    sudo mkinitcpio -P

System Settings -> Colors & Themes -> Boot Splash (plymouth-kcm) edits the
same plymouthd.conf, if you would rather switch themes from the GUI.

To re-render the frames at a different size, edit and run:
    python3 $SRC/make-frames.py
MSG
else
    cat <<MSG

Done -- reboot to see it.

Rollback:
    sudo update-alternatives --set default.plymouth \\
        /usr/share/plymouth/themes/kubuntu-logo/kubuntu-logo.plymouth
    sudo sed -i 's/^Theme=.*/Theme=kubuntu-logo/' /etc/plymouth/plymouthd.conf
    sudo update-initramfs -u

To re-render the frames at a different size, edit and run:
    python3 $SRC/make-frames.py
MSG
fi
