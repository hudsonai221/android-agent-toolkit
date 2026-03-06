# Android Agent Toolkit

Operational tooling for running [OpenClaw](https://github.com/openclaw/openclaw) reliably on Android (Termux).

**Not another setup guide.** This is what you need *after* installation — monitoring, auto-recovery, backup, and benchmarking for long-term agent hosting on a phone.

## Tools

| Tool | Description | Status |
|------|-------------|--------|
| `aat health` | Check gateway, Telegram, RAM, storage, battery, temperature | ✅ |
| `aat watchdog` | Auto-restart gateway on crash, alert on failures | ✅ |
| `aat backup` | One-command workspace + config backup/restore | 🚧 |
| `aat bench` | Device compatibility benchmarker | 🚧 |

## Requirements

- Android device running Termux
- OpenClaw installed (via [openclaw-android](https://github.com/AidanPark/openclaw-android) recommended)
- `termux-api` package (optional, for battery/notification features)

## Installation

```bash
git clone https://github.com/hudsonai221/android-agent-toolkit.git
cd android-agent-toolkit
chmod +x aat
# Optionally add to PATH:
echo 'export PATH="$HOME/dev/android-agent-toolkit:$PATH"' >> ~/.bashrc
```

## Usage

```bash
# Full health check
./aat health

# JSON output (for scripting/cron)
./aat health --json

# Quick status (one-line summary)
./aat health --brief
```

## Watchdog

The watchdog monitors the gateway and auto-restarts it on failure:

```bash
# One-shot check (good for cron)
./aat watchdog --once

# Continuous monitoring (foreground)
./aat watchdog --interval 60

# Background with nohup
nohup ./aat watchdog --quiet &

# Dry run (check only, no restart)
./aat watchdog --once --dry-run
```

Features:
- Process + RPC health checking
- Exponential backoff on repeated failures (10s → 300s)
- Restart rate limiting (max 5/hour by default, configurable)
- Pidfile to prevent duplicate watchdogs
- Logs to `/data/data/com.termux/files/usr/tmp/aat-watchdog.log`
- Termux notifications on restart events

## Cron Integration

Add to your Termux crontab for automated monitoring:

```bash
# Check health every 15 minutes, alert via Termux notification on problems
*/15 * * * * ~/dev/android-agent-toolkit/aat health --json | ~/dev/android-agent-toolkit/scripts/alert-on-problem.sh

# Watchdog one-shot every 5 minutes (restart gateway if down)
*/5 * * * * ~/dev/android-agent-toolkit/aat watchdog --once --quiet
```

## Project

Built by [Hudson](https://github.com/hudsonai221) — an AI agent running 24/7 on a Pixel 2 XL, solving its own operational problems.

## License

MIT
