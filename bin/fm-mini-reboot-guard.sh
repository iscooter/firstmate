#!/usr/bin/env bash
# fm-mini-reboot-guard.sh - CLI entry point for the mini self-reboot guard.
#
# Reboots this mini ONLY when a genuine resource-leak/pressure threshold has
# been crossed AND the local fleet is robustly idle. No drain, no admission
# lock, no blocking of new work, no captain-approval-per-reboot step: see
# bin/fm-mini-reboot-lib.sh for the full design rationale and the captain's
# 2026-08-24 retarget decision it implements.
#
# Usage:
#   fm-mini-reboot-guard.sh sample                collect and persist one sample
#   fm-mini-reboot-guard.sh evaluate               print the resource trigger verdict
#   fm-mini-reboot-guard.sh idle-check             print the idle verdict (single read)
#   fm-mini-reboot-guard.sh idle-confirm           print the two-snapshot idle-confirm verdict
#   fm-mini-reboot-guard.sh check                  run one full detect->idle->reboot cycle
#   fm-mini-reboot-guard.sh status                 human-readable current state summary
#
# Intended to be invoked on a recurring schedule (report: every ~5 minutes) by
# an operator-installed launchd job or cron entry. This script does not
# install its own schedule - arming the schedule, config/host-role=mini, and
# config/mini-reboot-helper are all separate, deliberate provisioning steps.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-mini-reboot-lib.sh
. "$SCRIPT_DIR/fm-mini-reboot-lib.sh"

usage() {
  cat <<'EOF'
fm-mini-reboot-guard.sh - mini self-reboot guard: reboots this mini ONLY when
a resource-leak/pressure threshold has been crossed AND the local fleet is
robustly idle. See bin/fm-mini-reboot-lib.sh for the full design.

Usage:
  fm-mini-reboot-guard.sh sample         collect and persist one sample
  fm-mini-reboot-guard.sh evaluate       print the resource trigger verdict
  fm-mini-reboot-guard.sh idle-check     print the idle verdict (single read)
  fm-mini-reboot-guard.sh idle-confirm   print the two-snapshot idle-confirm verdict
  fm-mini-reboot-guard.sh check          run one full detect->idle->reboot cycle
  fm-mini-reboot-guard.sh status         human-readable current state summary
EOF
}

cmd_status() {
  local homes
  echo "host-role: $(fm_mrb_host_is_mini && echo mini || echo "not mini (or unconfigured)")"
  echo "samples recorded: $(fm_mrb_sample_count "$(fm_mrb_samples_file)")"
  echo "--- evaluate ---"
  fm_mrb_evaluate
  echo "--- idle-check-all (single read) ---"
  fm_mrb_idle_check_all
  homes=$(fm_mrb_homes_registry)
  echo "--- registered homes ---"
  if [ -n "$homes" ]; then
    printf '%s\n' "$homes"
  else
    echo "(none - config/mini-reboot-homes absent or empty)"
  fi
  if fm_mrb_reboot_marker_active; then
    echo "--- reboot marker: ACTIVE (attempt in flight) ---"
  fi
}

main() {
  local sub=${1:-}
  case "$sub" in
    sample) fm_mrb_append_sample ;;
    evaluate) fm_mrb_evaluate ;;
    idle-check) fm_mrb_idle_check_all ;;
    idle-confirm) fm_mrb_idle_confirm ;;
    check) fm_mrb_with_lock fm_mrb_check_cycle ;;
    status) cmd_status ;;
    -h|--help|help|"") usage ;;
    *)
      echo "fm-mini-reboot-guard: unknown subcommand: $sub" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
