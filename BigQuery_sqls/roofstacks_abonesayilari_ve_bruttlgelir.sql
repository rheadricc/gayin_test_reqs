WITH params AS (
  SELECT
    DATE '2026-04-01' AS start_date,
    DATE '2026-04-30' AS end_date
)

SELECT
  payment_option,

  COUNT(*) AS payment_record_count,
  COUNT(DISTINCT user_id) AS unique_user_count,

  ROUND(SUM(amount) / 100, 2) AS total_amount_try,

FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`, params p
WHERE DATE(created_at) BETWEEN p.start_date AND p.end_date
  AND amount IS NOT NULL
  AND amount > 0
  AND payment_option != 'PREPAID'

GROUP BY payment_option
ORDER BY total_amount_try DESC;