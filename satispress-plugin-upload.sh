#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/satispress-plugin-upload.conf"

usage() {
  cat <<'EOF'
Upload a local premium plugin zip to a WordPress packages server and install/update it with WP-CLI.

Usage:
  satispress-plugin-upload.sh --zip /path/to/plugin.zip --host packages.example.com --user deploy --path /srv/www/site/current/web/wp
  satispress-plugin-upload.sh /path/to/plugin.zip

Default config file:
EOF
  printf '  %s\n' "$DEFAULT_CONFIG_FILE"
  cat <<'EOF'

Required unless provided by environment variables:
  --zip, -z           Local path to the plugin zip file.
  --host              SSH host for the packages server. Env: SATISPRESS_HOST
  --user              SSH user for the packages server. Env: SATISPRESS_USER
  --path              Remote WordPress path. Env: SATISPRESS_WP_PATH

Optional:
  --slug              Plugin slug. Defaults to the zip's top-level folder name.
  --port              SSH port. Env: SATISPRESS_SSH_PORT (default: 22)
  --identity, -i      SSH identity file. Env: SATISPRESS_IDENTITY_FILE
  --wp-bin            Remote WP-CLI binary. Env: SATISPRESS_WP_BIN (default: wp)
  --url               WordPress URL for multisite/context-specific commands. Env: SATISPRESS_WP_URL
  --remote-tmp-dir    Remote temp directory. Env: SATISPRESS_REMOTE_TMP_DIR (default: /tmp)
  --config            Load a specific config file.
  --no-config         Ignore the default config file.
  --activate          Activate after install.
  --activate-network  Network-activate after install.
  --inactive          Leave deactivated after install.
  --no-satispress-check
                      Skip checking whether the SatisPress plugin is installed.
  --keep-remote-zip   Keep the uploaded zip on the server after install.
  --help, -h          Show this help.

Default activation behavior:
  Preserve the plugin's current activation status. If it was active, reactivate it.

Environment variable shortcut:
  export SATISPRESS_HOST=packages.example.com
  export SATISPRESS_USER=deploy
  export SATISPRESS_WP_PATH=/srv/www/packages/current/web/wp
  ./satispress-plugin-upload.sh ~/Downloads/gravityforms.zip

Notes:
  - This installs the zip with `wp plugin install <zip> --force`.
  - The plugin should already be added to the SatisPress repository in wp-admin if you expect it to appear in packages.json.
  - Precedence is: script defaults < config file < environment variables < CLI flags.
EOF
}

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

abspath() {
  local target="$1"
  local dir
  dir="$(cd "$(dirname "$target")" && pwd -P)"
  printf '%s/%s\n' "$dir" "$(basename "$target")"
}

zip_root_dir() {
  local zip_file="$1"
  local root

  root="$(
    unzip -Z1 "$zip_file" \
      | awk -F/ 'NF && $1 != "__MACOSX" { print $1; exit }'
  )"

  [[ -n "$root" ]] || die "Unable to determine plugin slug from zip: $zip_file"
  printf '%s\n' "$root"
}

zip_plugin_version() {
  local zip_file="$1"
  local root="$2"
  local php_file
  local version

  php_file="$(
    unzip -Z1 "$zip_file" \
      | awk -F/ -v root="$root" '
          $1 == root && NF == 2 && $2 ~ /\.php$/ {
            print $0
            exit
          }
        '
  )"

  if [[ -z "$php_file" ]]; then
    return 0
  fi

  version="$(
    unzip -p "$zip_file" "$php_file" 2>/dev/null \
      | awk '
          BEGIN { IGNORECASE=1 }
          /^[[:space:]]*Version:[[:space:]]*/ {
            sub(/^[[:space:]]*Version:[[:space:]]*/, "", $0)
            print
            exit
          }
        '
  )"

  printf '%s\n' "$version"
}

ZIP_PATH="${SATISPRESS_ZIP_PATH:-}"
HOST=""
USER_NAME=""
WP_PATH=""
SSH_PORT="22"
IDENTITY_FILE=""
WP_BIN="wp"
WP_URL=""
REMOTE_TMP_DIR="/tmp"
PLUGIN_SLUG=""
ACTIVATION_MODE="preserve"
CHECK_SATISPRESS=1
KEEP_REMOTE_ZIP=0
USE_CONFIG=1
CONFIG_FILE="$DEFAULT_CONFIG_FILE"

load_config_file() {
  local file="$1"

  [[ -f "$file" ]] || die "Config file not found: $file"

  # shellcheck disable=SC1090
  source "$file"
}

ARGS=("$@")

for ((i = 0; i < ${#ARGS[@]}; i++)); do
  case "${ARGS[$i]}" in
    --config)
      (( i + 1 < ${#ARGS[@]} )) || die "Missing value for --config"
      CONFIG_FILE="${ARGS[$((i + 1))]}"
      ;;
    --no-config)
      USE_CONFIG=0
      ;;
  esac
done

if [[ "$USE_CONFIG" == "1" && -f "$CONFIG_FILE" ]]; then
  load_config_file "$CONFIG_FILE"
fi

ZIP_PATH="${SATISPRESS_ZIP_PATH:-$ZIP_PATH}"
HOST="${SATISPRESS_HOST:-${HOST:-}}"
USER_NAME="${SATISPRESS_USER:-${USER_NAME:-}}"
WP_PATH="${SATISPRESS_WP_PATH:-${WP_PATH:-}}"
SSH_PORT="${SATISPRESS_SSH_PORT:-${SSH_PORT:-22}}"
IDENTITY_FILE="${SATISPRESS_IDENTITY_FILE:-${IDENTITY_FILE:-}}"
WP_BIN="${SATISPRESS_WP_BIN:-${WP_BIN:-wp}}"
WP_URL="${SATISPRESS_WP_URL:-${WP_URL:-}}"
REMOTE_TMP_DIR="${SATISPRESS_REMOTE_TMP_DIR:-${REMOTE_TMP_DIR:-/tmp}}"
PLUGIN_SLUG="${SATISPRESS_PLUGIN_SLUG:-${PLUGIN_SLUG:-}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip|-z)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      ZIP_PATH="$2"
      shift 2
      ;;
    --host)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      HOST="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      USER_NAME="$2"
      shift 2
      ;;
    --path)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      WP_PATH="$2"
      shift 2
      ;;
    --slug)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      PLUGIN_SLUG="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      SSH_PORT="$2"
      shift 2
      ;;
    --identity|-i)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      IDENTITY_FILE="$2"
      shift 2
      ;;
    --wp-bin)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      WP_BIN="$2"
      shift 2
      ;;
    --url)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      WP_URL="$2"
      shift 2
      ;;
    --remote-tmp-dir)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      REMOTE_TMP_DIR="$2"
      shift 2
      ;;
    --config)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --no-config)
      shift
      ;;
    --activate)
      ACTIVATION_MODE="activate"
      shift
      ;;
    --activate-network)
      ACTIVATION_MODE="activate-network"
      shift
      ;;
    --inactive)
      ACTIVATION_MODE="inactive"
      shift
      ;;
    --no-satispress-check)
      CHECK_SATISPRESS=0
      shift
      ;;
    --keep-remote-zip)
      KEEP_REMOTE_ZIP=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -z "$ZIP_PATH" ]]; then
        ZIP_PATH="$1"
      else
        die "Unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

require_command unzip
require_command ssh
require_command scp
require_command date

[[ -n "$ZIP_PATH" ]] || die "A plugin zip is required. Use --zip or pass the path as the first argument."
[[ -n "$HOST" ]] || die "SSH host is required. Use --host or SATISPRESS_HOST."
[[ -n "$USER_NAME" ]] || die "SSH user is required. Use --user or SATISPRESS_USER."
[[ -n "$WP_PATH" ]] || die "Remote WordPress path is required. Use --path or SATISPRESS_WP_PATH."
[[ -f "$ZIP_PATH" ]] || die "Zip file not found: $ZIP_PATH"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH port must be numeric: $SSH_PORT"

ZIP_PATH="$(abspath "$ZIP_PATH")"

if [[ -z "$PLUGIN_SLUG" ]]; then
  PLUGIN_SLUG="$(zip_root_dir "$ZIP_PATH")"
fi

ZIP_VERSION="$(zip_plugin_version "$ZIP_PATH" "$PLUGIN_SLUG")"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
REMOTE_ZIP_PATH="${REMOTE_TMP_DIR%/}/${PLUGIN_SLUG}-${TIMESTAMP}.zip"

SSH_CMD=(ssh)
SCP_CMD=(scp)

if [[ -n "$IDENTITY_FILE" ]]; then
  SSH_CMD+=(-i "$IDENTITY_FILE")
  SCP_CMD+=(-i "$IDENTITY_FILE")
fi

if [[ "$SSH_PORT" != "22" ]]; then
  SSH_CMD+=(-p "$SSH_PORT")
  SCP_CMD+=(-P "$SSH_PORT")
fi

TARGET="${USER_NAME}@${HOST}"

info "Preparing upload for plugin slug: ${PLUGIN_SLUG}"
if [[ -n "$ZIP_VERSION" ]]; then
  info "Detected zip version: ${ZIP_VERSION}"
fi
info "Ensuring remote temp directory exists: ${REMOTE_TMP_DIR}"

"${SSH_CMD[@]}" "$TARGET" /bin/bash -s -- "$REMOTE_TMP_DIR" <<'REMOTE_MKDIR'
set -euo pipefail
mkdir -p "$1"
REMOTE_MKDIR

info "Uploading ${ZIP_PATH} to ${TARGET}:${REMOTE_ZIP_PATH}"

"${SCP_CMD[@]}" "$ZIP_PATH" "${TARGET}:${REMOTE_ZIP_PATH}"

info "Running remote WP-CLI install/update"

REMOTE_INSTALL_CMD="$(
  printf \
    'WP_PATH=%q WP_BIN=%q WP_URL=%q PLUGIN_SLUG=%q PLUGIN_ZIP=%q ACTIVATION_MODE=%q KEEP_REMOTE_ZIP=%q CHECK_SATISPRESS=%q /bin/bash -s' \
    "$WP_PATH" \
    "$WP_BIN" \
    "$WP_URL" \
    "$PLUGIN_SLUG" \
    "$REMOTE_ZIP_PATH" \
    "$ACTIVATION_MODE" \
    "$KEEP_REMOTE_ZIP" \
    "$CHECK_SATISPRESS"
)"

"${SSH_CMD[@]}" "$TARGET" "$REMOTE_INSTALL_CMD" <<'REMOTE_SCRIPT'
set -euo pipefail

wp_path="${WP_PATH:?WP_PATH is required}"
wp_bin="${WP_BIN:-wp}"
wp_url="${WP_URL:-}"
plugin_slug="${PLUGIN_SLUG:?PLUGIN_SLUG is required}"
plugin_zip="${PLUGIN_ZIP:?PLUGIN_ZIP is required}"
activation_mode="${ACTIVATION_MODE:-preserve}"
keep_remote_zip="${KEEP_REMOTE_ZIP:-0}"
check_satispress="${CHECK_SATISPRESS:-1}"

wp_cmd() {
  if [[ -n "$wp_url" ]]; then
    "$wp_bin" --path="$wp_path" --url="$wp_url" "$@"
  else
    "$wp_bin" --path="$wp_path" "$@"
  fi
}

cleanup() {
  if [[ "$keep_remote_zip" != "1" ]]; then
    rm -f "$plugin_zip"
  fi
}

trap cleanup EXIT

wp_cmd core is-installed >/dev/null

if [[ "$check_satispress" == "1" ]]; then
  if ! wp_cmd plugin is-installed satispress >/dev/null 2>&1; then
    echo "Warning: SatisPress is not installed at ${wp_path}." >&2
  fi
fi

previous_status="missing"
previous_version=""

if wp_cmd plugin is-installed "$plugin_slug" >/dev/null 2>&1; then
  previous_status="$(wp_cmd plugin get "$plugin_slug" --field=status)"
  previous_version="$(wp_cmd plugin get "$plugin_slug" --field=version)"
fi

if [[ "$previous_status" == "missing" ]]; then
  echo "Remote plugin state: not installed"
else
  echo "Remote plugin state: ${previous_status} (${previous_version})"
fi

wp_cmd plugin install "$plugin_zip" --force

case "$activation_mode" in
  preserve)
    if [[ "$previous_status" == "active" ]]; then
      wp_cmd plugin activate "$plugin_slug" >/dev/null
    elif [[ "$previous_status" == "active-network" ]]; then
      wp_cmd plugin activate "$plugin_slug" --network >/dev/null
    fi
    ;;
  activate)
    wp_cmd plugin activate "$plugin_slug" >/dev/null
    ;;
  activate-network)
    wp_cmd plugin activate "$plugin_slug" --network >/dev/null
    ;;
  inactive)
    current_status="$(wp_cmd plugin get "$plugin_slug" --field=status)"
    if [[ "$current_status" == "active-network" ]]; then
      wp_cmd plugin deactivate "$plugin_slug" --network >/dev/null
    elif [[ "$current_status" == "active" ]]; then
      wp_cmd plugin deactivate "$plugin_slug" >/dev/null
    fi
    ;;
  *)
    echo "Error: unsupported activation mode: ${activation_mode}" >&2
    exit 1
    ;;
esac

echo "Remote plugin state after install:"
wp_cmd plugin get "$plugin_slug" --fields=name,status,version --format=json
REMOTE_SCRIPT

info "Plugin upload/install complete"
