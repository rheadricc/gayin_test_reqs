-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Output: Heavy watcher payment method distribution
-- Logic:
--   - cohort window shifted back by 90 days
--   - first meaningful watch defines cohort entry
--   - watcher segment based on first 30-day watch time percentiles
--   - Heavy = top 30%
--   - daily watch outliers above 24h are excluded from segmentation
--   - payment distribution is shown by payment_option + currency

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

cohort_window AS (
  SELECT
    DATE_SUB(ds_start, INTERVAL 90 DAY) AS cohort_start,
    DATE_SUB(ds_end,   INTERVAL 90 DAY) AS cohort_end
  FROM params
),

contents AS (
  SELECT
    CAST(video_id AS STRING) AS video_id,
    TRIM(SPLIT(ANY_VALUE(genres), ',')[SAFE_OFFSET(0)]) AS genre
  FROM `microgain-9f959.Backoffice_metadata.ContentMetaData`
  WHERE video_id IS NOT NULL
  GROUP BY video_id
),

all_stream AS (
  SELECT
    CAST(user_id AS STRING) AS user_id,
    CAST(video_id AS STRING) AS video_id,
    Datetime_Ist,
    event_date,
    COALESCE(CAST(watch_time_second AS FLOAT64), 0) AS watch_time_second
  FROM `microgain-9f959.looker_report.content_report_streaming_V2`
  WHERE user_id IS NOT NULL
    AND video_id IS NOT NULL
    AND Datetime_Ist IS NOT NULL
),

stream_with_genre AS (
  SELECT
    s.user_id,
    s.video_id,
    s.Datetime_Ist,
    s.event_date,
    s.watch_time_second,
    c.genre
  FROM all_stream s
  JOIN contents c
    ON TRIM(s.video_id) = TRIM(c.video_id)
  WHERE c.genre IS NOT NULL
    AND TRIM(c.genre) != ''
),

first_valid_watch AS (
  SELECT
    user_id,
    event_date AS first_watch_date
  FROM (
    SELECT
      s.*,
      ROW_NUMBER() OVER (
        PARTITION BY user_id
        ORDER BY Datetime_Ist ASC, video_id ASC
      ) AS rn
    FROM stream_with_genre s
  )
  WHERE rn = 1
),

cohort AS (
  SELECT
    f.user_id,
    f.first_watch_date
  FROM first_valid_watch f
  CROSS JOIN cohort_window w
  WHERE f.first_watch_date BETWEEN w.cohort_start AND w.cohort_end
),

first_30d_user_day_watch AS (
  SELECT
    c.user_id,
    s.event_date,
    SUM(COALESCE(s.watch_time_second, 0)) / 60.0 AS daily_watch_minutes
  FROM cohort c
  JOIN all_stream s
    ON s.user_id = c.user_id
   AND s.watch_time_second > 0
   AND s.event_date BETWEEN c.first_watch_date
                        AND DATE_ADD(c.first_watch_date, INTERVAL 30 DAY)
  GROUP BY c.user_id, s.event_date
),

first_30d_watch_time AS (
  SELECT
    user_id,
    SUM(daily_watch_minutes) AS watch_minutes_30d
  FROM first_30d_user_day_watch
  WHERE daily_watch_minutes <= 1440
  GROUP BY user_id
),

percentile_bounds AS (
  SELECT
    APPROX_QUANTILES(watch_minutes_30d, 100)[OFFSET(30)] AS p30_watch_minutes,
    APPROX_QUANTILES(watch_minutes_30d, 100)[OFFSET(70)] AS p70_watch_minutes
  FROM first_30d_watch_time
),

watcher_segment AS (
  SELECT
    w.user_id,
    w.watch_minutes_30d,
    CASE
      WHEN w.watch_minutes_30d <= b.p30_watch_minutes THEN 'Light'
      WHEN w.watch_minutes_30d >= b.p70_watch_minutes THEN 'Heavy'
      ELSE 'Middle'
    END AS watcher_type
  FROM first_30d_watch_time w
  CROSS JOIN percentile_bounds b
),

heavy_users AS (
  SELECT DISTINCT
    user_id
  FROM watcher_segment
  WHERE watcher_type = 'Heavy'
),

payment_option_config AS (
  SELECT 'APP_STORE'      AS payment_option, 0.30 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'PLAY_STORE'     AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'MOBILE_PAYMENT' AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'CRAFTGATE'      AS payment_option, 0.00 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'IYZICO'         AS payment_option, 0.03 AS commission_rate, 0.20 AS tax_rate
),

heavy_payments AS (
  SELECT
    CAST(s.user_id AS STRING) AS user_id,
    s.payment_option AS payment_option,
    s.currency AS currency,
    DATE(s.created_at) AS payment_date,
    CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64) AS amount_minor
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  JOIN heavy_users h
    ON CAST(s.user_id AS STRING) = h.user_id
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND s.payment_option != 'PREPAID'
),

base AS (
  SELECT
    p.payment_option AS payment_option,
    p.currency AS currency,
    COUNT(*) AS payment_count,
    COUNT(DISTINCT p.user_id) AS user_count,
    SUM(p.amount_minor) / 100.0 AS gross_amount,
    SUM(
      SAFE_DIVIDE(p.amount_minor, 100.0)
      * (1.0 - COALESCE(c.commission_rate, 0.00))
      * (1.0 - COALESCE(c.tax_rate, 0.20))
    ) AS net_amount_after_commission_tax
  FROM heavy_payments p
  LEFT JOIN payment_option_config c
    ON p.payment_option = c.payment_option
  GROUP BY
    p.payment_option,
    p.currency
),

final AS (
  SELECT
    payment_option,
    currency,
    payment_count,
    user_count,
    gross_amount,
    net_amount_after_commission_tax,
    SAFE_DIVIDE(user_count, SUM(user_count) OVER ()) AS user_share_pct,
    SAFE_DIVIDE(payment_count, SUM(payment_count) OVER ()) AS payment_share_pct
  FROM base
)

SELECT
  payment_option,
  currency,
  payment_count,
  user_count,
  gross_amount,
  net_amount_after_commission_tax,
  user_share_pct,
  payment_share_pct
FROM final
ORDER BY user_count DESC, payment_count DESC;