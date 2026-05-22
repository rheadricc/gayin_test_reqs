-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Output: category-level average realized LTV
-- REVIEW NOTE: This query uses raw payment-sum realized LTV, while monthly realized LTV uses prorated active-day revenue.
-- Keep only if the intended metric is lifetime payment-sum by first watched category; otherwise align to active-day LTV.
-- Logic:
--   - first category = user's first meaningful watched content's first genre
--   - LTV = TRY-only realized LTV (real payment sum net of commission/tax)
--   - final = average LTV by first category

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

/* =====================================================
   1) FIRST CATEGORY
   ===================================================== */

contents AS (
  SELECT
    CAST(video_id AS STRING) AS video_id,
    ANY_VALUE(displayname) AS content_name,
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
    event_date
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
    event_date AS first_watch_date,
    video_id AS first_video_id,
    genre AS first_category
  FROM (
    SELECT
      s.*,
      ROW_NUMBER() OVER (
        PARTITION BY s.user_id
        ORDER BY s.Datetime_Ist ASC, s.video_id ASC
      ) AS rn
    FROM stream_with_genre s
  )
  WHERE rn = 1
),

first_category AS (
  SELECT
    user_id,
    first_watch_date,
    first_video_id,
    first_category
  FROM first_valid_watch
  CROSS JOIN params p
  WHERE first_watch_date BETWEEN p.ds_start AND p.ds_end
),

/* =====================================================
   2) USER LTV (TRY-ONLY REALIZED)
   ===================================================== */

payment_option_config AS (
  SELECT 'APP_STORE'      AS payment_option, 0.30 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'PLAY_STORE'     AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'MOBILE_PAYMENT' AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'CRAFTGATE'      AS payment_option, 0.00 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'IYZICO'         AS payment_option, 0.03 AS commission_rate, 0.20 AS tax_rate
),

base_payments AS (
  SELECT
    CAST(s.user_id AS STRING) AS user_id,
    DATE(s.created_at) AS payment_date,
    s.payment_option,
    UPPER(TRIM(s.currency)) AS currency,
    CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS INT64) AS amount_minor,
    s.created_at,
    s.inserted_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND s.payment_option != 'PREPAID'
    AND UPPER(TRIM(s.currency)) = 'TRY'
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 0
),

dedup_payments AS (
  SELECT
    user_id,
    payment_date,
    payment_option,
    amount_minor
  FROM (
    SELECT
      b.*,
      ROW_NUMBER() OVER (
        PARTITION BY
          b.user_id,
          b.payment_date,
          b.payment_option,
          b.amount_minor
        ORDER BY b.created_at DESC, b.inserted_date DESC
      ) AS rn
    FROM base_payments b
  )
  WHERE rn = 1
),

net_payments AS (
  SELECT
    p.user_id,
    p.payment_date,
    SAFE_DIVIDE(CAST(p.amount_minor AS FLOAT64), 100.0)
      * (1.0 - COALESCE(c.commission_rate, 0.00))
      * (1.0 - COALESCE(c.tax_rate, 0.20)) AS net_payment_tl
  FROM dedup_payments p
  LEFT JOIN payment_option_config c
    ON p.payment_option = c.payment_option
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

/* =====================================================
   3) FINAL AGG
   ===================================================== */

final AS (
  SELECT
    f.first_category,
    COUNT(DISTINCT f.user_id) AS users,
    AVG(COALESCE(l.user_ltv_tl, 0)) AS avg_ltv_tl,
    APPROX_QUANTILES(COALESCE(l.user_ltv_tl, 0), 100)[OFFSET(50)] AS median_ltv_tl,
    MIN(COALESCE(l.user_ltv_tl, 0)) AS min_ltv_tl,
    MAX(COALESCE(l.user_ltv_tl, 0)) AS max_ltv_tl,
    SUM(COALESCE(l.user_ltv_tl, 0)) AS total_ltv_tl,
    AVG(COALESCE(l.payment_count, 0)) AS avg_payment_count
  FROM first_category f
  LEFT JOIN user_ltv l
    ON f.user_id = l.user_id
  GROUP BY f.first_category
)

SELECT
  first_category,
  users,
  avg_ltv_tl,
  median_ltv_tl,
  min_ltv_tl,
  max_ltv_tl,
  total_ltv_tl,
  avg_payment_count
FROM final
ORDER BY avg_ltv_tl DESC, users DESC;