#!/usr/bin/env bash

set -euo pipefail

CONFIG_FILE="backups.ini"
LOG_DIR="${HOME}/.backup_logs"
TMP_DIR="/tmp/db_backups"
DATE_TAG=$(date +%Y%m%d)

mkdir -p "$LOG_DIR" "$TMP_DIR"
trap 'rm -f "$TMP_DIR"/*.zip' EXIT

# --dry-run support
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1 && echo "💡 Dry-run mode enabled: no actions will be executed"

# Initialization
RCLONE_REMOTE=""
telegram_token=""
telegram_chat_id=""

# Telegram alert function
send_telegram_alert() {
    local message="$1"
    local token="$2"
    local chat_id="$3"
    local url="https://api.telegram.org/bot${token}/sendMessage"

    curl -s -X POST "$url" \
        -d "chat_id=$chat_id" \
        -d "text=$(echo "$message" | sed 's/"/\\"/g')" \
        -d "parse_mode=Markdown" > /dev/null
}

fail_and_exit() {
    local message="$1"
    echo "❌ $message"
    [[ -n "${telegram_token:-}" && -n "${telegram_chat_id:-}" ]] && send_telegram_alert "❗$message" "$telegram_token" "$telegram_chat_id"
    exit 1
}

# Environment checks
[[ -f "$CONFIG_FILE" ]] || fail_and_exit "Configuration file $CONFIG_FILE not found"
command -v rclone >/dev/null || fail_and_exit "rclone not installed"
command -v jq     >/dev/null || fail_and_exit "jq not installed"
command -v zip    >/dev/null || fail_and_exit "zip not installed"

# Parse [cloud] section
in_cloud_section=0
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    if [[ "$line" == "[cloud]" ]]; then
        in_cloud_section=1
        continue
    elif [[ "$line" =~ \[.*\] ]]; then
        in_cloud_section=0
    fi

    if (( in_cloud_section )); then
        if [[ "$line" == provider* ]]; then
            val="${line#*=}"
            RCLONE_REMOTE="$(echo "$val" | xargs)"
        elif [[ "$line" == telegram* ]]; then
            val="${line#*=}"
            val="${val// /}"
            telegram_token="${val%:*}"
            telegram_chat_id="${val##*:}"
            [[ -z "$telegram_token" || -z "$telegram_chat_id" ]] && fail_and_exit "Invalid telegram format in config"
        fi
    fi
done < "$CONFIG_FILE"

[[ -z "$RCLONE_REMOTE" ]] && fail_and_exit "Missing 'provider' in [cloud] section"
rclone lsd "$RCLONE_REMOTE": >/dev/null 2>&1 || fail_and_exit "rclone remote '$RCLONE_REMOTE' is not accessible"

# Cleanup: keep only the last 10 backups
cleanup_old_backups() {
    local remote_path="$1"
    echo "🧹 Cleaning up old backups in $RCLONE_REMOTE:$remote_path"

    rclone lsjson "$RCLONE_REMOTE:$remote_path" --files-only \
    | jq -r 'sort_by(.ModTime) | reverse | .[].Name' \
    | grep -E '^[^/]+_[0-9]{8}\\.zip$' \
    | tail -n +11 \
    | while read -r oldfile; do
        if (( DRY_RUN )); then
            echo "❌ [dry-run] Would remove: $oldfile"
        else
            echo "❌ Removing: $oldfile"
            rclone delete "$RCLONE_REMOTE:$remote_path/$oldfile"
        fi
    done
}

# Parse [objects] section
in_objects_section=0
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    if [[ "$line" == "[objects]" ]]; then
        in_objects_section=1
        continue
    elif [[ "$line" =~ \[.*\] ]]; then
        in_objects_section=0
    fi

    if (( in_objects_section )); then
        IFS='=' read -r _ val <<< "$line"
        IFS=';' read -r raw_path raw_days raw_cloud <<< "$val"
        local_path="$(echo "$raw_path" | xargs)"
        interval_days="$(echo "$raw_days" | xargs)"
        cloud_path="$(echo "$raw_cloud" | xargs)"

        safe_name=$(echo "$local_path" | sed 's|/|_|g')
        archive_name="${safe_name}_${DATE_TAG}.zip"
        archive_path="$TMP_DIR/$archive_name"
        log_file="$LOG_DIR/${safe_name}.last"

        last_ts=0
        [[ -f "$log_file" ]] && last_ts=$(<"$log_file")
        now_ts=$(date +%s)
        interval_sec=$((interval_days * 86400))
        next_allowed=$((last_ts + interval_sec))

        if (( now_ts >= next_allowed )); then
            success=1
            {
                if [[ ! -f "$local_path" ]]; then
                    echo "❗File not found: $local_path"
                    [[ -n "$telegram_token" && -n "$telegram_chat_id" ]] && send_telegram_alert "File not found: $local_path" "$telegram_token" "$telegram_chat_id"
                    continue
                fi

                echo "📦 Archiving $local_path → $archive_path"
                if (( DRY_RUN )); then
                    echo "📦 [dry-run] Would archive $local_path to $archive_path"
                else
                    zip -j "$archive_path" "$local_path" >/dev/null
                fi

                if (( ! DRY_RUN )) && [[ ! -s "$archive_path" ]]; then
                    echo "❗Archive is empty: $archive_path"
                    [[ -n "$telegram_token" && -n "$telegram_chat_id" ]] && send_telegram_alert "Archive is empty: $archive_path" "$telegram_token" "$telegram_chat_id"
                    continue
                fi

                if (( DRY_RUN )); then
                    echo "🚀 [dry-run] Would upload $archive_path to $RCLONE_REMOTE:$cloud_path/"
                else
                    echo "🚀 Uploading to $RCLONE_REMOTE:$cloud_path/"
                    rclone copyto "$archive_path" "$RCLONE_REMOTE:$cloud_path/$(basename "$archive_path")" --progress
                fi

                (( DRY_RUN )) || date +%s > "$log_file"
                echo "✅ Backup completed: $archive_name"

                (( DRY_RUN )) || cleanup_old_backups "$cloud_path"
                success=0
            } || true

            if (( success != 0 && ! DRY_RUN )); then
                err_msg="❗Error during backup *$local_path* → *$cloud_path*"
                echo "$err_msg"
                [[ -n "$telegram_token" && -n "$telegram_chat_id" ]] && send_telegram_alert "$err_msg" "$telegram_token" "$telegram_chat_id"
            fi
        else
            echo "⏭ Skipping $local_path — not yet due for backup"
        fi
    fi
done < "$CONFIG_FILE"
