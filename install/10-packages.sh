#!/usr/bin/env bash
# Step 1 -- distro packages. Needs sudo.
#
# Package names differ between the two supported distros (fonts-noto-color-emoji
# vs noto-fonts-emoji, python3-pil vs python-pillow, ...), so each list is kept
# whole rather than translated -- the Arch list is not an alias table for the
# apt one.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_plasma6

say "Installing distro packages ($PKG)"

PKGS_APT=(
    curl unzip git                # fetching upstream assets
    papirus-icon-theme            # YAMIS inherits it; without it missing icons
                                  # fall back to colourful breeze-dark
    fonts-noto-color-emoji
    plymouth plymouth-themes      # boot animation
    python3-pil python3-numpy     # only to regenerate Plymouth frames
    imagemagick                   # wallpaper padding helper
)

PKGS_PACMAN=(
    curl unzip git                # fetching upstream assets
    papirus-icon-theme            # same icon inheritance as above
    noto-fonts-emoji              # fonts-noto-color-emoji
    plymouth plymouth-kcm         # boot animation + its "Boot Splash" settings page
    breeze-plymouth               # rollback theme; also the KCM's other option
    python-pillow python-numpy    # only to regenerate Plymouth frames
    imagemagick                   # wallpaper padding helper ("magick" on Arch)
    libinput-tools                # nothing-gestures: `libinput list-devices` and
                                  # `libinput debug-events`. The `libinput` package
                                  # is the shared library only; neither tool is in
                                  # it, and nothing pulls -tools in automatically.
)

# imagemagick's optional ghostscript is left out on purpose: on Arch it resolves
# to the full texlive, hundreds of megabytes for an `-extent` call on a PNG. The
# flag goes before the targets so it applies to all of them.
case "$PKG" in
    apt)
        sudo apt-get update
        sudo apt-get install -y "${PKGS_APT[@]}"
        ;;
    pacman)
        sudo pacman -S --needed --noconfirm --assume-installed ghostscript "${PKGS_PACMAN[@]}"
        ;;
esac

say "Optional: window decoration"
case "$AUR_HELPER" in
    "")
        step "Klassy is in the AUR; no paru/yay found, so it is not offered."
        step "Build it by hand: https://aur.archlinux.org/packages/klassy"
        ;;
    *)
        step "Klassy is in the AUR and $AUR_HELPER is available:"
        step "    $AUR_HELPER -S klassy"
        step "(not installed automatically -- it is a build from source)"
        ;;
esac
cat <<'MSG'
    The titlebars in the screenshots are Klassy (kdecoration3):

        https://github.com/paulmcauley/klassy

    Klassy is OPTIONAL. Skip it and KWin falls back to Breeze, which still
    looks fine with this rice; the aurorae "Nothing" decoration installed in
    step 2 is the other option (it is kdecoration2, so Plasma 6.6+ ignores it
    unless you force it).
MSG

say "Packages done"
