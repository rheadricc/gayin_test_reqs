-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Output: subscription-start first watch analysis by CONTENT and GENRE

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

contents AS (
  SELECT
    CAST(video_id AS STRING) AS video_id,
    ANY_VALUE(displayname) AS content_name,
    TRIM(SPLIT(ANY_VALUE(genres), ',')[SAFE_OFFSET(0)]) AS genre
  FROM `microgain-9f959.Backoffice_metadata.ContentMetaData`
  WHERE video_id IS NOT NULL
  GROUP BY video_id
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
    SAFE_DIVIDE(CAST(forex_buying AS FLOAT64), NULLIF(CAST(unit AS FLOAT64), 0.0)) AS rate_to_try
  FROM `microgain-9f959.bc_t.tcmb_exchange_rates_raw`
  WHERE currency_code IS NOT NULL
    AND forex_buying IS NOT NULL
    AND unit IS NOT NULL
),

base_payments AS (
  SELECT
    CAST(s.user_id AS STRING) AS user_id,
    DATE(s.created_at) AS payment_date,
    s.payment_option,
    UPPER(TRIM(s.currency)) AS currency_code,
    SAFE_DIVIDE(CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64), 100.0) AS amount_original,
    s.created_at,
    s.inserted_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND s.payment_option != 'PREPAID'
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 101
),

payment_rate_candidates AS (
  SELECT
    b.*,
    r.rate_date AS matched_rate_date,
    r.rate_to_try,
    ROW_NUMBER() OVER (
      PARTITION BY
        b.user_id,
        b.payment_date,
        b.payment_option,
        b.currency_code,
        CAST(b.amount_original AS STRING)
      ORDER BY r.rate_date DESC
    ) AS rate_rn
  FROM base_payments b
  LEFT JOIN tcmb_rates r
    ON b.currency_code != 'TRY'
   AND r.currency_code = b.currency_code
   AND r.rate_date <= b.payment_date
),

payments_converted AS (
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

dedup_payments AS (
  SELECT
    user_id,
    payment_date,
    payment_option,
    amount_gross_tl
  FROM (
    SELECT
      b.*,
      ROW_NUMBER() OVER (
        PARTITION BY
          b.user_id,
          b.payment_date,
          b.payment_option,
          b.currency_code,
          CAST(b.amount_gross_tl AS STRING)
        ORDER BY b.created_at DESC, b.inserted_date DESC
      ) AS rn
    FROM payments_converted b
    WHERE b.amount_gross_tl IS NOT NULL
  )
  WHERE rn = 1
),

net_payments AS (
  SELECT
    p.user_id,
    p.payment_date,
    p.amount_gross_tl
      * (1.0 - COALESCE(c.commission_rate, 0.00)) AS net_payment_tl
  FROM dedup_payments p
  LEFT JOIN payment_option_config c
    ON p.payment_option = c.payment_option
),

subscription_start AS (
  SELECT
    user_id,
    MIN(payment_date) AS subscription_start_date
  FROM net_payments
  GROUP BY user_id
),

selected_subscribers AS (
  SELECT
    s.user_id,
    s.subscription_start_date
  FROM subscription_start s
  CROSS JOIN params p
  WHERE s.subscription_start_date BETWEEN p.ds_start AND p.ds_end
),

user_ltv AS (
  SELECT
    user_id,
    SUM(net_payment_tl) AS user_ltv_tl,
    COUNT(*) AS payment_count,
    MIN(payment_date) AS first_payment_date,
    MAX(payment_date) AS last_payment_date
  FROM net_payments
  GROUP BY user_id
),

stream_events AS (
  SELECT
    CAST(s.user_id AS STRING) AS user_id,
    CAST(s.video_id AS STRING) AS video_id,
    s.Datetime_Ist,
    s.event_date,
    c.content_name,
    c.genre
  FROM `microgain-9f959.looker_report.content_report_streaming_V2` s
  JOIN contents c
    ON TRIM(CAST(s.video_id AS STRING)) = TRIM(c.video_id)
  WHERE s.user_id IS NOT NULL
    AND s.video_id IS NOT NULL
    AND s.Datetime_Ist IS NOT NULL
    AND c.content_name IS NOT NULL
    AND TRIM(c.content_name) != ''
    AND c.genre IS NOT NULL
    AND TRIM(c.genre) != ''
),

first_watch_after_subscription AS (
  SELECT
    user_id,
    subscription_start_date,
    event_date AS first_watch_date,
    video_id AS first_video_id,
    content_name AS first_content_name,
    genre AS first_genre
  FROM (
    SELECT
      ss.user_id,
      ss.subscription_start_date,
      se.event_date,
      se.Datetime_Ist,
      se.video_id,
      se.content_name,
      se.genre,
      ROW_NUMBER() OVER (
        PARTITION BY ss.user_id
        ORDER BY se.Datetime_Ist ASC, se.video_id ASC
      ) AS rn
    FROM selected_subscribers ss
    JOIN stream_events se
      ON ss.user_id = se.user_id
     AND se.event_date >= ss.subscription_start_date
  )
  WHERE rn = 1
),

content_agg AS (
  SELECT
    'CONTENT' AS breakdown_type,
    first_content_name AS breakdown_name,
    COUNT(DISTINCT f.user_id) AS first_watch_users,
    AVG(COALESCE(l.user_ltv_tl, 0)) AS avg_ltv_tl,
    APPROX_QUANTILES(COALESCE(l.user_ltv_tl, 0), 100)[OFFSET(50)] AS median_ltv_tl,
    SUM(COALESCE(l.user_ltv_tl, 0)) AS total_ltv_tl,
    AVG(COALESCE(l.payment_count, 0)) AS avg_payment_count
  FROM first_watch_after_subscription f
  LEFT JOIN user_ltv l
    ON f.user_id = l.user_id
  GROUP BY first_content_name
),

genre_agg AS (
  SELECT
    'GENRE' AS breakdown_type,
    first_genre AS breakdown_name,
    COUNT(DISTINCT f.user_id) AS first_watch_users,
    AVG(COALESCE(l.user_ltv_tl, 0)) AS avg_ltv_tl,
    APPROX_QUANTILES(COALESCE(l.user_ltv_tl, 0), 100)[OFFSET(50)] AS median_ltv_tl,
    SUM(COALESCE(l.user_ltv_tl, 0)) AS total_ltv_tl,
    AVG(COALESCE(l.payment_count, 0)) AS avg_payment_count
  FROM first_watch_after_subscription f
  LEFT JOIN user_ltv l
    ON f.user_id = l.user_id
  GROUP BY first_genre
),

final AS (
  SELECT * FROM content_agg
  UNION ALL
  SELECT * FROM genre_agg
)

SELECT
  breakdown_type,
  breakdown_name,
  first_watch_users,
  avg_ltv_tl,
  median_ltv_tl,
  total_ltv_tl,
  avg_payment_count
FROM final
ORDER BY breakdown_type, first_watch_users DESC, avg_ltv_tl DESC;
