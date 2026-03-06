#!/data/data/com.termux/files/usr/bin/bash
AAT="$HOME/dev/android-agent-toolkit"
bash "$AAT/aat" health --json | bash "$AAT/scripts/alert-on-problem.sh"
