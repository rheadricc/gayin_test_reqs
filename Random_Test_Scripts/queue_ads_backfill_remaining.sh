#!/bin/zsh

# Fills newly opened BigQuery Data Transfer run slots without creating
# overlapping date ranges. State and logs stay under /tmp.

set -u

export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

META_CONFIG="projects/454355656294/locations/us/transferConfigs/6a6005c4-0000-2657-9467-240588774a20"
GOOGLE_CONFIG="projects/454355656294/locations/us/transferConfigs/6a46b8c0-0000-28cf-a3ee-14223bc885e2"
UNIFIED_CONFIG="projects/454355656294/locations/us/transferConfigs/6a57263a-0000-2460-9587-b8db38f54a9a"

META_STATE="/tmp/gain_meta_ads_backfill_next_date"
GOOGLE_STATE="/tmp/gain_google_ads_backfill_next_date"
META_REPAIR_STATE="/tmp/gain_meta_ads_backfill_repair_dates"
LOG_FILE="/tmp/gain_ads_backfill_queue.log"
FINAL_RESULT="/tmp/gain_ads_backfill_final_verification.json"
FINAL_TABLE_RESULT="/tmp/gain_ads_backfill_final_table_verification.json"
BACKFILL_SQL="${REPO_ROOT}/looker_sqls/BC_ADS_DAILY_SPEND_UNIFIED_BACKFILL.sql"
PRODUCTION_SQL="${REPO_ROOT}/looker_sqls/BC_ADS_DAILY_SPEND_UNIFIED_01.sql"

META_START="2025-07-01"
META_END="2026-06-23"
GOOGLE_START="2025-07-01"
GOOGLE_END="2026-06-23"

# All dates in the declared ranges have already been submitted. These
# one-past-the-end defaults make a restart safe even if /tmp state is lost.
[[ -f "$META_STATE" ]] || print -r -- "2026-06-24" > "$META_STATE"
[[ -f "$GOOGLE_STATE" ]] || print -r -- "2026-06-24" > "$GOOGLE_STATE"
[[ -f "$META_REPAIR_STATE" ]] || : > "$META_REPAIR_STATE"

next_day() {
  date -j -v+1d -f '%Y-%m-%d' "$1" '+%Y-%m-%d'
}

inclusive_day_count() {
  local start_seconds
  local end_seconds

  start_seconds="$(date -j -f '%Y-%m-%d' "$1" '+%s')"
  end_seconds="$(date -j -f '%Y-%m-%d' "$2" '+%s')"
  print -r -- "$(( (end_seconds - start_seconds) / 86400 + 1 ))"
}

successful_day_count() {
  local config="$1"
  local start_date="$2"
  local end_date="$3"

  bq ls \
    --format=prettyjson \
    --transfer_run \
    --max_results=1000 \
    "$config" |
    jq \
      --arg start_date "$start_date" \
      --arg end_date "$end_date" \
      '[
        .[]
        | select(.state == "SUCCEEDED")
        | .runTime[0:10]
        | select(. >= $start_date and . <= $end_date)
      ] | unique | length'
}

queue_one_day() {
  local channel="$1"
  local config="$2"
  local state_file="$3"
  local end_date="$4"
  local run_date
  local error_file

  run_date="$(<"$state_file")"
  [[ "$run_date" > "$end_date" ]] && return 2

  error_file="/tmp/gain_${channel}_backfill_error.log"

  if bq_output="$(
    bq mk \
      --transfer_run \
      --start_time="${run_date}T00:00:00Z" \
      --end_time="${run_date}T23:59:59Z" \
      "$config" \
      2>&1
  )"; then
    print -r -- "$(date '+%Y-%m-%d %H:%M:%S') queued ${channel} ${run_date}" \
      >> "$LOG_FILE"
    next_day "$run_date" > "$state_file"
    return 0
  fi

  print -r -- "$bq_output" > "$error_file"

  if ! print -r -- "$bq_output" | grep -Eq "Maximum allowable runs inflight"; then
    error_summary="$(
      print -r -- "$bq_output" |
        tr '\n' ' ' |
        sed -E 's/[[:space:]]+/ /g' |
        cut -c1-500
    )"
    print -r -- "$(date '+%Y-%m-%d %H:%M:%S') ${channel} ${run_date} failed: ${error_summary}" \
      >> "$LOG_FILE"
  fi
  rm -f "$error_file"
  return 1
}

queue_next_repair_day() {
  local channel="$1"
  local config="$2"
  local state_file="$3"
  local run_date
  local remaining_file
  local error_file

  run_date="$(head -1 "$state_file")"
  [[ -z "$run_date" ]] && return 2

  remaining_file="${state_file}.remaining"
  error_file="/tmp/gain_${channel}_repair_error.log"

  if bq mk \
    --transfer_run \
    --start_time="${run_date}T00:00:00Z" \
    --end_time="${run_date}T23:59:59Z" \
    "$config" \
    >/dev/null 2>"$error_file"; then
    print -r -- "$(date '+%Y-%m-%d %H:%M:%S') queued ${channel} repair ${run_date}" \
      >> "$LOG_FILE"
    tail -n +2 "$state_file" > "$remaining_file"
    mv "$remaining_file" "$state_file"
    rm -f "$error_file"
    return 0
  fi

  if ! grep -Eq "Maximum allowable runs inflight" "$error_file"; then
    print -r -- "$(date '+%Y-%m-%d %H:%M:%S') ${channel} repair ${run_date} failed: $(head -1 "$error_file")" \
      >> "$LOG_FILE"
  fi
  rm -f "$error_file"
  return 1
}

while true; do
  meta_done=0
  google_done=0

  queue_next_repair_day "meta" "$META_CONFIG" "$META_REPAIR_STATE" || {
    repair_status=$?
    if [[ "$repair_status" -eq 2 ]]; then
      queue_one_day "meta" "$META_CONFIG" "$META_STATE" "$META_END" || {
        [[ $? -eq 2 ]] && meta_done=1
      }
    fi
  }

  queue_one_day "google" "$GOOGLE_CONFIG" "$GOOGLE_STATE" "2025-08-31" || {
    [[ $? -eq 2 ]] && google_done=1
  }

  if [[ "$meta_done" -eq 1 && "$google_done" -eq 1 ]]; then
    print -r -- "$(date '+%Y-%m-%d %H:%M:%S') all remaining transfer runs queued" \
      >> "$LOG_FILE"
    break
  fi

  # Transfer runs generally finish in 2-3 minutes. A one-minute poll keeps
  # newly released inflight slots occupied without creating overlapping dates.
  sleep 60
done

meta_expected="$(inclusive_day_count "$META_START" "$META_END")"
google_expected="$(inclusive_day_count "$GOOGLE_START" "$GOOGLE_END")"

while true; do
  meta_succeeded="$(successful_day_count "$META_CONFIG" "$META_START" "$META_END")"
  google_succeeded="$(successful_day_count "$GOOGLE_CONFIG" "$GOOGLE_START" "$GOOGLE_END")"

  print -r -- \
    "$(date '+%Y-%m-%d %H:%M:%S') completed transfer days: meta ${meta_succeeded}/${meta_expected}, google ${google_succeeded}/${google_expected}" \
    >> "$LOG_FILE"

  if [[ "$meta_succeeded" -eq "$meta_expected" &&
        "$google_succeeded" -eq "$google_expected" ]]; then
    break
  fi

  sleep 900
done

bq query \
  --location=us \
  --use_legacy_sql=false \
  < "$BACKFILL_SQL" \
  >> "$LOG_FILE" 2>&1

bq query \
  --location=us \
  --use_legacy_sql=false \
  --format=prettyjson \
  '
  WITH raw_days AS (
    SELECT
      "google" AS channel,
      segments_date AS day
    FROM `microgain-9f959.bc_googleads_spend_raw.p_ads_CampaignBasicStats_6861382209`
    WHERE segments_date >= DATE "2025-07-01"
    GROUP BY channel, day

    UNION ALL

    SELECT
      "meta" AS channel,
      DateStart AS day
    FROM `microgain-9f959.bc_meta_spend_raw.AdInsights`
    WHERE DateStart >= DATE "2025-07-01"
      AND UPPER(AccountCurrency) = "TRY"
    GROUP BY channel, day
  ),

  target_days AS (
    SELECT channel, day
    FROM `microgain-9f959.bc_marketing_marts.ads_daily_spend`
    WHERE day >= DATE "2025-07-01"
    GROUP BY channel, day
  ),

  duplicate_keys AS (
    SELECT
      COUNT(*) AS duplicate_key_groups,
      COALESCE(SUM(row_count - 1), 0) AS excess_rows
    FROM (
      SELECT
        day,
        channel,
        COALESCE(account_id, "") AS account_id,
        COALESCE(campaign_id, "") AS campaign_id,
        COALESCE(source_table, "") AS source_table,
        COUNT(*) AS row_count
      FROM `microgain-9f959.bc_marketing_marts.ads_daily_spend`
      GROUP BY day, channel, account_id, campaign_id, source_table
      HAVING COUNT(*) > 1
    )
  )

  SELECT
    r.channel,
    COUNT(*) AS raw_loaded_days,
    COUNTIF(t.day IS NULL) AS raw_days_missing_in_target,
    ANY_VALUE(d.duplicate_key_groups) AS duplicate_key_groups,
    ANY_VALUE(d.excess_rows) AS excess_rows
  FROM raw_days AS r
  LEFT JOIN target_days AS t
    USING (channel, day)
  CROSS JOIN duplicate_keys AS d
  GROUP BY r.channel
  ORDER BY r.channel
  ' \
  > "$FINAL_TABLE_RESULT"

jq -n \
  --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson meta_expected "$meta_expected" \
  --argjson meta_succeeded "$meta_succeeded" \
  --argjson google_expected "$google_expected" \
  --argjson google_succeeded "$google_succeeded" \
  --slurpfile table_verification "$FINAL_TABLE_RESULT" \
  '{
    generated_at: $generated_at,
    transfer_coverage: {
      meta: {
        expected_days: $meta_expected,
        succeeded_days: $meta_succeeded,
        missing_transfer_days: ($meta_expected - $meta_succeeded)
      },
      google: {
        expected_days: $google_expected,
        succeeded_days: $google_succeeded,
        missing_transfer_days: ($google_expected - $google_succeeded)
      }
    },
    table_verification: $table_verification[0]
  }' \
  > "$FINAL_RESULT"

rm -f "$FINAL_TABLE_RESULT"

production_params="$(jq -Rs '{query: .}' "$PRODUCTION_SQL")"
if bq update \
  --transfer_config \
  --params="$production_params" \
  "$UNIFIED_CONFIG" \
  >> "$LOG_FILE" 2>&1; then
  print -r -- \
    "$(date '+%Y-%m-%d %H:%M:%S') restored unified scheduled query to rolling 35-day production window" \
    >> "$LOG_FILE"
else
  print -r -- \
    "$(date '+%Y-%m-%d %H:%M:%S') failed to restore unified scheduled query production window" \
    >> "$LOG_FILE"
  exit 1
fi

print -r -- \
  "$(date '+%Y-%m-%d %H:%M:%S') backfill MERGE and final verification completed: ${FINAL_RESULT}" \
  >> "$LOG_FILE"
