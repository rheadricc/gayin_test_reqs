-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Output: Heavy vs Light watcher LTV (TRY + foreign currency, paying users only)
-- REVIEW NOTE: This uses active-day prorated LTV and is closer to monthly realized LTV logic.
-- Logic:
--   - cohort window shifted back by 90 days
--   - first meaningful watch defines cohort entry
--   - watcher segment based on first 30-day watch time percentiles
--   - Light = bottom 30%
--   - Heavy = top 30%
--   - Middle excluded
--   - daily watch outliers above 24h are excluded from segmentation
--   - LTV uses TRY + foreign currency realized lifetime value
--   - Foreign currencies converted to TRY with TCMB forex_buying rate
--   - If exact payment date rate is missing, latest available TCMB rate before payment date is used
--   - CANCELED users are counted as active until valid_until
--   - only users with converted TL LTV are included

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

/* =====================================================
   1) CONTENT MAP
   ===================================================== */
contents AS (
  SELECT
    CAST(video_id AS STRING) AS video_id,
    TRIM(SPLIT(ANY_VALUE(genres), ',')[SAFE_OFFSET(0)]) AS genre
  FROM `microgain-9f959.Backoffice_metadata.ContentMetaData`
  WHERE video_id IS NOT NULL
  GROUP BY video_id
),

/* =====================================================
   2) STREAM EVENTS
   ===================================================== */
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

/* =====================================================
   3) FIRST VALID WATCH / COHORT
   ===================================================== */
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

/* =====================================================
   4) WATCHER SEGMENTATION WITH DAILY 24H CAP
   ===================================================== */
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

/* =====================================================
   5) USER LTV - TRY + FX CONVERTED TO TL
   ===================================================== */
payment_option_config AS (
  SELECT 'APP_STORE'      AS payment_option, 0.30 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'PLAY_STORE'     AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'MOBILE_PAYMENT' AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'CRAFTGATE'      AS payment_option, 0.00 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'IYZICO'         AS payment_option, 0.03 AS commission_rate, 0.20 AS tax_rate
),

tcmb_rates AS (
  SELECT
    DATE(rate_date) AS rate_date,
    UPPER(currency_code) AS currency_code,
    SAFE_DIVIDE(CAST(forex_buying AS FLOAT64), NULLIF(CAST(unit AS FLOAT64), 0.0)) AS rate_to_try
  FROM `microgain-9f959.bc_t.tcmb_exchange_rates_raw`
  WHERE currency_code IS NOT NULL
    AND forex_buying IS NOT NULL
    AND unit IS NOT NULL
),

subs AS (
  SELECT
    s.user_id,
    s.payment_option,
    UPPER(TRIM(s.currency)) AS currency_code,
    s.status,
    s.created_at,
    s.inserted_date,
    DATE(s.created_at)  AS created_date,
    DATE(s.valid_until) AS valid_until_date,
    DATE(s.grace_until) AS grace_until_date,
    DATE(s.hold_until)  AS hold_until_date,
    CASE
      WHEN s.status = 'ON_HOLD'  THEN COALESCE(DATE(s.hold_until),  DATE(s.valid_until))
      WHEN s.status = 'IN_GRACE' THEN COALESCE(DATE(s.grace_until), DATE(s.valid_until))
      ELSE DATE(s.valid_until)
    END AS active_end_date,
    SAFE_DIVIDE(CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64), 100.0) AS amount_original
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND s.payment_option != 'PREPAID'
    AND s.status IN ('ACTIVE', 'CANCELED', 'IN_GRACE', 'ON_HOLD')
),

subs_with_rate_candidates AS (
  SELECT
    s.*,
    r.rate_date AS matched_rate_date,
    r.rate_to_try,
    ROW_NUMBER() OVER (
      PARTITION BY
        CAST(s.user_id AS STRING),
        s.payment_option,
        s.currency_code,
        s.created_at,
        s.inserted_date,
        s.valid_until_date,
        CAST(s.amount_original AS STRING)
      ORDER BY r.rate_date DESC
    ) AS rate_rn
  FROM subs s
  LEFT JOIN tcmb_rates r
    ON s.currency_code != 'TRY'
   AND r.currency_code = s.currency_code
   AND r.rate_date <= s.created_date
),

subs_converted AS (
  SELECT
    * EXCEPT(rate_rn),
    CASE
      WHEN currency_code = 'TRY' THEN amount_original
      ELSE amount_original * rate_to_try
    END AS amount_gross_tl
  FROM subs_with_rate_candidates
  WHERE currency_code = 'TRY'
     OR rate_rn = 1
),

days AS (
  SELECT
    d AS dt
  FROM params,
  UNNEST(GENERATE_DATE_ARRAY(DATE '2021-01-01', ds_end)) AS d
),

daily_active_raw AS (
  SELECT
    d.dt,
    s.user_id,
    s.payment_option,
    s.amount_gross_tl,
    s.created_at,
    s.inserted_date
  FROM days d
  JOIN subs_converted s
    ON d.dt BETWEEN s.created_date AND s.active_end_date
   AND s.amount_gross_tl IS NOT NULL
),

daily_active_dedup AS (
  SELECT
    r.dt,
    r.user_id,
    r.payment_option,
    r.amount_gross_tl
  FROM (
    SELECT
      r.*,
      ROW_NUMBER() OVER (
        PARTITION BY r.dt, r.user_id
        ORDER BY r.created_at DESC, r.inserted_date DESC
      ) AS rn
    FROM daily_active_raw r
  ) r
  WHERE r.rn = 1
),

daily_revenue AS (
  SELECT
    a.dt,
    a.user_id,
    SAFE_DIVIDE(
      a.amount_gross_tl
      * (1.0 - COALESCE(c.commission_rate, 0.00))
      * (1.0 - COALESCE(c.tax_rate, 0.20)),
      EXTRACT(DAY FROM LAST_DAY(a.dt))
    ) AS daily_rev_tl
  FROM daily_active_dedup a
  LEFT JOIN payment_option_config c
    ON a.payment_option = c.payment_option
),

user_ltv AS (
  SELECT
    CAST(user_id AS STRING) AS user_id,
    SUM(daily_rev_tl) AS user_ltv_tl
  FROM daily_revenue
  GROUP BY user_id
),

/* =====================================================
   6) FINAL
   ===================================================== */
final AS (
  SELECT
    w.watcher_type,
    COUNT(DISTINCT w.user_id) AS users,
    AVG(w.watch_minutes_30d) AS avg_watch_minutes_30d,
    AVG(l.user_ltv_tl) AS avg_ltv_tl,
    APPROX_QUANTILES(l.user_ltv_tl, 100)[OFFSET(50)] AS median_ltv_tl,
    SUM(l.user_ltv_tl) AS total_ltv_tl
  FROM watcher_segment w
  JOIN user_ltv l
    ON w.user_id = l.user_id
  WHERE w.watcher_type IN ('Light', 'Heavy')
  GROUP BY w.watcher_type
)

SELECT
  watcher_type,
  users,
  avg_watch_minutes_30d,
  avg_ltv_tl,
  median_ltv_tl,
  total_ltv_tl
FROM final
ORDER BY
  CASE watcher_type
    WHEN 'Light' THEN 1
    WHEN 'Heavy' THEN 2
    ELSE 99
  END;