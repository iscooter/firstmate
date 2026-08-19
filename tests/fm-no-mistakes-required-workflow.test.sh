#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Gate contract of .github/workflows/no-mistakes-required.yml.
#
# The check must exempt automation that cannot use the no-mistakes pipeline
# while still failing an ordinary human PR that lacks the pipeline signature.
# release-please opens its release PRs under a personal access token, so the
# author login reads as the repository owner and the bot exemptions never
# matched; every release needed a manual owner override (kunchenguid/sshhip#293
# is a real release PR that failed this check).
#
# The workflow is copied verbatim into consumer repositories, so the decision
# cannot move into a helper script. It lives in one shell step instead, and this
# test loads the workflow through a real YAML parser and executes that step's
# script with the environment GitHub would supply. It never asserts workflow
# source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"

command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/no-mistakes-required.yml as YAML"

# Exact body of a real release-please release PR (kunchenguid/sshhip#293).
RELEASE_PLEASE_BODY=':robot: I have created a release *beep* *boop*
---


## [1.22.0](https://github.com/kunchenguid/sshhip/compare/sshhip-v1.21.1...sshhip-v1.22.0) (2026-08-18)


### Features

* **ios:** support OSC 8 terminal hyperlinks

---
This PR was generated with [Release Please](https://github.com/googleapis/release-please). See [documentation](https://github.com/googleapis/release-please#release-please).'

NO_MISTAKES_BODY='## Summary

Something useful.

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

HUMAN_BODY='## Summary

Hand-written change with no pipeline behind it.'

TMP_ROOT=$(fm_test_tmproot fm-nm-required-workflow)
GATE="$TMP_ROOT/gate.sh"

extract_gate_script() {
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
job = doc.fetch("jobs").fetch("check")
if job.key?("if")
  raise "job-level `if` gating: the exemption decision must stay in the executable step"
end
steps = job.fetch("steps")
raise "expected exactly one gate step, got #{steps.length}" unless steps.length == 1
print steps.fetch(0).fetch("run")
' "$WORKFLOW"
}

extract_gate_script > "$GATE" \
  || fail "could not load the gate step from $WORKFLOW"
chmod +x "$GATE"

# Runs the gate exactly as the workflow step would, with GitHub's environment.
# Usage: run_gate <author> <head_ref> <head_repo> <body>
run_gate() {
  local author=$1 head_ref=$2 head_repo=$3 body=$4
  GATE_RC=0
  GATE_OUT=$(
    PR_BODY="$body" \
    PR_AUTHOR="$author" \
    PR_NUMBER=4242 \
    PR_HEAD_REF="$head_ref" \
    PR_HEAD_REPO="$head_repo" \
    BASE_REPO=kunchenguid/firstmate \
      bash "$GATE" 2>&1
  ) || GATE_RC=$?
}

test_release_please_pr_is_exempt() {
  run_gate kunchenguid \
    release-please--branches--main--components--sshhip \
    kunchenguid/firstmate \
    "$RELEASE_PLEASE_BODY"
  [ "$GATE_RC" -eq 0 ] \
    || fail "release-please release PR must pass without an owner override"$'\n'"$GATE_OUT"
  assert_contains "$GATE_OUT" "release-please release PR" \
    "gate did not report why the release PR was exempt"
  pass "a release-please release PR passes without the no-mistakes signature"
}

test_legacy_release_please_branch_is_exempt() {
  run_gate kunchenguid \
    release-please/branches/main \
    kunchenguid/firstmate \
    "$RELEASE_PLEASE_BODY"
  [ "$GATE_RC" -eq 0 ] \
    || fail "release-please's slash branch layout must also be exempt"$'\n'"$GATE_OUT"
  pass "the older release-please branch layout is exempt too"
}

test_human_pr_without_signature_still_fails() {
  run_gate kunchenguid feature/manual-edit kunchenguid/firstmate "$HUMAN_BODY"
  [ "$GATE_RC" -ne 0 ] \
    || fail "a human PR without the no-mistakes signature must still fail"$'\n'"$GATE_OUT"
  assert_contains "$GATE_OUT" "not raised through no-mistakes" \
    "failure did not explain the missing pipeline signature"
  pass "a human PR without the pipeline signature still fails"
}

test_human_pr_with_signature_passes() {
  run_gate kunchenguid fm/some-task kunchenguid/firstmate "$NO_MISTAKES_BODY"
  [ "$GATE_RC" -eq 0 ] \
    || fail "a PR carrying the no-mistakes signature must pass"$'\n'"$GATE_OUT"
  pass "a PR carrying the no-mistakes signature passes"
}

test_release_please_branch_name_alone_is_not_enough() {
  # A contributor cannot borrow the exemption by naming a branch after
  # release-please: the generated release body must be there too.
  run_gate kunchenguid \
    release-please--branches--main--components--sneaky \
    kunchenguid/firstmate \
    "$HUMAN_BODY"
  [ "$GATE_RC" -ne 0 ] \
    || fail "a release-please branch name alone must not grant the exemption"$'\n'"$GATE_OUT"
  pass "a release-please-shaped branch name alone does not grant the exemption"
}

test_release_please_body_from_a_fork_is_not_enough() {
  # Only a writer to this repository can push a release-please branch here, so
  # a fork copying the generated body must not be exempt.
  run_gate someone \
    release-please--branches--main--components--sshhip \
    someone/firstmate \
    "$RELEASE_PLEASE_BODY"
  [ "$GATE_RC" -ne 0 ] \
    || fail "a fork copying a release-please body must not be exempt"$'\n'"$GATE_OUT"
  pass "a fork copying a release-please body is not exempt"
}

test_bot_authors_remain_exempt() {
  local author
  for author in 'github-actions[bot]' 'dependabot[bot]'; do
    run_gate "$author" "dependabot/npm_and_yarn/x" kunchenguid/firstmate "$HUMAN_BODY"
    [ "$GATE_RC" -eq 0 ] \
      || fail "$author must stay exempt"$'\n'"$GATE_OUT"
  done
  pass "the existing bot author exemptions still hold"
}

test_release_please_pr_is_exempt
test_legacy_release_please_branch_is_exempt
test_human_pr_without_signature_still_fails
test_human_pr_with_signature_passes
test_release_please_branch_name_alone_is_not_enough
test_release_please_body_from_a_fork_is_not_enough
test_bot_authors_remain_exempt
