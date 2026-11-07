#!/bin/sh
# Netra installer: downloads the latest release, checks its SHA-256, and puts
# Netra.app in /Applications (or ~/Applications when /Applications isn't
# writable). Never uses sudo.
#
#   curl -fsSL https://raw.githubusercontent.com/sahabji0P/netra/master/install.sh | sh
#
# Re-run the same command to update. To uninstall:
#
#   curl -fsSL https://raw.githubusercontent.com/sahabji0P/netra/master/install.sh | sh -s -- --uninstall
#
# Why there is no Gatekeeper prompt: Netra isn't notarized yet. Gatekeeper only
# checks files carrying the com.apple.quarantine attribute, which browsers,
# Mail, AirDrop, and Homebrew casks add to what they download. curl and ditto
# don't, so the app this script installs opens without "Open Anyway".
#
# Environment overrides:
#   NETRA_VERSION=1.5.0       install that release instead of the latest
#   NETRA_INSTALL_DIR=<dir>   install into <dir> instead of choosing one
#   NETRA_NO_LAUNCH=1         don't open Netra after installing
#   NETRA_DOWNLOAD_BASE=<url> fetch Netra.zip and Netra.zip.sha256 from <url>
#                             (a mirror or file:// directory, for testing)
#
# Written for /bin/sh on macOS (bash 3.2 in POSIX mode); also runs in dash
# and zsh. Everything is inside main(), which runs on the last line, so a
# download cut off halfway through runs nothing.

set -eu
# pipefail isn't POSIX; use it wherever the shell has it.
# shellcheck disable=SC3040
(set -o pipefail) 2>/dev/null && set -o pipefail

REPO="sahabji0P/netra"
BUNDLE_ID="com.sahabji0P.netra"
APP_NAME="Netra.app"
ASSET="Netra.zip"
MIN_MACOS_MAJOR=14 # LSMinimumSystemVersion / Package.swift .macOS(.v14)
INSTALL_URL="https://raw.githubusercontent.com/$REPO/master/install.sh"

tmp_dir=""
staging=""

if [ -t 1 ]; then
    bold=$(printf '\033[1m')
    red=$(printf '\033[31m')
    yellow=$(printf '\033[33m')
    reset=$(printf '\033[0m')
else
    bold="" red="" yellow="" reset=""
fi

info() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
warn() { printf '%swarning:%s %s\n' "$yellow" "$reset" "$*" >&2; }
die() {
    printf '%serror:%s %s\n' "$red" "$reset" "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$staging" ] && [ -e "$staging" ]; then rm -rf "$staging"; fi
    if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then rm -rf "$tmp_dir"; fi
}

usage() {
    cat <<EOF
Usage: install.sh [--uninstall [--purge]]

  (no option)   install or update Netra
  --uninstall   quit Netra and remove Netra.app
  --purge       with --uninstall, also delete Netra's settings, caches, and
                ~/Library/Application Support/Netra

See the comments at the top of this script for environment overrides.
EOF
}

# --- checks ------------------------------------------------------------------

check_platform() {
    os=$(uname -s)
    [ "$os" = Darwin ] || die "Netra is a macOS app; this machine runs $os."

    macos=$(sw_vers -productVersion 2>/dev/null || true)
    major=${macos%%.*}
    case $major in
        '' | *[!0-9]*) die "could not read the macOS version (sw_vers said '$macos')." ;;
    esac
    [ "$major" -ge "$MIN_MACOS_MAJOR" ] ||
        die "Netra needs macOS $MIN_MACOS_MAJOR (Sonoma) or newer; this Mac runs macOS $macos."

    # Not `uname -m`: a shell running under Rosetta reports x86_64 on Apple
    # Silicon. hw.optional.arm64 is 1 on Apple Silicon, whatever the shell.
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != 1 ]; then
        die "Netra is built for Apple Silicon (M1 or newer) only; Intel Macs aren't supported."
    fi

    for tool in curl ditto codesign shasum xattr mktemp pgrep /usr/libexec/PlistBuddy; do
        command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' is missing."
    done
}

plist_value() { # <bundle> <key>
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true
}

has_quarantine() {
    xattr -r "$1" 2>/dev/null | grep -q 'com\.apple\.quarantine'
}

signer() {
    authority=$(codesign -dvv "$1" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
    if [ -n "$authority" ]; then printf '%s' "$authority"; else printf 'ad-hoc'; fi
}

# --- running copies ----------------------------------------------------------

running_pids() {
    pgrep -f "$APP_NAME/Contents/MacOS/Netra" 2>/dev/null || true
}

# Quit with SIGTERM rather than an Apple Event: `osascript ... quit` would make
# macOS ask whether Terminal may control Netra. Netra saves its snapshot after
# every refresh, and its keep-awake assertion ends with the process.
quit_running() {
    pids=$(running_pids)
    [ -n "$pids" ] || return 0
    info "Quitting the running Netra"
    printf '%s\n' "$pids" | while read -r pid; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    tries=0
    while [ -n "$(running_pids)" ]; do
        tries=$((tries + 1))
        [ "$tries" -le 50 ] ||
            die "Netra didn't quit within 10 seconds. Quit it from its menu (Quit) and run this again."
        sleep 0.2
    done
}

# --- install -----------------------------------------------------------------

resolve_version() {
    if [ -n "${NETRA_VERSION:-}" ]; then
        version=${NETRA_VERSION#v}
    elif [ -n "${NETRA_DOWNLOAD_BASE:-}" ]; then
        version="" # read from the downloaded bundle instead
        return 0
    else
        # Follow the releases/latest redirect to its tag: no API call, so no
        # unauthenticated rate limit and no JSON to parse.
        latest=$(curl -fsSLI --proto '=https' -o /dev/null -w '%{url_effective}' \
            "https://github.com/$REPO/releases/latest") ||
            die "could not reach GitHub to find the latest release. Check your connection and try again."
        case $latest in
            */releases/tag/*) version=${latest##*/tag/} ;;
            *) die "could not find the latest Netra release (GitHub sent $latest)." ;;
        esac
        version=${version#v}
    fi
    case $version in
        '' | *[!0-9A-Za-z.-]*) die "'$version' isn't a valid Netra version." ;;
    esac
}

download() { # <url> <file> <what>
    if [ -n "${NETRA_DOWNLOAD_BASE:-}" ]; then
        curl -fsSL --retry 2 -o "$2" "$1"
    else
        curl -fsSL --retry 2 --proto '=https' -o "$2" "$1"
    fi
}

choose_install_dir() {
    if [ -n "${NETRA_INSTALL_DIR:-}" ]; then
        install_dir=$NETRA_INSTALL_DIR
    elif [ -d "/Applications/$APP_NAME" ]; then
        install_dir=/Applications # update where it already is
    elif [ -d "$HOME/Applications/$APP_NAME" ]; then
        install_dir=$HOME/Applications
    elif [ -w /Applications ]; then
        install_dir=/Applications
    else
        install_dir=$HOME/Applications
    fi

    mkdir -p "$install_dir" 2>/dev/null || die "could not create $install_dir."
    # Ownership, not `-w`, for the bundle: right after a launch macOS briefly
    # reports a bundle as unwritable while it scans it.
    if [ ! -w "$install_dir" ] ||
        { [ -e "$install_dir/$APP_NAME" ] && [ ! -O "$install_dir/$APP_NAME" ]; }; then
        die "can't write to $install_dir/$APP_NAME (it may belong to another user).
       This installer never uses sudo. Either remove that copy yourself, or install
       into your own Applications folder:
       curl -fsSL $INSTALL_URL | NETRA_INSTALL_DIR=\"\$HOME/Applications\" sh"
    fi
}

install_netra() {
    check_platform
    resolve_version

    base=${NETRA_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/v$version}
    base=${base%/}

    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/netra-install.XXXXXX")

    if [ -n "$version" ]; then info "Downloading Netra $version"; else info "Downloading Netra from $base"; fi
    if ! download "$base/$ASSET.sha256" "$tmp_dir/$ASSET.sha256"; then
        if [ -n "$version" ]; then
            die "release v$version has no $ASSET.sha256 checksum. Releases before the
       curl installer existed can't be installed this way; use a newer version
       or Homebrew (see https://github.com/$REPO#install)."
        fi
        die "could not download $base/$ASSET.sha256."
    fi
    download "$base/$ASSET" "$tmp_dir/$ASSET" || die "could not download $base/$ASSET."

    expected=$(awk 'NR == 1 { print tolower($1) }' "$tmp_dir/$ASSET.sha256")
    case $expected in
        *[!0-9a-f]*) expected="" ;;
    esac
    [ "${#expected}" -eq 64 ] || die "$ASSET.sha256 doesn't contain a SHA-256 checksum."
    actual=$(shasum -a 256 "$tmp_dir/$ASSET" | awk '{ print $1 }')
    [ "$actual" = "$expected" ] || die "checksum mismatch for $ASSET; nothing was installed.
       expected $expected
       got      $actual"
    info "Checksum OK ($actual)"

    ditto -x -k "$tmp_dir/$ASSET" "$tmp_dir/unpacked" || die "could not unpack $ASSET."
    new_app="$tmp_dir/unpacked/$APP_NAME"
    [ -d "$new_app" ] || die "$ASSET doesn't contain $APP_NAME."
    [ "$(plist_value "$new_app" CFBundleIdentifier)" = "$BUNDLE_ID" ] ||
        die "$ASSET contains an app that isn't Netra ($BUNDLE_ID)."
    new_version=$(plist_value "$new_app" CFBundleShortVersionString)
    if [ -n "$version" ] && [ "$new_version" != "$version" ]; then
        die "release v$version contains Netra $new_version; refusing to install a mismatched build."
    fi
    codesign --verify --deep --strict "$new_app" 2>/dev/null ||
        die "Netra $new_version's code signature doesn't verify; refusing to install it."
    if has_quarantine "$new_app"; then xattr -dr com.apple.quarantine "$new_app"; fi

    choose_install_dir
    target="$install_dir/$APP_NAME"
    if [ -d /opt/homebrew/Caskroom/netra ] || [ -d /usr/local/Caskroom/netra ]; then
        warn "Homebrew also manages Netra. 'brew upgrade' would replace this copy and quarantine
         it again. To switch to this installer for good, run 'brew uninstall --cask netra'
         and then this command again."
    fi
    for other in /Applications "$HOME/Applications"; do
        if [ "$other" != "$install_dir" ] && [ -d "$other/$APP_NAME" ]; then
            warn "another copy stays at $other/$APP_NAME; delete it so you don't open the old one."
        fi
    done

    # Copy next to the target first, so the old copy is replaced only once the
    # new one is fully on disk.
    staging="$install_dir/.$APP_NAME.installing.$$"
    rm -rf "$staging"
    ditto "$new_app" "$staging" || die "could not copy Netra into $install_dir."

    quit_running
    # Swap by renaming, so a failure leaves either the old or the new app.
    old="$install_dir/.$APP_NAME.old.$$"
    if [ -e "$target" ]; then
        mv "$target" "$old" || die "could not move the old $target aside."
    fi
    if ! mv "$staging" "$target"; then
        if [ -e "$old" ]; then mv "$old" "$target" || true; fi
        die "could not move Netra into $install_dir."
    fi
    staging=""
    if [ -e "$old" ]; then rm -rf "$old" || warn "could not delete $old; remove it yourself."; fi

    codesign --verify --deep --strict "$target" 2>/dev/null ||
        die "the installed $target doesn't pass codesign --verify."
    if has_quarantine "$target"; then
        warn "removing an unexpected quarantine flag from $target"
        xattr -dr com.apple.quarantine "$target"
        ! has_quarantine "$target" || die "could not remove the quarantine flag from $target."
    fi

    launched=""
    if [ -z "${NETRA_NO_LAUNCH:-}" ]; then
        info "Opening Netra"
        open "$target" || warn "could not open $target; open it from Finder."
        tries=0
        while [ -z "$(running_pids)" ] && [ "$tries" -lt 25 ]; do
            tries=$((tries + 1))
            sleep 0.2
        done
        if [ -n "$(running_pids)" ]; then launched=1; else warn "Netra didn't start; open it from $install_dir."; fi
    fi

    printf '\n%sNetra %s is installed at %s%s\n' "$bold" "$new_version" "$target" "$reset"
    printf '  Signed by: %s · no quarantine flag\n' "$(signer "$target")"
    if [ -n "$launched" ]; then printf '  Look for the eye icon in your menu bar.\n'; fi
    printf '\n  Update:    curl -fsSL %s | sh\n' "$INSTALL_URL"
    printf '  Uninstall: curl -fsSL %s | sh -s -- --uninstall\n' "$INSTALL_URL"
}

# --- uninstall ---------------------------------------------------------------

uninstall_netra() {
    purge=$1
    quit_running

    removed=""
    for dir in ${NETRA_INSTALL_DIR:+"$NETRA_INSTALL_DIR"} /Applications "$HOME/Applications"; do
        app="$dir/$APP_NAME"
        [ -d "$app" ] || continue
        if [ "$(plist_value "$app" CFBundleIdentifier)" != "$BUNDLE_ID" ]; then
            warn "skipping $app: it isn't Netra ($BUNDLE_ID)."
            continue
        fi
        rm -rf "$app" || die "could not remove $app (it may belong to another user)."
        info "Removed $app"
        removed=1
    done
    [ -n "$removed" ] || info "Netra.app wasn't found in /Applications or ~/Applications."

    # Launch at login is an SMAppService registration, which only the app
    # itself can withdraw (Netra's Settings → "Launch at login", before
    # uninstalling). With the app gone the entry can't launch anything, but
    # macOS may still list it until it notices; say how to remove it.
    printf '\nIf "Netra" still shows under System Settings → General → Login Items,\nselect it and click the minus button.\n'

    if [ "$purge" = 1 ]; then
        rm -rf "$HOME/Library/Application Support/Netra" \
            "$HOME/Library/Caches/$BUNDLE_ID" \
            "$HOME/Library/HTTPStorages/$BUNDLE_ID"
        defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
        info "Deleted Netra's settings, caches, and ~/Library/Application Support/Netra"
    else
        printf '\nNetra'"'"'s settings and data are kept. To delete them too, run:\n'
        printf '  curl -fsSL %s | sh -s -- --uninstall --purge\n' "$INSTALL_URL"
    fi

    cat <<EOF

Keychain items are never touched. If you no longer need them, delete them in
Keychain Access: "Netra Account Vault" (saved Claude Code / Codex sign-ins of
parked accounts) and "$BUNDLE_ID.usage-feed" (website publishing token).
EOF
    if [ -d /opt/homebrew/Caskroom/netra ] || [ -d /usr/local/Caskroom/netra ]; then
        printf '\nHomebrew still lists Netra; clear that with: brew uninstall --cask netra\n'
    fi
}

# --- entry point -------------------------------------------------------------

main() {
    mode=install
    purge=0
    for arg in "$@"; do
        case $arg in
            --uninstall) mode=uninstall ;;
            --purge) purge=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "unknown option '$arg'."
                ;;
        esac
    done
    if [ "$purge" = 1 ] && [ "$mode" != uninstall ]; then die "--purge only goes with --uninstall."; fi

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [ "$mode" = uninstall ]; then uninstall_netra "$purge"; else install_netra; fi
}

main "$@"
