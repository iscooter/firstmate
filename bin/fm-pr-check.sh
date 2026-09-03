#!/usr/bin/env bash
# Record a PR-ready task: resolve the pull request live on its forge, store the
# validated canonical pr=<url> and the forge's exact pr_head=<sha> when
# available, then atomically arm a static merge poll. A URL the forge does not
# resolve is refused, never recorded, so no downstream reader can inherit an
# invented pull request as this task's recorded truth.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# The forge is the only authority on whether this pull request exists, and
# nothing downstream can tell an invented URL from a real one once pr= is
# recorded: metadata is exactly what later reads as the task's PR truth. So the
# URL is resolved LIVE here and a URL the forge does not resolve is refused
# rather than recorded, which is what stops an owner/repository assembled from
# memory - a plausible 404 - from becoming a recorded fact. Each provider is
# resolved through the same CLI and the same addressing its merge poll uses
# (bin/fm-pr-poll.sh), so registration and polling can never disagree about
# which project they are watching.

# gh addresses the pull request by the URL itself and reports back the
# canonical URL it resolved. Returns 0 when that is this exact URL, 2 when gh
# resolved a DIFFERENT canonical URL - a concrete contradiction, so a project
# that merely redirects cannot be recorded under the name that was typed - and
# 1 when gh is absent or its read failed, which is the only case a second
# reader may still answer.
FM_PR_CHECK_RESOLVED=
github_resolves_url_with_gh() {
  local resolved
  FM_PR_CHECK_RESOLVED=
  command -v gh >/dev/null 2>&1 || return 1
  resolved=$(gh pr view "$URL" --json url -q .url 2>/dev/null) || return 1
  [ -n "$resolved" ] || return 1
  [ "$resolved" = "$URL" ] && return 0
  FM_PR_CHECK_RESOLVED=$resolved
  return 2
}

# The same fallback bin/fm-pr-merge.sh uses when gh cannot answer, reading the
# one field that tool is already relied on for. It addresses the pull request by
# the owner/repository and number the stored URL reconstructs from, so a
# resolved view is a resolution of this exact URL.
github_resolves_url_with_gh_axi() {
  local output
  command -v gh-axi >/dev/null 2>&1 || return 1
  output=$(gh-axi pr view "$NUMBER" --repo "$PROJECT_PATH" 2>/dev/null) || return 1
  printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { exit !(count == 1 && value != "") }
  '
}

resolve_or_refuse() {
  local raw rc=0
  case "$PROVIDER" in
    github)
      if ! command -v gh >/dev/null 2>&1 && ! command -v gh-axi >/dev/null 2>&1; then
        echo "error: recording a GitHub pull request requires gh or gh-axi on PATH" >&2
        return 1
      fi
      github_resolves_url_with_gh || rc=$?
      case "$rc" in
        0) return 0 ;;
        2)
          echo "error: refusing to record $URL because GitHub resolves it as $FM_PR_CHECK_RESOLVED; record the URL the forge itself reports" >&2
          return 1
          ;;
      esac
      github_resolves_url_with_gh_axi && return 0
      echo "error: refusing to record $URL because GitHub did not resolve it; check the owner and repository against the worker's own report" >&2
      return 1
      ;;
    gitlab)
      # glab cannot take a merge request URL, so the merge request is addressed
      # by the same validated components the stored URL reconstructs from, with
      # the instance named explicitly rather than left to glab's own default.
      raw=$(GITLAB_HOST="$HOST" glab mr view "$NUMBER" \
        -R "https://$HOST/$PROJECT_PATH" 2>/dev/null) || {
        echo "error: refusing to record $URL because GitLab did not resolve it; check the project path against the worker's own report" >&2
        return 1
      }
      printf '%s\n' "$raw" | grep -q '^state:' || {
        echo "error: refusing to record $URL because glab returned no merge request state for it" >&2
        return 1
      }
      ;;
    *) return 1 ;;
  esac
}
resolve_or_refuse || exit 1

STATUS_URLS=$(fm_pr_task_status_recorded_urls "$STATE" "$ID") || {
  echo "error: task status is unavailable" >&2
  exit 1
}
if [ -n "$STATUS_URLS" ]; then
  case "
$STATUS_URLS
" in
    *"
$URL
"*) ;;
    *)
      echo "error: refusing to record $URL because the task status reports another forge URL; use the URL the worker itself reported" >&2
      exit 1
      ;;
  esac
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/fm-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'armed: state/%s.check.sh\n' "$ID"
