#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK_DIR=${FREEMIND_BUILD_WORK_DIR:-/tmp/freemind-build-local}

copy_with_retry() {
    src=$1
    dst=$2
    i=1
    while [ "$i" -le 30 ]; do
        if cp -p "$src" "$dst" 2>/tmp/freemind_copy.err; then
            return 0
        fi
        err=$(cat /tmp/freemind_copy.err 2>/dev/null || true)
        echo "retry ${i}/30 copying $src: $err" >&2
        i=$((i + 1))
        sleep 1
    done
    echo "failed to copy $src after retries" >&2
    return 1
}

git_stream_with_retry() {
    i=1
    while [ "$i" -le 30 ]; do
        if "$@"; then
            return 0
        fi
        echo "retry ${i}/30 running: $*" >&2
        i=$((i + 1))
        sleep 1
    done
    echo "failed after retries: $*" >&2
    return 1
}

list_overlay_files() {
    if [ -n "${FREEMIND_LOCAL_OVERRIDE_FILES:-}" ]; then
        printf '%s\n' "$FREEMIND_LOCAL_OVERRIDE_FILES" | tr ' ' '\n' | sed '/^$/d'
        return 0
    fi

    git_stream_with_retry git -C "$ROOT_DIR" diff --name-only --relative HEAD
}

resolve_java_home() {
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
        echo "$JAVA_HOME"
        return 0
    fi

    if [ -x "$ROOT_DIR/.toolchain/jdk-17.0.2.jdk/Contents/Home/bin/java" ]; then
        echo "$ROOT_DIR/.toolchain/jdk-17.0.2.jdk/Contents/Home"
        return 0
    fi

    local_java=$(find "$ROOT_DIR/.toolchain" -maxdepth 5 -type f -path "*/jdk-*.jdk/Contents/Home/bin/java" 2>/dev/null | head -n 1 || true)
    if [ -n "$local_java" ]; then
        echo "$(dirname "$(dirname "$local_java")")"
        return 0
    fi

    echo "No usable JDK found. Set JAVA_HOME or prepare .toolchain/jdk-*.jdk first." >&2
    return 1
}

resolve_ant_bin() {
    if [ -n "${ANT_BIN:-}" ] && [ -x "$ANT_BIN" ]; then
        echo "$ANT_BIN"
        return 0
    fi

    if command -v ant >/dev/null 2>&1; then
        command -v ant
        return 0
    fi

    local_ant=$(find "$ROOT_DIR/.toolchain" -maxdepth 4 -type f -path "*/apache-ant-*/bin/ant" 2>/dev/null | head -n 1 || true)
    if [ -n "$local_ant" ]; then
        echo "$local_ant"
        return 0
    fi

    echo "No usable Ant found. Install Ant or set ANT_BIN." >&2
    return 1
}

resolve_macos_runtime_dir() {
    java_home=$1

    if [ -n "${FREEMIND_MAC_RUNTIME_DIR:-}" ]; then
        if [ -x "$FREEMIND_MAC_RUNTIME_DIR/bin/java" ]; then
            echo "$FREEMIND_MAC_RUNTIME_DIR"
            return 0
        fi
        if [ -x "$FREEMIND_MAC_RUNTIME_DIR/Contents/Home/bin/java" ]; then
            echo "$FREEMIND_MAC_RUNTIME_DIR/Contents/Home"
            return 0
        fi
        echo "FREEMIND_MAC_RUNTIME_DIR is set but invalid: $FREEMIND_MAC_RUNTIME_DIR" >&2
        return 1
    fi

    if file "$java_home/bin/java" | grep -q 'x86_64'; then
        echo "$java_home"
        return 0
    fi

    for candidate in $(find "$ROOT_DIR/.toolchain" -maxdepth 6 -type f -path "*/jdk-*.jdk/Contents/Home/bin/java" 2>/dev/null); do
        if file "$candidate" | grep -q 'x86_64'; then
            home_dir=$(dirname "$(dirname "$candidate")")
            echo "$home_dir"
            return 0
        fi
    done

    echo "No x86_64 JDK bundle found for macOS packaging." >&2
    echo "JavaAppLauncher from appbundler-1.0 is x86_64-only, so set FREEMIND_MAC_RUNTIME_DIR to an x64 JDK (Contents/Home or .jdk path)." >&2
    return 1
}

hydrate_runtime_home() {
    src_home=$1
    dst_home=$2

    rm -rf "$dst_home"
    mkdir -p "$dst_home"

    for item in bin conf lib release legal; do
        if [ -e "$src_home/$item" ]; then
            cp -R "$src_home/$item" "$dst_home/"
        fi
    done

    # appbundler-1.0 launcher probes Contents/Home/jre/lib/jli/libjli.dylib.
    if [ ! -e "$dst_home/jre" ]; then
        ln -s . "$dst_home/jre"
    fi
    if [ -f "$dst_home/lib/libjli.dylib" ]; then
        mkdir -p "$dst_home/lib/jli"
        if [ ! -e "$dst_home/lib/jli/libjli.dylib" ]; then
            ln -s ../libjli.dylib "$dst_home/lib/jli/libjli.dylib"
        fi
    fi
}

prepare_workspace() {
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"

    if ! git_stream_with_retry sh -c 'git -C "$1" archive --format=tar HEAD | tar -xf - -C "$2"' sh "$ROOT_DIR" "$WORK_DIR"; then
        echo "unable to create workspace archive from git" >&2
        return 1
    fi

    # Overlay selected local files so local fixes are included.
    list_overlay_files | while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        case "$rel" in
            .github/*|.git/*|.toolchain/*)
                continue
                ;;
        esac
        src="$ROOT_DIR/$rel"
        dst="$WORK_DIR/$rel"
        if [ -e "$src" ] || [ -L "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            if ! copy_with_retry "$src" "$dst"; then
                echo "warning: skip local override for $rel after repeated read failures" >&2
            fi
        fi
    done

    # Keep local deletions consistent.
    if [ -n "${FREEMIND_LOCAL_OVERRIDE_FILES:-}" ]; then
        return 0
    fi

    git_stream_with_retry git -C "$ROOT_DIR" diff --name-only --diff-filter=D --relative HEAD | while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        rm -f "$WORK_DIR/$rel"
    done
}

build_dmg() {
    JAVA_HOME_RESOLVED=$(resolve_java_home)
    ANT_BIN_RESOLVED=$(resolve_ant_bin)
    MAC_RUNTIME_DIR_RESOLVED=$(resolve_macos_runtime_dir "$JAVA_HOME_RESOLVED")

    echo "Using JAVA_HOME=$JAVA_HOME_RESOLVED"
    echo "Using ANT_BIN=$ANT_BIN_RESOLVED"
    echo "Using MAC_RUNTIME_DIR=$MAC_RUNTIME_DIR_RESOLVED"

    (cd "$WORK_DIR/freemind" && \
        JAVA_HOME="$JAVA_HOME_RESOLVED" PATH="$JAVA_HOME_RESOLVED/bin:$PATH" "$ANT_BIN_RESOLVED" -f build.xml -Dmacos_runtime_dir="$MAC_RUNTIME_DIR_RESOLVED" dist)

    app_bundle=$(find "$WORK_DIR/bin/dist_macos" -maxdepth 3 -type d -name "FreeMind.app" | head -n 1 || true)
    if [ -n "$app_bundle" ]; then
        runtime_name=$(/usr/libexec/PlistBuddy -c 'Print :JVMRuntime' "$app_bundle/Contents/Info.plist" 2>/dev/null || true)
        if [ -n "$runtime_name" ]; then
            hydrated_home="$app_bundle/Contents/PlugIns/$runtime_name/Contents/Home"
            echo "Hydrating bundled runtime at $hydrated_home"
            hydrate_runtime_home "$MAC_RUNTIME_DIR_RESOLVED" "$hydrated_home"
        fi
    fi

    mkdir -p "$WORK_DIR/post"
    (cd "$WORK_DIR/freemind" && \
        JAVA_HOME="$JAVA_HOME_RESOLVED" PATH="$JAVA_HOME_RESOLVED/bin:$PATH" "$ANT_BIN_RESOLVED" -f build.xml -Dmacos_runtime_dir="$MAC_RUNTIME_DIR_RESOLVED" -DisMacOs=true post_macos)

    for archive in /tmp/FreeMind_*" Archive.dmg"; do
        [ -f "$archive" ] || continue
        base=$(basename "$archive" " Archive.dmg")
        mv "$archive" "$WORK_DIR/post/$base.dmg"
    done

    dmg=$(ls -1t "$WORK_DIR"/post/FreeMind_*.dmg 2>/dev/null | head -n 1 || true)
    if [ -z "$dmg" ]; then
        dist_root=$(find "$WORK_DIR/bin/dist_macos" -maxdepth 1 -type d -name 'FreeMind_*' | head -n 1 || true)
        if [ -n "$dist_root" ]; then
            dmg_name=$(basename "$dist_root")
            fallback_dmg="$WORK_DIR/post/$dmg_name.dmg"
            echo "Creating fallback DMG: $fallback_dmg"
            hdiutil create -volname "$dmg_name" -srcfolder "$dist_root" -ov -format UDZO "$fallback_dmg" >/tmp/freemind_hdiutil.log 2>&1
        fi
    fi

    dmg=$(ls -1t "$WORK_DIR"/post/FreeMind_*.dmg 2>/dev/null | head -n 1 || true)
    if [ -z "$dmg" ]; then
        echo "No DMG produced. Check build output under $WORK_DIR." >&2
        return 1
    fi

    mkdir -p "$ROOT_DIR/post"
    out="$ROOT_DIR/post/$(basename "$dmg")"
    copy_with_retry "$dmg" "$out"

    echo "DMG ready: $out"
}

prepare_workspace
build_dmg
