#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/build-cli-release.sh [--output-dir DIR] [--self-check]

Options:
  --output-dir DIR   Release artifact output directory.
  --self-check       Validate the script prerequisites without building.
  -h, --help         Show this help text.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PRODUCT_NAME="neptune"
OUTPUT_DIR="${ROOT_DIR}/dist/cli-release"
SELF_CHECK=0

while (($# > 0)); do
    case "$1" in
        --output-dir)
            [[ $# -ge 2 ]] || { echo "Missing value for --output-dir" >&2; exit 1; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --self-check)
            SELF_CHECK=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_command() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        echo "Required command not found: $name" >&2
        exit 1
    fi
}

require_checksum_command() {
    if command -v shasum >/dev/null 2>&1; then
        return 0
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        return 0
    fi

    echo "Required command not found: shasum or sha256sum" >&2
    exit 1
}

compute_sha256() {
    local file_path="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file_path" | awk '{print $1}'
        return 0
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file_path" | awk '{print $1}'
        return 0
    fi

    require_checksum_command
}

resolve_swift() {
    if command -v xcrun >/dev/null 2>&1; then
        xcrun --find swift
        return 0
    fi

    command -v swift
}

resolve_version() {
    if git -C "$ROOT_DIR" describe --tags --always --dirty --abbrev=12 >/dev/null 2>&1; then
        git -C "$ROOT_DIR" describe --tags --always --dirty --abbrev=12
        return 0
    fi

    git -C "$ROOT_DIR" rev-parse --short=12 HEAD
}

self_check() {
    require_command git
    require_command awk
    require_checksum_command

    [[ -f "${ROOT_DIR}/Package.swift" ]] || {
        echo "Package.swift not found at repository root." >&2
        exit 1
    }

    echo "self-check ok: ${PRODUCT_NAME}"
}

build_release() {
    require_command git
    require_command awk
    require_checksum_command

    mkdir -p "$OUTPUT_DIR"

    local swift_bin
    swift_bin="$(resolve_swift)"

    local version
    version="$(resolve_version)"

    echo "Building ${PRODUCT_NAME} release with version ${version}"
    "$swift_bin" build --package-path "$ROOT_DIR" -c release --product "$PRODUCT_NAME"

    local binary_dir binary_path artifact_name artifact_path checksum checksum_file manifest_path built_at commit
    binary_dir="$("$swift_bin" build --package-path "$ROOT_DIR" --show-bin-path -c release --product "$PRODUCT_NAME")"
    binary_path="${binary_dir}/${PRODUCT_NAME}"
    artifact_name="${PRODUCT_NAME}-${version}"
    artifact_path="${OUTPUT_DIR}/${artifact_name}"
    checksum_file="${artifact_path}.sha256"
    manifest_path="${OUTPUT_DIR}/${artifact_name}.release-info.txt"
    built_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    commit="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"

    [[ -f "$binary_path" ]] || {
        echo "Release binary not found: $binary_path" >&2
        exit 1
    }

    cp "$binary_path" "$artifact_path"
    chmod +x "$artifact_path"

    checksum="$(compute_sha256 "$artifact_path")"
    printf '%s  %s\n' "$checksum" "$artifact_name" > "$checksum_file"

    cat > "$manifest_path" <<EOF
version=${version}
commit=${commit}
built_at=${built_at}
binary=${artifact_name}
sha256=${checksum}
source_binary=${binary_path}
EOF

    cat <<EOF
Release artifacts written to: ${OUTPUT_DIR}
Binary: ${artifact_path}
Checksum: ${checksum_file}
Manifest: ${manifest_path}
EOF
}

cd "$ROOT_DIR"

if [[ "$SELF_CHECK" -eq 1 ]]; then
    self_check
else
    build_release
fi
