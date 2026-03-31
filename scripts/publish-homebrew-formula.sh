#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/publish-homebrew-formula.sh --release-tag TAG [--self-check]

Options:
  --release-tag TAG   Git tag used by GitHub Release, for example v1.2.3
  --self-check        Validate prerequisites only.
  -h, --help          Show this help text.

Required environment variables:
  HOMEBREW_TAP_TOKEN  GitHub token with push permission to HOMEBREW_TAP_REPO

Optional environment variables:
  HOMEBREW_TAP_REPO   GitHub tap repository, defaults to linhay/homebrew-tap
  RELEASE_REPO        Release source repository, defaults to current repo
  HOMEBREW_FORMULA    Formula name, defaults to neptune
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RELEASE_TAG=""
SELF_CHECK=0

while (($# > 0)); do
    case "$1" in
        --release-tag)
            [[ $# -ge 2 ]] || { echo "Missing value for --release-tag" >&2; exit 1; }
            RELEASE_TAG="$2"
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

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "Required environment variable missing: $name" >&2
        exit 1
    fi
}

normalize_version() {
    local raw="$1"
    if [[ "$raw" =~ ^v(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    echo "$raw"
}

resolve_release_repo() {
    if [[ -n "${RELEASE_REPO:-}" ]]; then
        echo "${RELEASE_REPO}"
        return 0
    fi
    if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
        echo "${GITHUB_REPOSITORY}"
        return 0
    fi
    echo "Unable to resolve RELEASE_REPO. Set RELEASE_REPO explicitly." >&2
    exit 1
}

resolve_tap_repo() {
    if [[ -n "${HOMEBREW_TAP_REPO:-}" ]]; then
        echo "${HOMEBREW_TAP_REPO}"
        return 0
    fi
    echo "linhay/homebrew-tap"
}

resolve_artifact_sha256() {
    local release_repo="$1"
    local release_tag="$2"
    local artifact_name="$3"

    local checksum_file="${ROOT_DIR}/dist/cli-release/${artifact_name}.sha256"
    if [[ -f "$checksum_file" ]]; then
        local local_sha
        local_sha="$(awk '{print $1}' "$checksum_file" | head -n 1)"
        if [[ -n "$local_sha" ]]; then
            echo "$local_sha"
            return 0
        fi
        echo "Unable to parse sha256 from $checksum_file" >&2
        return 1
    fi

    local checksum_url="https://github.com/${release_repo}/releases/download/${release_tag}/${artifact_name}.sha256"
    local remote_checksum
    remote_checksum="$(curl -fsSL "$checksum_url" | awk '{print $1}' | head -n 1 || true)"
    if [[ -n "$remote_checksum" ]]; then
        echo "$remote_checksum"
        return 0
    fi

    echo "Checksum file not found locally and failed to fetch from release: $checksum_url" >&2
    return 1
}

write_formula() {
    local formula_path="$1"
    local formula_name="$2"
    local formula_class_name="$3"
    local version="$4"
    local release_repo="$5"
    local release_tag="$6"
    local artifact_name="$7"
    local sha256="$8"

    cat > "$formula_path" <<EOF
class ${formula_class_name} < Formula
  desc "Neptune gateway CLI"
  homepage "https://github.com/${release_repo}"
  version "${version}"
  url "https://github.com/${release_repo}/releases/download/${release_tag}/${artifact_name}"
  sha256 "${sha256}"
  license "MIT"

  def install
    bin.install "${artifact_name}" => "${formula_name}"
  end

  test do
    output = shell_output("#{bin}/${formula_name} --help", 0)
    assert_match "${formula_name}", output.downcase
  end
end
EOF
}

self_check() {
    require_command git
    require_command awk
    require_command curl
    require_env HOMEBREW_TAP_TOKEN
    [[ -n "$RELEASE_TAG" ]] || {
        echo "--release-tag is required in self-check mode." >&2
        exit 1
    }
    local release_repo artifact_name
    release_repo="$(resolve_release_repo)"
    artifact_name="neptune-${RELEASE_TAG}"
    resolve_tap_repo >/dev/null
    resolve_artifact_sha256 "$release_repo" "$RELEASE_TAG" "$artifact_name" >/dev/null
    echo "self-check ok: publish-homebrew-formula"
}

publish_formula() {
    require_command git
    require_command awk
    require_command curl
    require_env HOMEBREW_TAP_TOKEN
    [[ -n "$RELEASE_TAG" ]] || {
        echo "--release-tag is required." >&2
        exit 1
    }

    local tap_repo release_repo formula_name formula_class_name version artifact_name sha256
    tap_repo="$(resolve_tap_repo)"
    release_repo="$(resolve_release_repo)"
    formula_name="${HOMEBREW_FORMULA:-neptune}"
    formula_class_name="$(echo "$formula_name" | awk -F'[-_ ]+' '{for(i=1;i<=NF;i++){printf toupper(substr($i,1,1)) tolower(substr($i,2))}}')"
    version="$(normalize_version "$RELEASE_TAG")"
    artifact_name="neptune-${RELEASE_TAG}"
    sha256="$(resolve_artifact_sha256 "$release_repo" "$RELEASE_TAG" "$artifact_name")"
    [[ -n "$sha256" ]] || {
        echo "Unable to resolve sha256 for ${artifact_name}" >&2
        exit 1
    }

    local temp_dir tap_dir formula_dir formula_path
    temp_dir="$(mktemp -d)"
    tap_dir="${temp_dir}/tap"
    formula_dir="${tap_dir}/Formula"
    formula_path="${formula_dir}/${formula_name}.rb"

    git clone "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/${tap_repo}.git" "$tap_dir"
    mkdir -p "$formula_dir"

    write_formula "$formula_path" "$formula_name" "$formula_class_name" "$version" "$release_repo" "$RELEASE_TAG" "$artifact_name" "$sha256"

    pushd "$tap_dir" >/dev/null
    git config user.name "${GITHUB_ACTOR:-github-actions[bot]}"
    git config user.email "${GITHUB_ACTOR:-github-actions[bot]}@users.noreply.github.com"

    if [[ -z "$(git status --porcelain -- "$formula_path")" ]]; then
        echo "No formula changes detected. Skip publish."
        popd >/dev/null
        rm -rf "$temp_dir"
        return 0
    fi

    git add "$formula_path"
    git commit -m "chore(formula): ${formula_name} ${version}"
    git push origin HEAD
    popd >/dev/null
    rm -rf "$temp_dir"

    echo "Published Homebrew formula ${formula_name} ${version} to ${tap_repo}"
}

cd "$ROOT_DIR"

if [[ "$SELF_CHECK" -eq 1 ]]; then
    self_check
else
    publish_formula
fi
