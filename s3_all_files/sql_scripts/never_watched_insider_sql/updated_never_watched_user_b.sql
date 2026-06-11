-- Parametreler
DECLARE p_lookback_days INT64 DEFAULT 30;
DECLARE p_grace_days    INT64 DEFAULT 3;
DECLARE p_etl_date DATE DEFAULT CURRENT_DATE();

-- 1) Değişenleri temp tabloya yaz
CREATE TEMP TABLE to_watched AS
WITH prev_never AS (
  SELECT user_id
  FROM `microgain-9f959.gain_model_prod.never_watched_scd`
  WHERE is_current = TRUE AND status = 'never_watched'
),
cur_never AS (
  SELECT user_id
  FROM `microgain-9f959.insider.never_watched_paid_sparse_snapshot`
),
windows AS (
  SELECT DATE_SUB(CURRENT_DATE(), INTERVAL (p_lookback_days + p_grace_days) DAY) AS since_date
),
active_watchers AS (
  SELECT DISTINCT user_id
  FROM `microgain-9f959.looker_report.content_report_streaming_V2`, windows
  WHERE event_date >= (SELECT since_date FROM windows)
),
premium_still AS (
  SELECT DISTINCT user_id
  FROM `test_dataset.guncel_premium_users`
)
SELECT
  p.user_id,
  CURRENT_TIMESTAMP() AS change_ts
FROM prev_never p
LEFT JOIN cur_never c USING (user_id)
WHERE c.user_id IS NULL
  AND EXISTS (SELECT 1 FROM active_watchers aw WHERE aw.user_id = p.user_id)
  AND EXISTS (SELECT 1 FROM premium_still ps WHERE ps.user_id = p.user_id);

-- 2) Eski NEVER current'ı kapat
MERGE `microgain-9f959.gain_model_prod.never_watched_scd` T
USING to_watched S
ON T.user_id = S.user_id AND T.is_current = TRUE AND T.status = 'never_watched'
WHEN MATCHED THEN
  UPDATE SET
    T.effective_end_ts = S.change_ts,
    T.is_current       = FALSE,
    T.updated_at       = CURRENT_TIMESTAMP(),
    T.updated_by       = 'mwaa_scd_sparse';

-- 3) Yeni WATCHED current aç
INSERT INTO `microgain-9f959.gain_model_prod.never_watched_scd` (
  user_id, email_address, is_email_permitted, status,
  effective_start_ts, effective_end_ts, is_current,
  last_seen_snapshot_ts, last_snapshot_week,
  updated_at, updated_by, etl_date
)
SELECT
  w.user_id,
  ANY_VALUE(t.email_address),
  ANY_VALUE(t.is_email_permitted),
  'watched',
  w.change_ts,
  TIMESTAMP '9999-12-31 23:59:59',
  TRUE,
  w.change_ts,
  FORMAT_TIMESTAMP('%G-%V', w.change_ts),
  CURRENT_TIMESTAMP(),
  'mwaa_scd_sparse',
  CURRENT_DATE()
FROM to_watched w
JOIN `microgain-9f959.gain_model_prod.never_watched_scd` t
  ON t.user_id = w.user_id AND t.status = 'never_watched' AND t.is_current = FALSE
WHERE DATE(t.effective_end_ts) = DATE(w.change_ts)
GROUP BY w.user_id, w.change_ts;
