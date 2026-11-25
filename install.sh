#!/usr/bin/env bash
#
# Install the Remote Browser CLI (remotebrowser) from the latest stable GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/remotebrowser/cli/main/install.sh | bash
#
# Environment variables:
#   REMOTEBROWSER_INSTALL_DIR  where to put the binary (default: ~/.local/bin)
#   REMOTEBROWSER_VERSION      a version to install instead of the latest, such as 0.2.0

# Everything is inside main, so a partial download of this script runs nothing.
main() {
  set -euo pipefail

  local repo=remotebrowser/cli
  local install_dir=${REMOTEBROWSER_INSTALL_DIR:-$HOME/.local/bin}

  command -v curl >/dev/null || fatal "curl is required"
  command -v tar >/dev/null || fatal "tar is required"

  local os arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    FreeBSD) os=freebsd ;;
    MINGW* | MSYS* | CYGWIN*) fatal "on Windows, download the zip file from https://github.com/$repo/releases/latest" ;;
    *) fatal "unsupported operating system: $(uname -s)" ;;
  esac

  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    armv7* | armv8l) arch=armv7 ;;
    riscv64) arch=riscv64 ;;
    *) fatal "unsupported architecture: $(uname -m)" ;;
  esac

  # A shell running under Rosetta reports x86_64 on Apple silicon; prefer the native binary.
  if [[ $os == macos && $arch == x86_64 ]] && [[ $(sysctl -n sysctl.proc_translated 2>/dev/null) == 1 ]]; then
    arch=aarch64
  fi

  case "$os-$arch" in
    linux-x86_64 | linux-aarch64 | linux-armv7 | linux-riscv64 | macos-x86_64 | macos-aarch64 | freebsd-x86_64) ;;
    *) fatal "unsupported platform: $os $arch" ;;
  esac

  local version=${REMOTEBROWSER_VERSION:-}
  version=${version#v}
  if [[ -z $version ]]; then
    # /releases/latest redirects to the newest release that is not a prerelease or a draft.
    local url
    url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest") ||
      fatal "cannot find the latest release of $repo"
    version=${url##*/tag/v}
    [[ $version != "$url" && -n $version ]] || fatal "cannot find the latest release of $repo"
  fi

  local name=remotebrowser-$version-$os-$arch
  local base=https://github.com/$repo/releases/download/v$version

  # Not local: the EXIT trap runs after main returns.
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' EXIT

  info "Downloading remotebrowser $version for $os $arch"
  curl -fsSL -o "$tmp/$name.tar.gz" "$base/$name.tar.gz" || fatal "cannot download $base/$name.tar.gz"
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || fatal "cannot download $base/SHA256SUMS"

  local expected actual
  expected=$(awk -v f="$name.tar.gz" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
  [[ -n $expected ]] || fatal "$name.tar.gz is not listed in SHA256SUMS"
  if command -v sha256sum >/dev/null; then
    actual=$(sha256sum "$tmp/$name.tar.gz" | awk '{ print $1 }')
  elif command -v shasum >/dev/null; then
    actual=$(shasum -a 256 "$tmp/$name.tar.gz" | awk '{ print $1 }')
  elif command -v sha256 >/dev/null; then
    actual=$(sha256 -q "$tmp/$name.tar.gz")
  else
    fatal "sha256sum, shasum, or sha256 is required to verify the download"
  fi
  [[ $actual == "$expected" ]] || fatal "checksum mismatch for $name.tar.gz"

  tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
  mkdir -p "$install_dir"
  install -m 755 "$tmp/$name/remotebrowser" "$install_dir/remotebrowser"
  info "Installed $install_dir/remotebrowser"

  case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) info "Add $install_dir to your PATH to run remotebrowser" ;;
  esac
}

info() {
  printf '%s\n' "$*"
}

fatal() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

main "$@"
