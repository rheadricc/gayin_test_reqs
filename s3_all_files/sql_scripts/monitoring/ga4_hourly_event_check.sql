-- Tek saat kontrolü (bir önceki saat) + %25 margin
WITH params AS (
  SELECT "Europe/Istanbul" AS tz,
         14 AS lookback_days,
         0.25 AS margin
),
target AS (
  SELECT
    DATETIME_SUB(DATETIME(TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), HOUR), tz), INTERVAL 1 HOUR) AS last_hour,
    CURRENT_DATE(tz) AS today,
    DATE_SUB(CURRENT_DATE(tz), INTERVAL 1 DAY) AS yesterday
  FROM params
),

-- last_hour bugünün içindeyse intraday'den çek
cur_intraday AS (
  SELECT
    DATETIME(TIMESTAMP_TRUNC(TIMESTAMP_MICROS(event_timestamp), HOUR), p.tz) AS hour_tr,
    COUNT(*) AS cur_cnt
  FROM `analytics_236816681.events_intraday_*`, params p, target t
  WHERE DATE(t.last_hour) = t.today
    AND _TABLE_SUFFIX = FORMAT_DATE('%Y%m%d', t.today)
    AND DATETIME(TIMESTAMP_TRUNC(TIMESTAMP_MICROS(event_timestamp), HOUR), p.tz) = t.last_hour
  GROUP BY 1
),

-- last_hour dündense günlük tablodan çek
cur_daily AS (
  SELECT
    DATETIME(TIMESTAMP_TRUNC(TIMESTAMP_MICROS(event_timestamp), HOUR), p.tz) AS hour_tr,
    COUNT(*) AS cur_cnt
  FROM `analytics_236816681.events_*`, params p, target t
  WHERE DATE(t.last_hour) = t.yesterday
    AND _TABLE_SUFFIX = FORMAT_DATE('%Y%m%d', t.yesterday)
    AND DATETIME(TIMESTAMP_TRUNC(TIMESTAMP_MICROS(event_timestamp), HOUR), p.tz) = t.last_hour
  GROUP BY 1
),

-- Seçili tek saatlik current
cur AS (
  SELECT * FROM cur_intraday
  UNION ALL
  SELECT * FROM cur_daily
),

-- 🔧 Baseline: aynı HOD için GÜN GÜN sayım al!
hist AS (
  SELECT
    EXTRACT(HOUR FROM DATETIME(TIMESTAMP_MICROS(event_timestamp), p.tz)) AS hod,
    DATE(DATETIME(TIMESTAMP_MICROS(event_timestamp), p.tz)) AS d_ist,
    COUNT(*) AS c
  FROM `analytics_236816681.events_*`, params p
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(p.tz), INTERVAL p.lookback_days DAY))
                          AND FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(p.tz), INTERVAL 1 DAY))
  GROUP BY 1,2
),

base AS (
  SELECT
    hod,
    COUNT(*) AS sample_days,
    MIN(c) AS min_c,
    MAX(c) AS max_c
  FROM hist
  GROUP BY 1
),

scored AS (
  SELECT
    c.hour_tr,
    c.cur_cnt,
    CAST(b.min_c * (1 - params.margin) AS INT64) AS low_band,
    CAST(b.max_c * (1 + params.margin) AS INT64) AS high_band,
    CASE
      WHEN b.sample_days IS NULL OR b.sample_days < 5 THEN 'NO_BASELINE'
      WHEN c.cur_cnt < b.min_c * (1 - params.margin) THEN 'LOW'
      WHEN c.cur_cnt > b.max_c * (1 + params.margin) THEN 'HIGH'
      ELSE 'OK'
    END AS verdict,
    FORMAT('[GA4 Hourly] %s | cnt=%d, band=[%d..%d] -> %s',
           CAST(c.hour_tr AS STRING), c.cur_cnt,
           CAST(b.min_c * (1 - params.margin) AS INT64),
           CAST(b.max_c * (1 + params.margin) AS INT64),
           CASE
             WHEN b.sample_days IS NULL OR b.sample_days < 5 THEN 'NO_BASELINE'
             WHEN c.cur_cnt < b.min_c * (1 - params.margin) THEN 'LOW'
             WHEN c.cur_cnt > b.max_c * (1 + params.margin) THEN 'HIGH'
             ELSE 'OK' END
    ) AS alert_message
  FROM cur c
  LEFT JOIN base b
    ON b.hod = EXTRACT(HOUR FROM c.hour_tr)
  CROSS JOIN params
)

-- Sadece anomali döndür
SELECT hour_tr, cur_cnt, low_band, high_band, verdict, alert_message
FROM scored
WHERE verdict <> 'OK'
ORDER BY hour_tr;
