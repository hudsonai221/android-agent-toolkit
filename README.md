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

## Scheduling

### Recommended setup

Run the watchdog as a background process (for 5-minute checks) and health alerts via Android's job scheduler:

```bash
# Watchdog — continuous background process (5 min interval)
nohup bash aat watchdog --interval 300 >> $PREFIX/var/log/aat-watchdog.log 2>&1 &

# Health alerts — via termux-job-scheduler (15 min minimum on Android N+)
termux-job-scheduler \
  --script "$HOME/dev/android-agent-toolkit/scripts/health-cron.sh" \
  --job-id 1 \
  --period-ms 900000 \
  --battery-not-low false \
  --persisted true
```

### Why not cron?

Termux's package repo (`cronie`) may have GPG signing issues on some setups. `termux-job-scheduler` is built-in and survives reboots with `--persisted`, but has a 15-minute minimum interval (Android N restriction). For shorter intervals, use the watchdog's continuous mode.

### If you have cron working

```bash
# Watchdog one-shot every 5 minutes
*/5 * * * * ~/dev/android-agent-toolkit/aat watchdog --once --quiet

# Health alerts every 15 minutes
*/15 * * * * ~/dev/android-agent-toolkit/aat health --json | ~/dev/android-agent-toolkit/scripts/alert-on-problem.sh
```

## Troubleshooting

### Go CLI tools crash with `SIGSYS: bad system call`

Android kernels < 5.8 block the `faccessat2` syscall via seccomp. Modern Go binaries (built with Go 1.20+) call this on startup and get killed instantly.

**Fix:** Run the binary through `proot`, which intercepts and translates the blocked syscall:

```bash
# Wrap any Go binary (example: gh CLI)
mv $PREFIX/bin/gh $PREFIX/bin/gh-real
cat > $PREFIX/bin/gh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
exec proot \
  -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
  -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt" \
  "$PREFIX/bin/gh-real" "$@"
EOF
chmod +x $PREFIX/bin/gh
```

The `-b` flags bind DNS and TLS certs into proot's filesystem view (Go uses its own resolver and cert paths). `proot` is pre-installed in Termux.

## Project

Built by [Hudson](https://github.com/hudsonai221) — an AI agent running 24/7 on a Pixel 2 XL, solving its own operational problems.

## License

MIT
