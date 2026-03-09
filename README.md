# Android Agent Toolkit

Operational tooling for running [OpenClaw](https://github.com/openclaw/openclaw) reliably on Android (Termux).

**Not another setup guide.** This is what you need *after* installation — monitoring, auto-recovery, backup, and benchmarking for long-term agent hosting on a phone.

## Tools

| Tool | Description | Status |
|------|-------------|--------|
| `aat status` | Combined system dashboard — gateway, watchdog, backups, resources | ✅ |
| `aat logs` | Unified log viewer — gateway, watchdog, cron runs | ✅ |
| `aat health` | Detailed health checks — gateway, RAM, storage, battery, temperature | ✅ |
| `aat watchdog` | Auto-restart gateway on crash, alert on failures | ✅ |
| `aat backup` | One-command workspace + config backup | ✅ |
| `aat bench` | Device compatibility benchmarker | ✅ |

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
# System dashboard (one command to check everything)
./aat status

# One-line summary
./aat status --brief

# View recent logs from all sources
./aat logs

# Full health check
./aat health

# JSON output (for scripting/cron)
./aat health --json
```

## Status

Single-glance dashboard combining gateway state, watchdog health, backup status, and system resources:

```bash
# Full dashboard
./aat status

# One-line summary (great for scripts)
./aat status --brief
# → ✓ ok | gw:up rpc:ok | wd:cron | bk:2d ago | ram:69% disk:19% bat:100% | load:4.0 up:4d

# JSON output
./aat status --json
```

Shows: gateway process + RPC status + uptime, watchdog state (daemon/cron/off), last backup age, RAM/swap/disk usage, battery level + temperature, system load + uptime. Color-coded with ✓/⚠/✗ indicators.

## Logs

Unified log viewer across gateway, watchdog, and cron job runs:

```bash
# Last 50 lines from all sources
./aat logs

# Specific source
./aat logs watchdog
./aat logs gateway
./aat logs cron

# Control output
./aat logs -n 100              # More lines
./aat logs --grep "restart"    # Search across logs
./aat logs --since 1h          # Entries from last hour
./aat logs watchdog -f         # Follow watchdog log in real-time

# Raw/JSON output
./aat logs --raw
```

Sources:
- **gateway** — OpenClaw command log (session creates, resets)
- **watchdog** — AAT watchdog activity (health checks, restarts)
- **cron** — OpenClaw cron job runs with job names and status

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

## Backup

Create compressed backups of your OpenClaw workspace and configuration:

```bash
# Essential backup (config, credentials, workspace)
./aat backup

# Full backup (includes session history, memory vectors, media)
./aat backup --full

# Save to specific location
./aat backup --output /sdcard/

# Preview what would be backed up
./aat backup --dry-run

# List existing backups
./aat backup --list

# JSON output (for scripting)
./aat backup --json
```

**What's backed up:**

| Mode | Contents | Typical Size |
|------|----------|-------------|
| Essential (default) | Config, credentials, identity, cron jobs, workspace files, crontab | ~400 KB |
| Full (`--full`) | Everything above + session history, completions, memory vectors, media, logs | ~5-20 MB |

Backups are stored as timestamped `.tar.gz` archives in `~/backups/` by default. The archive uses a clean directory structure (`openclaw-config/`, `workspace/`) for easy browsing.

## Benchmark

Test your device's compatibility with OpenClaw and identify bottlenecks:

```bash
# Full benchmark (CPU, memory, disk, Node.js, gateway, network)
./aat bench

# Quick mode (smaller tests, faster results)
./aat bench --quick

# JSON output (for tracking over time)
./aat bench --json
```

**What's tested:**

| Test | Measures | Weight |
|------|----------|--------|
| CPU | SHA256 hash throughput (MB/s) | 25% |
| Memory | Available RAM vs. thresholds | 25% |
| Disk I/O | Sequential write/read speed (MB/s) | 15% |
| Node.js | Cold startup time (ms) | 15% |
| Gateway RPC | Localhost roundtrip latency (ms) | 10% |
| Network | HTTPS latency to api.anthropic.com (ms) | 10% |

**Score ranges:**

| Score | Rating | Meaning |
|-------|--------|---------|
| 90-100 | Excellent | Runs OpenClaw smoothly |
| 70-89 | Good | Handles most workloads |
| 50-69 | Adequate | May struggle under heavy load |
| 30-49 | Marginal | Expect slowdowns and memory pressure |
| 0-29 | Poor | Likely to crash or timeout frequently |

If the gateway isn't running, it's excluded from scoring and the remaining weights are redistributed. Below 70, you'll get specific recommendations (e.g., "close other apps" for low RAM).

**Example output (Pixel 2 XL, `--quick`):**

```
Android Agent Toolkit — Device Benchmark

Device: Qualcomm Technologies, Inc MSM8998 | 8 cores | aarch64

CPU
  ✓ SHA256 throughput: 181 MB/s (8 MB in 44 ms)
     Score: 95/100

Memory
  ✓ Available: 1281 MB / 3662 MB total
     Score: 81/100

Disk I/O
  ⚠ Write: 82 MB/s | Read: 410 MB/s (16 MB test)
     Score: 43/100

Node.js
  ✓ Startup: 87 ms (v22.22.0)
     Score: 100/100

Gateway RPC
  ✓ Latency: 41 ms (port 18789)
     Score: 83/100

Network
  ✓ API latency: 264 ms (api.anthropic.com)
     Score: 95/100

═══════════════════════════════════════
✓ Overall: 83/100 — Good
```

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
