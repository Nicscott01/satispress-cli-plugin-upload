# SatisPress CLI Plugin Upload

Small Bash utility for uploading a local premium WordPress plugin zip to a SatisPress server and installing or updating it with WP-CLI.

This is intended for workflows where you download premium plugin updates locally, then need to push them to a packages server that runs WordPress plus the SatisPress plugin for Bedrock or Composer-based installs.

The repository contains only a safe example config. Your real server settings live in a local config file that is ignored by git.

## What It Does

- Uploads a local plugin zip to the packages server over SSH/SCP
- Runs `wp plugin install <zip> --force` on the remote WordPress install
- Preserves the plugin's previous activation state by default
- Uses a local config file so host, user, and WordPress path do not need to be typed every time

## Files

- `satispress-plugin-upload.sh`
- `satispress-plugin-upload.conf.example`
- `satispress-plugin-upload.conf` (local, ignored by git)

## Requirements

- Bash
- `ssh`
- `scp`
- `unzip`
- SSH key access to the packages server
- `wp` available on the remote server
- A WordPress install on the remote server with SatisPress available

## Config

Copy the example config and then edit your local config:

```bash
cp satispress-plugin-upload.conf.example satispress-plugin-upload.conf
```

Edit `satispress-plugin-upload.conf`:

```bash
HOST="packages.example.com"
USER_NAME="packages"
WP_PATH="/path/to/wordpress"
```

Optional settings:

```bash
# SSH_PORT="22"
# IDENTITY_FILE="${HOME}/.ssh/id_rsa"
# WP_BIN="wp"
# WP_URL=""
# REMOTE_TMP_DIR="/tmp"
```

## Usage

Basic:

```bash
./satispress-plugin-upload.sh ~/Downloads/fluentformpro.6.1.21.zip
```

The script will load `./satispress-plugin-upload.conf` automatically when it exists.

Override config values for a single run:

```bash
./satispress-plugin-upload.sh \
  --path /path/to/wordpress \
  --identity ~/.ssh/id_rsa \
  ~/Downloads/gravityforms.zip
```

Force activation after install:

```bash
./satispress-plugin-upload.sh --activate ~/Downloads/plugin.zip
```

Leave plugin inactive:

```bash
./satispress-plugin-upload.sh --inactive ~/Downloads/plugin.zip
```

## Common Options

- `--slug your-plugin-slug`
- `--identity ~/.ssh/keyfile`
- `--port 2222`
- `--activate`
- `--activate-network`
- `--inactive`
- `--config /path/to/config`
- `--no-config`

Run `./satispress-plugin-upload.sh --help` for the full option list.

## Notes

- The plugin should already be selected in SatisPress if you expect it to appear in `packages.json`.
- The script uploads the zip to a remote temp directory, installs it, then removes the uploaded zip unless `--keep-remote-zip` is used.
- CLI flags override environment variables, and environment variables override the config file.
- The committed `satispress-plugin-upload.conf.example` file is a template only. Keep real server details in the ignored `satispress-plugin-upload.conf`.
