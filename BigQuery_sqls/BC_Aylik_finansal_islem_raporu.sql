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
)

SELECT
  payment_option,
  COUNT(*) AS payment_record_count,
  COUNT(DISTINCT user_id) AS unique_user_count,
  ROUND(SUM(tutar), 2) AS total_amount,
  ROUND(AVG(tutar), 2) AS avg_amount
FROM may_financial_transactions
GROUP BY
  payment_option
ORDER BY
  total_amount DESC;