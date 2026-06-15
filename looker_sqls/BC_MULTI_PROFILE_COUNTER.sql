-- BC_MULTI_PROFILE_COUNTER
-- Multi profile ve kids profile kullanım KPI'ları

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

multi_profile_daily AS (
  SELECT
    run_date AS date,
    run_date,
    MAX(scanned_accounts) AS scanned_accounts,
    MAX(total_profiles) AS total_profiles,
    MAX(avg_profiles_per_account) AS avg_profiles_per_account,
    MAX(multi_profile_users) AS multi_profile_users,
    MAX(single_profile_users) AS single_profile_users,
    MAX(valid_until_from_date) AS valid_until_from_date,
    ANY_VALUE(query_hash) AS query_hash
  FROM `microgain-9f959.bc_t.multi_profile_counter`, params p
  WHERE run_date BETWEEN p.ds_start AND p.ds_end
  GROUP BY run_date
),

kids_snapshot_daily AS (
  SELECT
    DATE(snapshot_ts, "Europe/Istanbul") AS date,
    DATE(snapshot_ts, "Europe/Istanbul") AS snapshot_date,
    snapshot_ts,
    active_total,
    kids_total,
    source,
    run_id
  FROM `microgain-9f959.bc_t.active_subscribers_snapshot`, params p
  WHERE DATE(snapshot_ts, "Europe/Istanbul") BETWEEN p.ds_start AND p.ds_end
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY DATE(snapshot_ts, "Europe/Istanbul")
    ORDER BY snapshot_ts DESC
  ) = 1
),

final AS (
  SELECT
    COALESCE(m.date, k.date) AS date,
    COALESCE(m.run_date, k.date) AS run_date,
    COALESCE(k.snapshot_date, m.date) AS snapshot_date,
    k.snapshot_ts,

    m.valid_until_from_date,
    m.scanned_accounts,
    m.total_profiles,
    m.avg_profiles_per_account,

    m.multi_profile_users,
    SAFE_DIVIDE(m.multi_profile_users, m.scanned_accounts) AS multi_profile_user_rate,
    ROUND(SAFE_DIVIDE(m.multi_profile_users, m.scanned_accounts) * 100, 2) AS multi_profile_user_pct,

    m.single_profile_users,
    SAFE_DIVIDE(m.single_profile_users, m.scanned_accounts) AS single_profile_user_rate,
    ROUND(SAFE_DIVIDE(m.single_profile_users, m.scanned_accounts) * 100, 2) AS single_profile_user_pct,

    k.active_total,
    k.kids_total,
    SAFE_DIVIDE(k.kids_total, m.scanned_accounts) AS kids_profile_user_rate,
    ROUND(SAFE_DIVIDE(k.kids_total, m.scanned_accounts) * 100, 2) AS kids_profile_user_pct,

    m.query_hash,
    k.source AS kids_source,
    k.run_id AS kids_run_id
  FROM multi_profile_daily m
  FULL OUTER JOIN kids_snapshot_daily k
    ON m.date = k.date
)

SELECT *
FROM final
ORDER BY date;