-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Name: BC_WATCHER_LTV_02
--
-- Watcher LTV universe:
--   1) The user has made a real payment and has at least three complete
--      observation months after the first payment.
--   2) Churned users are included; current subscription status is not used.
--   3) First 30-day watch behavior is calculated for those mature payers.
--   4) Users with <1 minute total watch or any day >24h are excluded.
--   5) Light = bottom 30%, Heavy = top 30%, Middle excluded from final chart.
--
-- LTV:
--   Fixed first-three-month realized LTV. Only actual payment events from
--   first_payment_date (inclusive) to first_payment_date + 3 months
--   (exclusive) are included. Amounts are converted to TL, deduplicated and
--   reduced by payment-provider commission. Tax is not deducted.

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
  SELECT
    s.*
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

first_paid AS (
  SELECT
    CAST(s.user_id AS STRING) AS user_id,
    MIN(DATE(s.created_at)) AS first_payment_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN params p
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND UPPER(TRIM(s.payment_option)) != 'PREPAID'
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 101
    AND DATE(s.created_at) <= p.snapshot_date
  GROUP BY user_id
),

mature_payers AS (
  SELECT
    f.user_id,
    f.first_payment_date,
    DATE_ADD(f.first_payment_date, INTERVAL 3 MONTH) AS observation_end_date
  FROM first_paid f
  CROSS JOIN params p
  WHERE DATE_ADD(f.first_payment_date, INTERVAL 3 MONTH) <= p.snapshot_date
),

first_30d_user_day_watch AS (
  SELECT
    m.user_id,
    s.event_date,
    SUM(s.watch_time_second) / 60.0 AS daily_watch_minutes
  FROM mature_payers m
  JOIN first_valid_watch f
    ON m.user_id = f.user_id
  JOIN all_stream s
    ON m.user_id = s.user_id
   AND s.watch_time_second > 0
   AND s.event_date BETWEEN f.first_watch_date
                        AND DATE_ADD(f.first_watch_date, INTERVAL 30 DAY)
  GROUP BY m.user_id, s.event_date
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

watcher_segment AS (
  SELECT
    user_id,
    watch_minutes_30d,
    CASE
      WHEN watch_decile <= 3 THEN 'Light'
      WHEN watch_decile >= 8 THEN 'Heavy'
      ELSE 'Middle'
    END AS watcher_type
  FROM ranked_watchers
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

payment_base AS (
  SELECT
    CAST(s.user_id AS STRING) AS user_id,
    UPPER(TRIM(s.payment_option)) AS payment_option,
    UPPER(TRIM(s.currency)) AS currency_code,
    s.created_at,
    s.inserted_date,
    DATE(s.created_at) AS payment_date,
    DATE(s.valid_until) AS valid_until_date,
    s.apple_original_transaction_id,
    s.google_original_transaction_id,
    SAFE_DIVIDE(
      CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64),
      100.0
    ) AS amount_original
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN params p
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND UPPER(TRIM(s.payment_option)) != 'PREPAID'
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 101
    AND DATE(s.created_at) <= p.snapshot_date
),

payment_rate_candidates AS (
  SELECT
    p.*,
    r.rate_to_try,
    ROW_NUMBER() OVER (
      PARTITION BY
        p.user_id,
        p.payment_option,
        p.currency_code,
        p.created_at,
        p.inserted_date,
        p.valid_until_date,
        p.apple_original_transaction_id,
        p.google_original_transaction_id,
        CAST(p.amount_original AS STRING)
      ORDER BY DATE(r.rate_date) DESC
    ) AS rate_rn
  FROM payment_base p
  LEFT JOIN tcmb_rates r
    ON p.currency_code != 'TRY'
   AND r.currency_code = p.currency_code
   AND r.rate_date <= p.payment_date
),

payment_converted AS (
  SELECT
    * EXCEPT(rate_rn),
    CASE
      WHEN currency_code = 'TRY' THEN amount_original
      ELSE amount_original * rate_to_try
    END AS amount_gross_tl
  FROM payment_rate_candidates
  WHERE currency_code = 'TRY'
     OR rate_rn = 1
),

payment_events AS (
  SELECT
    user_id,
    payment_option,
    payment_date,
    amount_gross_tl
  FROM payment_converted
  WHERE amount_gross_tl IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY
      user_id,
      payment_option,
      currency_code,
      created_at,
      valid_until_date,
      apple_original_transaction_id,
      google_original_transaction_id,
      CAST(amount_original AS STRING)
    ORDER BY inserted_date DESC
  ) = 1
),

user_ltv AS (
  SELECT
    p.user_id,
    COUNT(*) AS payment_count_3m,
    SUM(
      p.amount_gross_tl
        * (1.0 - COALESCE(c.commission_rate, 0.00))
    ) AS realized_ltv_3m_tl
  FROM payment_events p
  JOIN mature_payers m
    ON p.user_id = m.user_id
   AND p.payment_date >= m.first_payment_date
   AND p.payment_date < m.observation_end_date
  LEFT JOIN payment_option_config c
    ON p.payment_option = c.payment_option
  GROUP BY p.user_id
)

SELECT
  w.watcher_type,
  COUNT(DISTINCT w.user_id) AS users,
  AVG(w.watch_minutes_30d) AS avg_watch_minutes_30d,
  3 AS observation_months,
  AVG(COALESCE(l.payment_count_3m, 0)) AS avg_payment_count_3m,
  AVG(COALESCE(l.realized_ltv_3m_tl, 0.0)) AS avg_realized_ltv_3m_tl,
  APPROX_QUANTILES(
    COALESCE(l.realized_ltv_3m_tl, 0.0),
    100
  )[OFFSET(50)] AS median_realized_ltv_3m_tl,
  SUM(COALESCE(l.realized_ltv_3m_tl, 0.0)) AS total_realized_ltv_3m_tl,
  -- Compatibility aliases for the existing Looker chart.
  AVG(COALESCE(l.payment_count_3m, 0)) AS avg_payment_count,
  AVG(COALESCE(l.realized_ltv_3m_tl, 0.0)) AS avg_ltv_tl,
  APPROX_QUANTILES(
    COALESCE(l.realized_ltv_3m_tl, 0.0),
    100
  )[OFFSET(50)] AS median_ltv_tl,
  SUM(COALESCE(l.realized_ltv_3m_tl, 0.0)) AS total_ltv_tl
FROM watcher_segment w
LEFT JOIN user_ltv l
  ON w.user_id = l.user_id
WHERE w.watcher_type IN ('Light', 'Heavy')
GROUP BY w.watcher_type
ORDER BY
  CASE w.watcher_type
    WHEN 'Light' THEN 1
    WHEN 'Heavy' THEN 2
    ELSE 99
  END;
