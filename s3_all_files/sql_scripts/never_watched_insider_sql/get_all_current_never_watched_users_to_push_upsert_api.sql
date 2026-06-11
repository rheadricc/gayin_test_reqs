-- Haftalık upsert için: data_interval_start → data_interval_end
WITH win AS (
  SELECT
    TIMESTAMP('{{ data_interval_start }}') AS start_ts_utc,
    TIMESTAMP('{{ data_interval_end }}')   AS end_ts_utc
)
SELECT
  user_id as uuid,
  email_address,
  status as watching_status,
  is_email_permitted as isEmailPermitted
FROM `microgain-9f959.gain_model_prod.never_watched_scd`, win
WHERE is_current = TRUE
  AND updated_at >= win.start_ts_utc
  AND updated_at <  win.end_ts_utc;
