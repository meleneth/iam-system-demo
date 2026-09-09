#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
stack="${1:-prod}"
action="${2:-}"
case "$stack" in dev|test|prod) ;; *) echo 'Expected stack: dev, test, or prod' >&2; exit 2 ;; esac
case "$action" in start|stop) ;; *) echo 'Usage: ./seed_workers.sh [prod|dev|test] start|stop' >&2; exit 2 ;; esac
if [[ "$stack" == prod && "$action" == start ]]; then
  ruby scripts/check_production_config.rb
fi
config="$(./dc_"$stack" config --format json)"
worker_names="$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("services").keys.grep(/-create-service-worker-/).sort' <<<"$config")"
[[ -n "$worker_names" ]] || { echo 'No seed workers found' >&2; exit 1; }
mapfile -t workers <<<"$worker_names"
if [[ "$action" == start ]]; then
  ./dc_"$stack" up -d "${workers[@]}"
else
  ./dc_"$stack" stop "${workers[@]}"
fi
