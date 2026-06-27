#!/bin/zsh

# Meta Ads + Google Ads backfill runner.
#
# Usage:
#   ./Random_Test_Scripts/run_ads_backfill_local.sh start
#   ./Random_Test_Scripts/run_ads_backfill_local.sh status
#   ./Random_Test_Scripts/run_ads_backfill_local.sh stop
#
# `start` runs in the current terminal. Closing the terminal or pressing Ctrl+C
# stops the worker. This script does not launch a hidden/background process.

set -u

export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"

# In zsh, $0 changes to the current function name while a function is running.
# Capture the script path once at top-level so start/status/help always refer to
# this file instead of names such as "start_detached".
SELF_PATH="${0:A}"
SCRIPT_DIR="${SELF_PATH:h}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ACCELERATOR="${SCRIPT_DIR}/accelerate_ads_backfill.sh"
MERGE_SQL="${REPO_ROOT}/looker_sqls/BC_ADS_DAILY_SPEND_UNIFIED_BACKFILL.sql"
PRODUCTION_SQL="${REPO_ROOT}/looker_sqls/BC_ADS_DAILY_SPEND_UNIFIED_01.sql"

META_CONFIG="projects/454355656294/locations/us/transferConfigs/6a6005c4-0000-2657-9467-240588774a20"
GOOGLE_CONFIG="projects/454355656294/locations/us/transferConfigs/6a46b8c0-0000-28cf-a3ee-14223bc885e2"
UNIFIED_CONFIG="projects/454355656294/locations/us/transferConfigs/6a57263a-0000-2460-9587-b8db38f54a9a"

START_DATE="2025-07-01"
END_DATE="2026-06-23"
EXPECTED_DAYS=358

PID_FILE="/tmp/gain_ads_backfill_local.pid"
LOCK_DIR="/tmp/gain_ads_backfill_local.lock"
LOG_FILE="/tmp/gain_ads_backfill_local.log"
ACCELERATOR_LOG="/tmp/gain_ads_backfill_accelerator.log"
FINAL_RESULT="/tmp/gain_ads_backfill_final_verification.json"
ACCELERATOR_PID=""

log_message() {
  local message="$*"
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S') ${message}" >> "$LOG_FILE"
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    print -u2 -- "Eksik komut: ${command_name}"
    return 1
  fi
}

preflight() {
  local failed=0
  local command_name

  for command_name in bq gcloud jq curl grep pgrep pkill; do
    require_command "$command_name" || failed=1
  done

  [[ -f "$ACCELERATOR" ]] || {
    print -u2 -- "Bulunamadı: ${ACCELERATOR}"
    failed=1
  }
  [[ -f "$MERGE_SQL" ]] || {
    print -u2 -- "Bulunamadı: ${MERGE_SQL}"
    failed=1
  }
  [[ -f "$PRODUCTION_SQL" ]] || {
    print -u2 -- "Bulunamadı: ${PRODUCTION_SQL}"
    failed=1
  }

  if [[ "$failed" -ne 0 ]]; then
    return 1
  fi

  if ! gcloud auth print-access-token >/dev/null 2>&1; then
    print -u2 -- "Google Cloud oturumu açık değil. Önce çalıştır:"
    print -u2 -- "  gcloud auth login"
    return 1
  fi
}

pid_is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(<"$PID_FILE")"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

cleanup() {
  if [[ -n "${ACCELERATOR_PID:-}" ]] &&
     kill -0 "$ACCELERATOR_PID" >/dev/null 2>&1; then
    kill -TERM "$ACCELERATOR_PID" >/dev/null 2>&1 || true
    wait "$ACCELERATOR_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$PID_FILE"
  rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
}

successful_dates_file() {
  local config="$1"
  local output_file="$2"
  local runs_file="${output_file}.runs.json"

  bq ls \
    --format=prettyjson \
    --transfer_run \
    --max_results=1000 \
    "$config" > "$runs_file"

  jq -r \
    --arg start_date "$START_DATE" \
    --arg end_date "$END_DATE" \
    '.[] |
      select(.state == "SUCCEEDED") |
      .runTime[0:10] |
      select(. >= $start_date and . <= $end_date)' \
    "$runs_file" |
    sort -u > "$output_file"
}

verify_transfer_coverage() {
  local meta_dates="/tmp/gain_meta_successful_dates.txt"
  local google_dates="/tmp/gain_google_successful_dates.txt"
  local meta_count
  local google_count

  successful_dates_file "$META_CONFIG" "$meta_dates"
  successful_dates_file "$GOOGLE_CONFIG" "$google_dates"

  # The accelerator records direct successes before deleting old future
  # placeholders. Include these state files in case listTransferRuns has a
  # short propagation delay.
  if [[ -f /tmp/gain_meta_accelerator_completed_dates ]]; then
    cat /tmp/gain_meta_accelerator_completed_dates >> "$meta_dates"
    sort -u "$meta_dates" -o "$meta_dates"
  fi
  if [[ -f /tmp/gain_google_accelerator_completed_dates ]]; then
    cat /tmp/gain_google_accelerator_completed_dates >> "$google_dates"
    sort -u "$google_dates" -o "$google_dates"
  fi

  meta_count="$(wc -l < "$meta_dates" | tr -d ' ')"
  google_count="$(wc -l < "$google_dates" | tr -d ' ')"

  log_message "Transfer coverage: meta ${meta_count}/${EXPECTED_DAYS}, google ${google_count}/${EXPECTED_DAYS}"

  [[ "$meta_count" -eq "$EXPECTED_DAYS" &&
     "$google_count" -eq "$EXPECTED_DAYS" ]]
}

run_merge() {
  log_message "ads_daily_spend güvenli MERGE başlıyor"
  bq query \
    --quiet \
    --location=us \
    --use_legacy_sql=false \
    < "$MERGE_SQL" >> "$LOG_FILE" 2>&1
  log_message "ads_daily_spend MERGE tamamlandı"
}

write_final_verification() {
  local table_result="/tmp/gain_ads_backfill_table_verification.json"
  local meta_dates="/tmp/gain_meta_successful_dates.txt"
  local google_dates="/tmp/gain_google_successful_dates.txt"
  local meta_count
  local google_count

  meta_count="$(wc -l < "$meta_dates" | tr -d ' ')"
  google_count="$(wc -l < "$google_dates" | tr -d ' ')"

  bq query \
    --quiet \
    --location=us \
    --use_legacy_sql=false \
    --format=prettyjson \
    '
    WITH raw_keys AS (
      SELECT
        segments_date AS day,
        "google" AS channel,
        CAST(customer_id AS STRING) AS account_id,
        CAST(campaign_id AS STRING) AS campaign_id,
        "p_ads_CampaignBasicStats_6861382209" AS source_table,
        SUM(metrics_cost_micros) / 1000000.0 AS spend_tl
      FROM `microgain-9f959.bc_googleads_spend_raw.p_ads_CampaignBasicStats_6861382209`
      WHERE segments_date BETWEEN DATE "2025-07-01" AND DATE "2026-06-23"
      GROUP BY day, channel, account_id, campaign_id, source_table

      UNION ALL

      SELECT
        DateStart,
        "meta",
        CAST(AdAccountId AS STRING),
        CAST(CampaignId AS STRING),
        "AdInsights",
        SUM(CAST(Spend AS FLOAT64))
      FROM `microgain-9f959.bc_meta_spend_raw.AdInsights`
      WHERE DateStart BETWEEN DATE "2025-07-01" AND DATE "2026-06-23"
        AND UPPER(AccountCurrency) = "TRY"
      GROUP BY 1, 2, 3, 4, 5
    ),

    target_keys AS (
      SELECT
        day,
        channel,
        account_id,
        campaign_id,
        source_table,
        spend_tl
      FROM `microgain-9f959.bc_marketing_marts.ads_daily_spend`
      WHERE day BETWEEN DATE "2025-07-01" AND DATE "2026-06-23"
    ),

    target_duplicates AS (
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
        WHERE day BETWEEN DATE "2025-07-01" AND DATE "2026-06-23"
        GROUP BY day, channel, account_id, campaign_id, source_table
        HAVING COUNT(*) > 1
      )
    ),

    comparison AS (
      SELECT
        r.channel,
        COUNT(*) AS raw_key_count,
        COUNTIF(t.day IS NULL) AS raw_keys_missing_in_target,
        COUNTIF(
          t.day IS NOT NULL
          AND ABS(r.spend_tl - t.spend_tl) > 0.000001
        ) AS spend_mismatches,
        COUNT(DISTINCT r.day) AS raw_days_with_rows,
        MIN(r.day) AS raw_min_day,
        MAX(r.day) AS raw_max_day
      FROM raw_keys r
      LEFT JOIN target_keys t
        ON r.day = t.day
       AND r.channel = t.channel
       AND COALESCE(r.account_id, "") = COALESCE(t.account_id, "")
       AND COALESCE(r.campaign_id, "") = COALESCE(t.campaign_id, "")
       AND COALESCE(r.source_table, "") = COALESCE(t.source_table, "")
      GROUP BY r.channel
    )

    SELECT
      c.*,
      d.duplicate_key_groups,
      d.excess_rows
    FROM comparison c
    CROSS JOIN target_duplicates d
    ORDER BY c.channel
    ' > "$table_result"

  jq -n \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson expected_days "$EXPECTED_DAYS" \
    --argjson meta_succeeded "$meta_count" \
    --argjson google_succeeded "$google_count" \
    --slurpfile table_verification "$table_result" \
    '{
      generated_at: $generated_at,
      period: {
        start: "2025-07-01",
        end: "2026-06-23"
      },
      transfer_coverage: {
        meta: {
          expected_days: $expected_days,
          succeeded_days: $meta_succeeded,
          missing_transfer_days: ($expected_days - $meta_succeeded)
        },
        google: {
          expected_days: $expected_days,
          succeeded_days: $google_succeeded,
          missing_transfer_days: ($expected_days - $google_succeeded)
        }
      },
      note: "A successful transfer date can have zero raw rows when there was no ad spend. Transfer coverage is the authoritative date-gap check.",
      table_verification: $table_verification[0]
    }' > "$FINAL_RESULT"

  rm -f "$table_result"
}

restore_production_schedule() {
  local production_params
  production_params="$(jq -Rs '{query: .}' "$PRODUCTION_SQL")"

  bq update \
    --transfer_config \
    --params="$production_params" \
    "$UNIFIED_CONFIG" >> "$LOG_FILE" 2>&1

  log_message "Günlük unified sorgu rolling 35 günlük üretim penceresine döndürüldü"
}

run_job() {
  if ! mkdir "$LOCK_DIR" >/dev/null 2>&1; then
    print -u2 -- "Başka bir local backfill worker çalışıyor olabilir: ${LOCK_DIR}"
    return 1
  fi

  print -r -- "$$" > "$PID_FILE"
  trap cleanup EXIT INT TERM

  preflight
  log_message "Backfill başladı: ${START_DATE} - ${END_DATE}"

  "$ACCELERATOR" &
  ACCELERATOR_PID=$!
  wait "$ACCELERATOR_PID"
  accelerator_status=$?
  ACCELERATOR_PID=""

  if [[ "$accelerator_status" -ne 0 ]]; then
    log_message "Transfer accelerator hata koduyla durdu: ${accelerator_status}"
    return "$accelerator_status"
  fi

  if ! verify_transfer_coverage; then
    log_message "Transfer coverage tamamlanmadı; final MERGE çalıştırılmadı"
    return 1
  fi

  run_merge
  write_final_verification

  if jq -e '
    .transfer_coverage.meta.missing_transfer_days == 0
    and .transfer_coverage.google.missing_transfer_days == 0
    and all(.table_verification[];
      .raw_keys_missing_in_target == "0"
      and .spend_mismatches == "0"
      and .duplicate_key_groups == "0"
      and .excess_rows == "0"
    )
  ' "$FINAL_RESULT" >/dev/null; then
    restore_production_schedule
    log_message "BACKFILL BAŞARILI. Rapor: ${FINAL_RESULT}"
    return 0
  fi

  log_message "BACKFILL BİTTİ AMA KALİTE KONTROLÜ BAŞARISIZ. Rapor: ${FINAL_RESULT}"
  return 1
}

show_status() {
  if pid_is_running; then
    print -r -- "Durum: ÇALIŞIYOR (PID $(<"$PID_FILE"))"
  else
    print -r -- "Durum: ÇALIŞMIYOR"
  fi

  if [[ -f "$LOG_FILE" ]]; then
    print -r -- ""
    print -r -- "Son loglar:"
    tail -20 "$LOG_FILE"
  fi

  if [[ -f "$ACCELERATOR_LOG" ]]; then
    print -r -- ""
    print -r -- "Transfer ilerlemesi:"
    tail -12 "$ACCELERATOR_LOG"
  fi

  if [[ -f "$FINAL_RESULT" ]]; then
    print -r -- ""
    print -r -- "Final rapor:"
    jq . "$FINAL_RESULT"
  fi
}

start_foreground() {
  preflight

  if pid_is_running; then
    print -r -- "Backfill zaten çalışıyor. PID: $(<"$PID_FILE")"
    return 0
  fi

  local legacy_workers
  legacy_workers="$(
    pgrep -f \
      'Random_Test_Scripts/(accelerate_ads_backfill|queue_ads_backfill_remaining)\.sh' \
      2>/dev/null || true
  )"
  if [[ -n "$legacy_workers" ]]; then
    print -u2 -- "Eski backfill worker hâlâ çalışıyor: ${legacy_workers//$'\n'/, }"
    print -u2 -- "Önce yalnız bu iki eski worker'ı kapat:"
    print -u2 -- "  pkill -f 'Random_Test_Scripts/(accelerate_ads_backfill|queue_ads_backfill_remaining)\\.sh'"
    print -u2 -- "Sonra tekrar:"
    print -u2 -- "  ${SELF_PATH} start"
    return 1
  fi

  if [[ -d "$LOCK_DIR" ]]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || {
      print -u2 -- "Stale olmayan lock bulundu: ${LOCK_DIR}"
      return 1
    }
  fi

  print -r -- "Backfill bu terminalde çalışacak."
  print -r -- "Durdurmak için Ctrl+C kullanabilirsin."
  print -r -- "Log: ${LOG_FILE}"
  print -r -- ""
  run_job
}

stop_job() {
  if ! pid_is_running; then
    print -r -- "Çalışan local backfill worker bulunamadı."
    rm -f "$PID_FILE"
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
    return 0
  fi

  local pid
  pid="$(<"$PID_FILE")"
  kill -TERM "$pid"
  print -r -- "Durdurma sinyali gönderildi. PID: ${pid}"
}

case "${1:-status}" in
  start)
    start_foreground
    ;;
  status)
    show_status
    ;;
  stop)
    stop_job
    ;;
  *)
    print -u2 -- "Kullanım: ${SELF_PATH} {start|status|stop}"
    exit 2
    ;;
esac
