-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Name: BC_PAYMENT_METHOD_DISTRIBUTION_01
-- Source: BO subs_payment only.
--
-- This dashboard is the BO payment-method distribution. Provider raw tables
-- are intentionally not mixed into it; mixing both sources can double-count
-- the same economy.
--
-- Rules:
--   - PREPAID excluded.
--   - Raw minor-unit amount must be > 101.
--   - Foreign currency is converted with the latest available TCMB
--     forex_buying rate on or before payment date.
--   - Payment events are deduplicated.
--
-- Looker donut:
--   Dimension: payment_method_label
--   Metric: payment_count

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    LEAST(
      PARSE_DATE('%Y%m%d', @DS_END_DATE),
      DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
    ) AS ds_end
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
    AND DATE(s.created_at) BETWEEN p.ds_start AND p.ds_end
    AND COALESCE(s.amount, s.amount_before_promotions, 0) > 101
),

rate_candidates AS (
  SELECT
    p.*,
    r.rate_date AS matched_rate_date,
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
      ORDER BY r.rate_date DESC
    ) AS rate_rn
  FROM payment_base p
  LEFT JOIN tcmb_rates r
    ON p.currency_code != 'TRY'
   AND r.currency_code = p.currency_code
   AND r.rate_date <= p.payment_date
),

converted AS (
  SELECT
    * EXCEPT(rate_rn),
    CASE
      WHEN currency_code = 'TRY' THEN amount_original
      ELSE amount_original * rate_to_try
    END AS amount_gross_tl
  FROM rate_candidates
  WHERE currency_code = 'TRY'
     OR rate_rn = 1
),

dedup AS (
  SELECT
    user_id,
    payment_option,
    amount_gross_tl
  FROM (
    SELECT
      p.*,
      ROW_NUMBER() OVER (
        PARTITION BY
          p.user_id,
          p.payment_option,
          p.currency_code,
          p.created_at,
          p.valid_until_date,
          p.apple_original_transaction_id,
          p.google_original_transaction_id,
          CAST(p.amount_original AS STRING)
        ORDER BY p.inserted_date DESC
      ) AS payment_rn
    FROM converted p
    WHERE p.amount_gross_tl IS NOT NULL
  )
  WHERE payment_rn = 1
),

base AS (
  SELECT
    payment_option,
    CASE payment_option
      WHEN 'APP_STORE' THEN 'Apple / App Store'
      WHEN 'PLAY_STORE' THEN 'Google / Play Store'
      WHEN 'MOBILE_PAYMENT' THEN 'Payguru / Mobil'
      WHEN 'IYZICO' THEN 'Iyzico'
      WHEN 'CRAFTGATE' THEN 'Craftgate (Legacy)'
      ELSE payment_option
    END AS payment_method_label,
    COUNT(*) AS payment_count,
    COUNT(DISTINCT user_id) AS user_count,
    SUM(amount_gross_tl) AS gross_collections_tl
  FROM dedup
  GROUP BY payment_option, payment_method_label
)

SELECT
  payment_option AS payment_provider,
  payment_method_label,
  payment_count,
  user_count,
  gross_collections_tl,
  SAFE_DIVIDE(payment_count, SUM(payment_count) OVER ()) AS payment_share_pct,
  SAFE_DIVIDE(user_count, SUM(user_count) OVER ()) AS user_share_pct,
  SAFE_DIVIDE(
    gross_collections_tl,
    SUM(gross_collections_tl) OVER ()
  ) AS amount_share_pct,
  CONCAT(
    payment_method_label,
    ' ',
    CAST(payment_count AS STRING),
    ' işlem (',
    CAST(
      ROUND(
        SAFE_DIVIDE(payment_count, SUM(payment_count) OVER ()) * 100,
        1
      ) AS STRING
    ),
    '%)'
  ) AS donut_label
FROM base
ORDER BY payment_count DESC;
