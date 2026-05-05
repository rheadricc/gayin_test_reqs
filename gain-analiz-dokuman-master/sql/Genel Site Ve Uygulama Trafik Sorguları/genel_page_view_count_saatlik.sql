WITH
p AS (SELECT 'Europe/Istanbul' AS tz),
win AS (
  SELECT
    DATETIME '2025-09-13 17:00:00' AS start_dt_tr,
    DATETIME '2025-09-14 00:00:00' AS end_dt_tr,
    tz
  FROM p
),
base AS (
  SELECT
    DATETIME(TIMESTAMP_MICROS(event_timestamp), p.tz) AS event_dt_tr,
    DATETIME_TRUNC(DATETIME(TIMESTAMP_MICROS(event_timestamp), p.tz), HOUR) AS hour_tr,
    COALESCE(CAST(user_id AS STRING), user_pseudo_id) AS user_key
  FROM `microgain-9f959.analytics_236816681.events_*`, p
  WHERE _TABLE_SUFFIX = '20250913'
    AND event_name = 'page_view'
    AND (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location')
        IN ('https://www.gain.tv/', 'https://www.gain.tv/home')
)
SELECT
  b.hour_tr,
  COUNT(DISTINCT b.user_key) AS homepage_users
FROM base b
CROSS JOIN win w
WHERE b.event_dt_tr >= w.start_dt_tr
  AND b.event_dt_tr <  w.end_dt_tr
GROUP BY b.hour_tr
ORDER BY b.hour_tr;
