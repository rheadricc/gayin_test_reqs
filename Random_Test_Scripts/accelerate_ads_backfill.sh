#!/bin/zsh

# Accelerates already queued BigQuery Data Transfer backfills by submitting one
# immediate requestedRunTime at a time per connector. Existing scheduled runs
# are left intact; the source connectors overwrite the requested date
# partition, and ads_daily_spend is loaded later with an idempotent MERGE.

set -u

export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"

META_CONFIG="projects/454355656294/locations/us/transferConfigs/6a6005c4-0000-2657-9467-240588774a20"
GOOGLE_CONFIG="projects/454355656294/locations/us/transferConfigs/6a46b8c0-0000-28cf-a3ee-14223bc885e2"

START_DATE="2025-07-01"
END_DATE="2026-06-23"
EXPECTED_DAYS=358
LOG_FILE="/tmp/gain_ads_backfill_accelerator.log"

expected_dates_file="/tmp/gain_ads_expected_dates.txt"

if [[ ! -s "$expected_dates_file" ]]; then
  : > "$expected_dates_file"
  for offset in {0..357}; do
    date -j -v+"${offset}"d -f '%Y-%m-%d' "$START_DATE" '+%Y-%m-%d' \
      >> "$expected_dates_file"
  done
fi

log_message() {
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

write_runs() {
  local config="$1"
  local output_file="$2"

  bq ls \
    --format=prettyjson \
    --transfer_run \
    --max_results=1000 \
    "$config" > "$output_file"
}

successful_count() {
  local runs_file="$1"
  local completed_file="$2"

  {
    jq -r \
      --arg start_date "$START_DATE" \
      --arg end_date "$END_DATE" \
      '.[] |
        select(.state == "SUCCEEDED") |
        .runTime[0:10] |
        select(. >= $start_date and . <= $end_date)' \
      "$runs_file"
    [[ -f "$completed_file" ]] && cat "$completed_file"
  } | sort -u | wc -l | tr -d ' '
}

next_missing_date() {
  local runs_file="$1"
  local completed_file="$2"
  local succeeded_file="${runs_file}.succeeded"

  {
    jq -r \
      --arg start_date "$START_DATE" \
      --arg end_date "$END_DATE" \
      '.[] |
        select(.state == "SUCCEEDED") |
        .runTime[0:10] |
        select(. >= $start_date and . <= $end_date)' \
      "$runs_file"
    [[ -f "$completed_file" ]] && cat "$completed_file"
  } | sort -u > "$succeeded_file"

  comm -23 "$expected_dates_file" "$succeeded_file" | head -1
}

has_running_run() {
  local runs_file="$1"
  jq -e 'any(.[]; .state == "RUNNING")' "$runs_file" >/dev/null
}

wait_for_run() {
  local run_name="$1"
  local run_json
  local state

  while true; do
    if ! run_json="$(
      bq show --format=prettyjson --transfer_run "$run_name" 2>/dev/null
    )"; then
      sleep 30
      continue
    fi

    state="$(print -r -- "$run_json" | jq -r '.state')"
    case "$state" in
      SUCCEEDED)
        return 0
        ;;
      FAILED|CANCELLED)
        return 1
        ;;
      *)
        sleep 30
        ;;
    esac
  done
}

delete_pending_for_date() {
  local config="$1"
  local run_date="$2"
  local runs_file="$3"
  local token
  local pending_names
  local pending_name

  # Deleting the old future-scheduled placeholder exposes the successful
  # immediate run in listTransferRuns. Repeat because multiple attempts for
  # the same runTime can be hidden behind one another.
  for _ in {1..5}; do
    write_runs "$config" "$runs_file" || return 1
    pending_names="$(
      jq -r \
        --arg run_date "$run_date" \
        '.[] |
          select(.runTime[0:10] == $run_date and .state == "PENDING") |
          .name' \
        "$runs_file"
    )"
    [[ -z "$pending_names" ]] && return 0

    token="$(gcloud auth print-access-token)"
    while IFS= read -r pending_name; do
      [[ -z "$pending_name" ]] && continue
      curl -fsS \
        -X DELETE \
        -H "Authorization: Bearer ${token}" \
        "https://bigquerydatatransfer.googleapis.com/v1/${pending_name}" \
        >/dev/null || return 1
    done <<< "$pending_names"
    sleep 3
  done

  return 0
}

accelerate_channel() {
  local channel="$1"
  local config="$2"
  local runs_file="/tmp/gain_${channel}_accelerator_runs.json"
  local completed_file="/tmp/gain_${channel}_accelerator_completed_dates"
  local count
  local run_date
  local request_output
  local run_name

  touch "$completed_file"

  while true; do
    if ! write_runs "$config" "$runs_file"; then
      log_message "${channel}: failed to list transfer runs; retrying"
      sleep 60
      continue
    fi

    count="$(successful_count "$runs_file" "$completed_file")"
    if [[ "$count" -ge "$EXPECTED_DAYS" ]]; then
      log_message "${channel}: complete ${count}/${EXPECTED_DAYS}"
      return 0
    fi

    if has_running_run "$runs_file"; then
      sleep 30
      continue
    fi

    run_date="$(next_missing_date "$runs_file" "$completed_file")"
    if [[ -z "$run_date" ]]; then
      log_message "${channel}: no missing date found at ${count}/${EXPECTED_DAYS}"
      sleep 60
      continue
    fi

    if request_output="$(
      bq --format=prettyjson mk \
        --transfer_run \
        --run_time="${run_date}T00:01:00Z" \
        "$config" \
        2>&1
    )"; then
      run_name="$(
        print -r -- "$request_output" |
          jq -r '
            if type == "array" then
              .[0].name // empty
            else
              .name // empty
            end
          '
      )"
      if [[ -z "$run_name" ]]; then
        log_message "${channel}: ${run_date} started but run name was not returned"
        sleep 30
        continue
      fi

      log_message "${channel}: started immediate run ${run_date} (${count}/${EXPECTED_DAYS})"
      if wait_for_run "$run_name"; then
        print -r -- "$run_date" >> "$completed_file"
        sort -u "$completed_file" -o "$completed_file"
        delete_pending_for_date "$config" "$run_date" "$runs_file" || \
          log_message "${channel}: could not delete old pending run for ${run_date}"
        log_message "${channel}: succeeded immediate run ${run_date}"
      else
        log_message "${channel}: immediate run failed for ${run_date}; will retry"
      fi
      continue
    fi

    if print -r -- "$request_output" | grep -Eq \
      "Maximum allowable runs inflight|Too many transfer runs"; then
      sleep 30
      continue
    fi

    error_summary="$(
      print -r -- "$request_output" |
        tr '\n' ' ' |
        sed -E 's/[[:space:]]+/ /g' |
        cut -c1-500
    )"
    log_message "${channel}: ${run_date} request failed: ${error_summary}"
    sleep 60
  done
}

log_message "accelerator started"

accelerate_channel "meta" "$META_CONFIG" &
meta_pid=$!

accelerate_channel "google" "$GOOGLE_CONFIG" &
google_pid=$!

wait "$meta_pid"
meta_status=$?
wait "$google_pid"
google_status=$?

if [[ "$meta_status" -eq 0 && "$google_status" -eq 0 ]]; then
  log_message "all accelerated transfer dates completed"
  exit 0
fi

log_message "accelerator stopped with meta=${meta_status}, google=${google_status}"
exit 1
