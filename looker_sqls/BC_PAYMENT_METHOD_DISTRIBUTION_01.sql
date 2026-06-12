-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- New name: BC_PAYMENT_METHOD_DISTRIBUTION_01
-- Output: Payment method distribution for selected date range
--
-- Logic:
--   - Shows collected payment distribution by payment method.
--   - Primary donut metric: payment_count.
--   - payment_share_pct is calculated over selected period total payment_count.
--   - Store payments are sourced from subs_payment because APP_STORE / PLAY_STORE are not part of bc_t provider raw tables.
--   - Craftgate is sourced from subs_payment unless/until a separate Craftgate raw transaction table is added.
--   - IYZICO / PARAM / PAYGURU / N_KOLAY are sourced from bc_t provider transaction raw tables.
--   - Provider raw tables do not expose user_id; user_count is only populated where user_id is available.
--   - Trial/provision/test-like low amount payments are excluded with fixed 101 TL minimum threshold.
--   - Refund/cancel/reversal-like provider rows are excluded by transaction/status text filters where available.
--
-- Recommended Looker donut setup:
--   - Dimension: payment_method_label or payment_provider
--   - Metric: payment_count
--   - Optional label: donut_label

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

payment_provider_spine AS (
  SELECT 'APPLE' AS payment_provider, 'Apple / App Store' AS payment_method_label UNION ALL
  SELECT 'GOOGLE' AS payment_provider, 'Google / Play Store' AS payment_method_label UNION ALL
  SELECT 'CRAFTGATE' AS payment_provider, 'Craftgate' AS payment_method_label UNION ALL
  SELECT 'IYZICO' AS payment_provider, 'Iyzico' AS payment_method_label UNION ALL
  SELECT 'PARAM' AS payment_provider, 'Param' AS payment_method_label UNION ALL
  SELECT 'PAYGURU' AS payment_provider, 'Payguru / Mobil' AS payment_method_label UNION ALL
  SELECT 'N_KOLAY' AS payment_provider, 'N Kolay' AS payment_method_label
),

/* =====================================================
   1) STORE + CRAFTGATE PAYMENTS
   Source: subs_payment

   APP_STORE, PLAY_STORE and CRAFTGATE are not covered by
   bc_t.iyzico/param/payguru/nkolay transaction raw tables.
   Therefore they are counted from subs_payment.payment_option.
   ===================================================== */

store_and_craftgate_payments AS (
  SELECT
    CASE
      WHEN UPPER(TRIM(s.payment_option)) = 'APP_STORE'  THEN 'APPLE'
      WHEN UPPER(TRIM(s.payment_option)) = 'PLAY_STORE' THEN 'GOOGLE'
      WHEN UPPER(TRIM(s.payment_option)) = 'CRAFTGATE'  THEN 'CRAFTGATE'
      ELSE UPPER(TRIM(s.payment_option))
    END AS payment_provider,
    CASE
      WHEN UPPER(TRIM(s.payment_option)) = 'APP_STORE'  THEN 'Apple / App Store'
      WHEN UPPER(TRIM(s.payment_option)) = 'PLAY_STORE' THEN 'Google / Play Store'
      WHEN UPPER(TRIM(s.payment_option)) = 'CRAFTGATE'  THEN 'Craftgate'
      ELSE UPPER(TRIM(s.payment_option))
    END AS payment_method_label,
    CAST(s.user_id AS STRING) AS user_id,
    COALESCE(
      CAST(s.apple_original_transaction_id AS STRING),
      CAST(s.google_original_transaction_id AS STRING),
      CONCAT(
        CAST(s.user_id AS STRING),
        '-',
        CAST(s.created_at AS STRING),
        '-',
        CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS STRING)
      )
    ) AS transaction_key,
    DATE(s.created_at) AS payment_date,
    SAFE_DIVIDE(CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64), 100.0) AS amount_original,
    UPPER(TRIM(s.currency)) AS currency_code,
    'subs_payment' AS source_table
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN params p
  WHERE DATE(s.created_at) BETWEEN p.ds_start AND p.ds_end
    AND s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND UPPER(TRIM(s.payment_option)) IN ('APP_STORE', 'PLAY_STORE', 'CRAFTGATE')
    AND SAFE_DIVIDE(CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64), 100.0) >= 101.0
),

/* =====================================================
   2) PROVIDER RAW PAYMENTS
   Source: bc_t provider transaction raw tables

   The four Airflow provider tables are the desired sources for
   IYZICO / PARAM / PAYGURU / N_KOLAY. They are normalized with
   provider-specific transaction id, transaction date, currency and positive amount fields.
   Only positive gross_amount rows are counted as collected payments.

   Required normalized output columns:
     payment_provider
     payment_method_label
     user_id
     transaction_key
     payment_date
     amount_original
     currency_code
     source_table
   ===================================================== */

provider_raw_payments AS (
  SELECT
    'IYZICO' AS payment_provider,
    'Iyzico' AS payment_method_label,
    CAST(NULL AS STRING) AS user_id,
    COALESCE(
      CAST(transaction_id AS STRING),
      CAST(payment_tx_id AS STRING),
      CAST(payment_id AS STRING),
      CAST(conversation_id AS STRING),
      CAST(basket_id AS STRING),
      CONCAT('IYZICO-', CAST(transaction_date AS STRING), '-', CAST(COALESCE(paid_price, amount, price) AS STRING))
    ) AS transaction_key,
    COALESCE(
      SAFE_CAST(transaction_date AS DATE),
      DATE(SAFE_CAST(transaction_date AS TIMESTAMP)),
      report_date
    ) AS payment_date,
    CAST(COALESCE(paid_price, amount, price) AS FLOAT64) AS amount_original,
    UPPER(TRIM(COALESCE(currency, transaction_currency, settlement_currency))) AS currency_code,
    'bc_t.iyzico_transactions_raw' AS source_table
  FROM `microgain-9f959.bc_t.iyzico_transactions_raw`
  CROSS JOIN params p
  WHERE COALESCE(
      SAFE_CAST(transaction_date AS DATE),
      DATE(SAFE_CAST(transaction_date AS TIMESTAMP)),
      report_date
    ) BETWEEN p.ds_start AND p.ds_end
    AND CAST(COALESCE(paid_price, amount, price) AS FLOAT64) >= 101.0
    AND NOT REGEXP_CONTAINS(UPPER(COALESCE(transaction_type, '')), r'(REFUND|CANCEL|CANCELLATION|REVERSAL|IADE|İADE|IPTAL|İPTAL)')
    AND NOT REGEXP_CONTAINS(UPPER(COALESCE(transaction_status, '')), r'(FAILED|FAIL|ERROR|REFUND|CANCEL|CANCELLATION|REVERSAL|IADE|İADE|IPTAL|İPTAL)')
    AND NOT REGEXP_CONTAINS(UPPER(COALESCE(payment_phase, '')), r'(REFUND|CANCEL|CANCELLATION|REVERSAL|IADE|İADE|IPTAL|İPTAL)')

  UNION ALL

  SELECT
    'PARAM' AS payment_provider,
    'Param' AS payment_method_label,
    CAST(NULL AS STRING) AS user_id,
    COALESCE(
      CAST(transaction_id AS STRING),
      CAST(order_id AS STRING),
      CONCAT('PARAM-', CAST(transaction_date AS STRING), '-', CAST(gross_amount AS STRING))
    ) AS transaction_key,
    DATE(transaction_date) AS payment_date,
    CAST(gross_amount AS FLOAT64) AS amount_original,
    UPPER(TRIM(currency)) AS currency_code,
    'bc_t.param_transactions_raw' AS source_table
  FROM `microgain-9f959.bc_t.param_transactions_raw`
  CROSS JOIN params p
  WHERE DATE(transaction_date) BETWEEN p.ds_start AND p.ds_end
    AND CAST(gross_amount AS FLOAT64) >= 101.0
    AND NOT REGEXP_CONTAINS(UPPER(COALESCE(transaction_type, '')), r'(REFUND|CANCEL|CANCELLATION|REVERSAL|IADE|İADE|IPTAL|İPTAL)')

  UNION ALL

  SELECT
    'PAYGURU' AS payment_provider,
    'Payguru / Mobil' AS payment_method_label,
    CAST(NULL AS STRING) AS user_id,
    COALESCE(
      CAST(transaction_id AS STRING),
      CAST(reference_code AS STRING),
      CAST(subscription_id AS STRING),
      CONCAT('PAYGURU-', CAST(transaction_date AS STRING), '-', CAST(amount AS STRING))
    ) AS transaction_key,
    DATE(transaction_date) AS payment_date,
    CAST(amount AS FLOAT64) AS amount_original,
    UPPER(TRIM(currency)) AS currency_code,
    'bc_t.payguru_transactions_raw' AS source_table
  FROM `microgain-9f959.bc_t.payguru_transactions_raw`
  CROSS JOIN params p
  WHERE DATE(transaction_date) BETWEEN p.ds_start AND p.ds_end
    AND CAST(amount AS FLOAT64) >= 101.0
    AND NOT REGEXP_CONTAINS(UPPER(COALESCE(status, '')), r'(FAILED|FAIL|ERROR|REFUND|CANCEL|CANCELLATION|REVERSAL|IADE|İADE|IPTAL|İPTAL)')
    AND NOT REGEXP_CONTAINS(UPPER(COALESCE(status_text, '')), r'(FAILED|FAIL|ERROR|REFUND|CANCEL|CANCELLATION|REVERSAL|IADE|İADE|IPTAL|İPTAL)')

  UNION ALL

  SELECT
    'N_KOLAY' AS payment_provider,
    'N Kolay' AS payment_method_label,
    CAST(NULL AS STRING) AS user_id,
    COALESCE(
      CAST(transaction_id AS STRING),
      CAST(reference_code AS STRING),
      CAST(client_reference_code AS STRING),
      CAST(auth_code AS STRING),
      CONCAT('N_KOLAY-', CAST(transaction_date AS STRING), '-', CAST(transaction_amount AS STRING))
    ) AS transaction_key,
    DATE(transaction_date) AS payment_date,
    CAST(transaction_amount AS FLOAT64) AS amount_original,
    UPPER(TRIM(currency)) AS currency_code,
    'bc_t.nkolay_transactions_raw' AS source_table
  FROM `microgain-9f959.bc_t.nkolay_transactions_raw`
  CROSS JOIN params p
  WHERE DATE(transaction_date) BETWEEN p.ds_start AND p.ds_end
    AND CAST(transaction_amount AS FLOAT64) >= 101.0
    AND NOT REGEXP_CONTAINS(UPPER(COALESCE(transaction_type, '')), r'(REFUND|CANCEL|CANCELLATION|REVERSAL|IADE|İADE|IPTAL|İPTAL)')
    AND NOT REGEXP_CONTAINS(UPPER(COALESCE(status, '')), r'(FAILED|FAIL|ERROR|REFUND|CANCEL|CANCELLATION|REVERSAL|IADE|İADE|IPTAL|İPTAL)')
),

/* =====================================================
   3) UNION + DEDUP
   ===================================================== */

all_payments AS (
  SELECT * FROM store_and_craftgate_payments
  UNION ALL
  SELECT * FROM provider_raw_payments
),

dedup_payments AS (
  SELECT
    payment_provider,
    payment_method_label,
    user_id,
    transaction_key,
    payment_date,
    amount_original,
    currency_code,
    source_table
  FROM (
    SELECT
      p.*,
      ROW_NUMBER() OVER (
        PARTITION BY payment_provider, transaction_key
        ORDER BY payment_date DESC
      ) AS rn
    FROM all_payments p
    WHERE payment_provider IS NOT NULL
      AND transaction_key IS NOT NULL
      AND amount_original >= 101.0
  )
  WHERE rn = 1
),

base AS (
  SELECT
    payment_provider,
    payment_method_label,
    COUNT(*) AS payment_count,
    CASE
      WHEN COUNTIF(user_id IS NOT NULL) = 0 THEN NULL
      ELSE COUNT(DISTINCT user_id)
    END AS user_count,
    COUNT(DISTINCT transaction_key) AS distinct_transaction_count,
    ROUND(SUM(amount_original), 2) AS total_amount_original
  FROM dedup_payments
  GROUP BY payment_provider, payment_method_label
),

final AS (
  SELECT
    s.payment_provider,
    s.payment_method_label,
    COALESCE(b.payment_count, 0) AS payment_count,
    b.user_count,
    COALESCE(b.distinct_transaction_count, 0) AS distinct_transaction_count,
    COALESCE(b.total_amount_original, 0.0) AS total_amount_original,
    SAFE_DIVIDE(COALESCE(b.payment_count, 0), SUM(COALESCE(b.payment_count, 0)) OVER ()) AS payment_share_pct,
    SAFE_DIVIDE(b.user_count, SUM(b.user_count) OVER ()) AS user_share_pct,
    CASE
      WHEN b.user_count IS NULL THEN 'user_id_yok'
      ELSE 'user_id_var'
    END AS user_count_status,
    SAFE_DIVIDE(COALESCE(b.total_amount_original, 0.0), SUM(COALESCE(b.total_amount_original, 0.0)) OVER ()) AS amount_share_pct,
    CONCAT(
      s.payment_method_label,
      ' ',
      CAST(COALESCE(b.payment_count, 0) AS STRING),
      ' ödeme (',
      CAST(ROUND(SAFE_DIVIDE(COALESCE(b.payment_count, 0), SUM(COALESCE(b.payment_count, 0)) OVER ()) * 100, 1) AS STRING),
      '%)'
    ) AS donut_label
  FROM payment_provider_spine s
  LEFT JOIN base b
    ON s.payment_provider = b.payment_provider
)

SELECT
  payment_provider,
  payment_method_label,
  payment_count,
  user_count,
  distinct_transaction_count,
  total_amount_original,
  payment_share_pct,
  user_share_pct,
  user_count_status,
  amount_share_pct,
  donut_label
FROM final
ORDER BY payment_count DESC;