-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Name: BC_HEAVY_PAYMENT_DISTRIBUTION_01
--
-- Current-state companion to BC_WATCHER_LTV_02. Unlike the LTV query, this
-- output intentionally contains only paid subscribers on selected end date/T-1
-- because it shows the CURRENT payment-option distribution of Heavy users.
--
-- Looker donut:
--   Dimension: payment_method_label
--   Metric: user_count

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    LEAST(
      PARSE_DATE('%Y%m%d', @DS_END_DATE),
      DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
    ) AS snapshot_date
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
  SELECT s.*
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
  FROM stream_with_genre
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id
    ORDER BY Datetime_Ist, video_id
  ) = 1
),

current_paid_raw AS (
  SELECT
    CAST(s.user_id AS STRING) AS user_id,
    UPPER(TRIM(s.payment_option)) AS payment_option,
    UPPER(TRIM(s.currency)) AS currency_code,
    s.created_at,
    s.inserted_date,
    DATE(s.created_at) AS created_date,
    DATE(s.valid_until) AS valid_until_date,
    CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS INT64) AS amount_minor,
    SAFE_DIVIDE(
      CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64),
      100.0
    ) AS amount_original
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN params p
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND UPPER(TRIM(s.payment_option)) != 'PREPAID'
    AND UPPER(TRIM(s.status)) IN (
      'ACTIVE', 'CANCELED', 'IN_GRACE', 'ON_HOLD', 'EXPIRED'
    )
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 101
    AND p.snapshot_date BETWEEN DATE(s.created_at) AND DATE(s.valid_until)
),

current_paid AS (
  SELECT
    user_id,
    payment_option,
    currency_code,
    created_date,
    amount_original
  FROM current_paid_raw
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id
    ORDER BY created_at DESC, inserted_date DESC
  ) = 1
),

first_30d_user_day_watch AS (
  SELECT
    p.user_id,
    s.event_date,
    SUM(s.watch_time_second) / 60.0 AS daily_watch_minutes
  FROM current_paid p
  JOIN first_valid_watch f
    ON p.user_id = f.user_id
  JOIN all_stream s
    ON p.user_id = s.user_id
   AND s.watch_time_second > 0
   AND s.event_date BETWEEN f.first_watch_date
                        AND DATE_ADD(f.first_watch_date, INTERVAL 30 DAY)
  GROUP BY p.user_id, s.event_date
),

first_30d_watch AS (
  SELECT
    user_id,
    SUM(daily_watch_minutes) AS watch_minutes_30d,
    MAX(IF(daily_watch_minutes > 1440, 1, 0)) AS has_daily_watch_over_24h
  FROM first_30d_user_day_watch
  GROUP BY user_id
),

eligible_watchers AS (
  SELECT
    user_id,
    watch_minutes_30d
  FROM first_30d_watch
  WHERE watch_minutes_30d >= 1
    AND has_daily_watch_over_24h = 0
),

ranked_watchers AS (
  SELECT
    user_id,
    watch_minutes_30d,
    NTILE(10) OVER (
      ORDER BY watch_minutes_30d, user_id
    ) AS watch_decile
  FROM eligible_watchers
),

heavy_users AS (
  SELECT
    user_id,
    watch_minutes_30d
  FROM ranked_watchers
  WHERE watch_decile >= 8
),

payment_option_config AS (
  SELECT 'APP_STORE'      AS payment_option, 0.30 AS commission_rate UNION ALL
  SELECT 'PLAY_STORE'     AS payment_option, 0.15 AS commission_rate UNION ALL
  SELECT 'MOBILE_PAYMENT' AS payment_option, 0.15 AS commission_rate UNION ALL
  SELECT 'CRAFTGATE'      AS payment_option, 0.00 AS commission_rate UNION ALL
  SELECT 'IYZICO'         AS payment_option, 0.03 AS commission_rate
),

tcmb_rates AS (
  SELECT
    DATE(rate_date) AS rate_date,
    UPPER(currency_code) AS currency_code,
    SAFE_DIVIDE(
      CAST(forex_buying AS FLOAT64),
      NULLIF(CAST(unit AS FLOAT64), 0.0)
    ) AS rate_to_try
  FROM `microgain-9f959.bc_t.tcmb_exchange_rates_raw`
  WHERE currency_code IS NOT NULL
    AND forex_buying IS NOT NULL
    AND unit IS NOT NULL
),

current_paid_converted AS (
  SELECT
    p.user_id,
    p.payment_option,
    p.currency_code,
    p.amount_original,
    CASE
      WHEN p.currency_code = 'TRY' THEN p.amount_original
      ELSE p.amount_original * r.rate_to_try
    END AS amount_gross_tl
  FROM current_paid p
  LEFT JOIN tcmb_rates r
    ON p.currency_code != 'TRY'
   AND r.currency_code = p.currency_code
   AND r.rate_date <= p.created_date
  QUALIFY p.currency_code = 'TRY'
       OR ROW_NUMBER() OVER (
            PARTITION BY p.user_id
            ORDER BY r.rate_date DESC
          ) = 1
),

base AS (
  SELECT
    p.payment_option,
    CASE p.payment_option
      WHEN 'APP_STORE' THEN 'Apple / App Store'
      WHEN 'PLAY_STORE' THEN 'Google / Play Store'
      WHEN 'MOBILE_PAYMENT' THEN 'Payguru / Mobil'
      WHEN 'IYZICO' THEN 'Iyzico'
      WHEN 'CRAFTGATE' THEN 'Kart / Craftgate (Legacy)'
      ELSE p.payment_option
    END AS payment_method_label,
    COUNT(DISTINCT p.user_id) AS user_count,
    AVG(h.watch_minutes_30d) AS avg_watch_minutes_30d,
    SUM(p.amount_gross_tl) AS gross_mrr_tl,
    SUM(
      p.amount_gross_tl
        * (1.0 - COALESCE(c.commission_rate, 0.00))
    ) AS net_mrr_tl
  FROM current_paid_converted p
  JOIN heavy_users h
    ON p.user_id = h.user_id
  LEFT JOIN payment_option_config c
    ON p.payment_option = c.payment_option
  GROUP BY p.payment_option, payment_method_label
)

SELECT
  payment_option,
  payment_method_label,
  user_count,
  user_count AS payment_count,
  avg_watch_minutes_30d,
  gross_mrr_tl,
  net_mrr_tl,
  SAFE_DIVIDE(user_count, SUM(user_count) OVER ()) AS user_share_pct,
  SAFE_DIVIDE(user_count, SUM(user_count) OVER ()) AS payment_share_pct,
  CONCAT(
    payment_method_label,
    ' ',
    CAST(user_count AS STRING),
    ' kullanıcı (',
    CAST(
      ROUND(
        SAFE_DIVIDE(user_count, SUM(user_count) OVER ()) * 100,
        1
      ) AS STRING
    ),
    '%)'
  ) AS donut_label
FROM base
ORDER BY user_count DESC;
