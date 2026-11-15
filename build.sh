#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

install_app=0
make_zip=0
universal=0
while (($#)); do
    case "$1" in
        --install) install_app=1 ;;
        --zip) make_zip=1 ;;
        --universal) universal=1 ;;
        *) printf 'Usage: %s [--install] [--zip] [--universal]\n' "$0" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p build
stage=$(mktemp -d "$PWD/build/stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/CV Vault.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"

if ((universal)); then
    for arch in arm64 x86_64; do
        swift build -c release --arch "$arch" --scratch-path ".build-${arch}"
    done
    arm_dir=$(swift build -c release --arch arm64 --scratch-path .build-arm64 --show-bin-path)
    intel_dir=$(swift build -c release --arch x86_64 --scratch-path .build-x86_64 --show-bin-path)
    for binary in CVVault cv-vault-mcp; do
        lipo -create "$arm_dir/$binary" "$intel_dir/$binary" -output "$app/Contents/MacOS/$binary"
    done
    arch_tag=universal
else
    swift build -c release
    bin_dir=$(swift build -c release --show-bin-path)
    for binary in CVVault cv-vault-mcp; do
        cp "$bin_dir/$binary" "$app/Contents/MacOS/$binary"
    done
    arch_tag=$(uname -m)
fi

swift assets/MakeIcon.swift "$stage/icon.png"
iconset="$stage/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$stage/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((2 * size))
    sips -z "$double" "$double" "$stage/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

identity=${SIGN_IDENTITY:--}
sign_flags=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
    sign_flags+=(--options runtime --timestamp)
fi
codesign "${sign_flags[@]}" "$app/Contents/MacOS/cv-vault-mcp"
codesign "${sign_flags[@]}" "$app"
codesign --verify --deep --strict "$app"

dest="$PWD/build/CV Vault.app"
rm -rf "$dest"
mv "$app" "$dest"
printf 'Built: %s\n' "$dest"

if ((make_zip)); then
    mkdir -p dist
    version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
    archive="$PWD/dist/CV-Vault-${version}-macOS-${arch_tag}.zip"
    ditto -c -k --norsrc --noextattr --noqtn --keepParent "$dest" "$stage/archive.zip"
    mv "$stage/archive.zip" "$archive"
    printf 'Archive: %s\n' "$archive"
fi

if ((install_app)); then
    applications="$HOME/Applications"
    installed="$applications/CV Vault.app"
    mkdir -p "$applications"
    if [[ -e "$installed" || -L "$installed" ]]; then
        if [[ -L "$installed" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$installed/Contents/Info.plist" 2>/dev/null || true)" != com.cv-vault.macos ]]; then
            printf 'A different app already exists at %s.\n' "$installed" >&2
            exit 1
        fi
    fi
    install_stage=$(mktemp -d "$applications/.cv-vault-XXXXXX")
    trap 'rm -rf "$stage" "$install_stage"' EXIT
    ditto "$dest" "$install_stage/new.app"
    if [[ -e "$installed" ]]; then
        mv "$installed" "$install_stage/previous.app"
    fi
    if ! mv "$install_stage/new.app" "$installed"; then
        if [[ -d "$install_stage/previous.app" ]]; then
            mv "$install_stage/previous.app" "$installed"
        fi
        exit 1
    fi
    printf 'Installed: %s\n' "$installed"
fi
