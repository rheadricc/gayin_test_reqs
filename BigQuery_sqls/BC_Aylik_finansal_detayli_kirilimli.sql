WITH params AS (
  SELECT
    DATE '2026-05-01' AS start_date,
    DATE '2026-05-31' AS end_date
),

may_financial_transactions AS (
  SELECT
    user_id,
    ROUND(amount / 100, 2) AS tutar,
    currency AS para_turu,
    created_at AS islem_tarihi,
    valid_until,
    status,
    payment_option
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`, params p
  WHERE DATE(created_at) BETWEEN p.start_date AND p.end_date
    AND user_id IS NOT NULL
    AND amount IS NOT NULL
    AND currency IS NOT NULL
    AND payment_option != 'PREPAID'
),

classified AS (
  SELECT
    *,
    CASE
      WHEN tutar > 0 THEN 'PAYMENT'
      WHEN tutar < 0 THEN 'REFUND'
      WHEN LOWER(CAST(status AS STRING)) LIKE '%refund%' THEN 'REFUND'
      WHEN LOWER(CAST(status AS STRING)) LIKE '%cancel%' THEN 'REFUND_OR_CANCEL'
      ELSE 'OTHER'
    END AS islem_tipi
  FROM may_financial_transactions
)

SELECT
  payment_option,
  para_turu,

  COUNT(*) AS total_record_count,
  COUNT(DISTINCT user_id) AS total_user_count,

  COUNTIF(islem_tipi = 'PAYMENT') AS payment_record_count,
  COUNT(DISTINCT IF(islem_tipi = 'PAYMENT', user_id, NULL)) AS payment_user_count,
  ROUND(SUM(IF(islem_tipi = 'PAYMENT', tutar, 0)), 2) AS total_payment_amount,

  COUNTIF(islem_tipi IN ('REFUND', 'REFUND_OR_CANCEL')) AS refund_record_count,
  COUNT(DISTINCT IF(islem_tipi IN ('REFUND', 'REFUND_OR_CANCEL'), user_id, NULL)) AS refund_user_count,
  ROUND(SUM(IF(islem_tipi IN ('REFUND', 'REFUND_OR_CANCEL'), tutar, 0)), 2) AS total_refund_amount,

  ROUND(SUM(tutar), 2) AS net_amount

FROM classified
GROUP BY
  payment_option,
  para_turu
ORDER BY
  net_amount DESC;