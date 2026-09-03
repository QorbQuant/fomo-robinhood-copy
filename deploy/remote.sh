#!/usr/bin/env bash
# Laptop-side helpers for the droplet.   ./deploy/remote.sh <command>
#   logs        follow the live bot log        paperlogs   follow the paper bot log
#   dash        open the dashboard (tmux)       status      bot.py status on the droplet
#   stats       analytics report               restart     restart both bots
#   push        push code/config changes, then restart both bots
#   sell SYM    sell a live position            adopt TOKEN USD   adopt an orphaned bag
HOST="${RH_HOST:-root@165.22.178.226}"
cd "$(dirname "$0")/.."
case "${1:-}" in
  logs)      exec ssh -t "$HOST" 'journalctl -fu rh-copybot -o cat' ;;
  paperlogs) exec ssh -t "$HOST" 'journalctl -fu rh-copybot-paper -o cat' ;;
  dash)      exec ssh -t "$HOST" 'cd /opt/rh-copybot && .venv/bin/python dash.py' ;;
  status)    exec ssh "$HOST" 'cd /opt/rh-copybot && .venv/bin/python bot.py status' ;;
  stats)     exec ssh "$HOST" 'cd /opt/rh-copybot && .venv/bin/python stats.py' ;;
  restart)   exec ssh "$HOST" 'systemctl restart rh-copybot rh-copybot-paper && sleep 3 && systemctl is-active rh-copybot rh-copybot-paper' ;;
  push)      ./deploy/push.sh "$HOST" && ssh "$HOST" 'systemctl restart rh-copybot rh-copybot-paper && sleep 3 && systemctl is-active rh-copybot rh-copybot-paper' ;;
  sell)      exec ssh -t "$HOST" "cd /opt/rh-copybot && .venv/bin/python bot.py sell ${2:?symbol} ${3:-100}" ;;
  adopt)     exec ssh "$HOST" "cd /opt/rh-copybot && .venv/bin/python bot.py adopt ${2:?token} ${3:?usd} ${4:-}" ;;
  *) sed -n 2,9p "$0" ;;
esac
