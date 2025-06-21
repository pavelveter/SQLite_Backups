# 🔐 Automated SQLite Backup to Cloud with rclone + Telegram Alerts

This script automates the process of archiving `.db` files, uploading them to a cloud via `rclone`, and cleaning up old backups. It also supports error reporting to Telegram.

---

## ✨ Features

- Backups SQLite `.db` files defined in `backups.ini`
- Archives files to `.zip` with date stamp `YYYYMMDD.zip`
- Uploads via `rclone copyto` to Mail.ru or any `rclone` remote
- Keeps only the latest 10 backups per destination
- Sends error alerts via Telegram
- Safe `--dry-run` mode
- Cron-job friendly

---

## 📁 Config file: `backups.ini`

```ini
[cloud]
provider = mailru
telegram = 749640157:AAEy...fwE:-1001234567890

[objects]
1 = /home/user/project.db;7;Backups/Project
2 = /home/user/another.db;1;Backups/Another
```

- `provider` — must match a configured `rclone` remote
- `telegram` — in format `<bot_token>:<chat_id>`, supports channels too
- `[objects]` — entries in format `<local_path>;<days_interval>;<remote_folder>`

---

## 🛠 Requirements

- `rclone` (configured remote e.g. `mailru`)
- `jq` (for JSON processing)
- `zip`
- `curl`

Install on Debian/Ubuntu:

```bash
sudo apt install rclone jq zip curl
```

---

## 🚀 Usage

### Manual run:
```bash
./backup.sh
```

### Dry-run mode:
```bash
./backup.sh --dry-run
```

### Cron example (4:20 AM daily):
```bash
crontab -e
```

```cron
20 4 * * * /home/user/backups/backup.sh >> /home/user/backups/backup.log 2>&1
```

---

## 📦 Output

- Logs stored in `~/.backup_logs/`
- Archives created in `/tmp/db_backups/` (auto-cleaned)
- Telegram alerts sent only on failure

---

## ❤️ Author

Crafted with care for personal DevOps automation. Extend freely!
