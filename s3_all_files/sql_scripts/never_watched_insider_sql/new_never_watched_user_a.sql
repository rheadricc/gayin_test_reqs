-- 1) Mevcut current ≠ NEVER ise kapat
MERGE `microgain-9f959.gain_model_prod.never_watched_scd` T
USING (
  SELECT user_id, email_address, is_email_permitted, snapshot_ts
  FROM `microgain-9f959.insider.never_watched_paid_sparse_snapshot`
) S
ON T.user_id = S.user_id AND T.is_current = TRUE AND T.status <> 'never_watched'
WHEN MATCHED THEN
  UPDATE SET
    T.effective_end_ts = S.snapshot_ts,
    T.is_current       = FALSE,
    T.updated_at       = CURRENT_TIMESTAMP(),
    T.updated_by       = 'mwaa_weekly_never';

-- 2) Current kaydı yoksa NEVER aç
INSERT INTO `microgain-9f959.gain_model_prod.never_watched_scd` (
  user_id, email_address, is_email_permitted, status,
  effective_start_ts, effective_end_ts, is_current,
  last_seen_snapshot_ts, last_snapshot_week,
  updated_at, updated_by, etl_date
)
SELECT
  S.user_id, S.email_address, S.is_email_permitted, 'never_watched',
  S.snapshot_ts, TIMESTAMP '9999-12-31 23:59:59', TRUE,
  S.snapshot_ts, FORMAT_TIMESTAMP('%G-%V', S.snapshot_ts),
  CURRENT_TIMESTAMP(), 'mwaa_weekly_never', CURRENT_DATE()
FROM `microgain-9f959.insider.never_watched_paid_sparse_snapshot` S
LEFT JOIN `microgain-9f959.gain_model_prod.never_watched_scd` T
  ON T.user_id = S.user_id AND T.is_current = TRUE
WHERE T.user_id IS NULL;
