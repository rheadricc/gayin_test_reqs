WITH params AS (
  SELECT
    DATE '2026-03-28' AS start_date,
    DATE '2026-03-28' AS end_date
),

subs_filtered AS (
  SELECT
    sp.status,
    sp.payment_option,
    sp.amount,
    sp.currency,
    sp.google_original_transaction_id,
    sp.apple_original_transaction_id,
    sp.user_id,
    sp.email,
    sp.created_at,
    sp.valid_until,
    DATE(sp.created_at) AS created_date,
    DATE(sp.valid_until) AS valid_until_date,
    DATE_SUB(DATE(sp.valid_until), INTERVAL 30 DAY) AS derived_payment_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` sp
  WHERE sp.status = 'ACTIVE'
    AND sp.payment_option != 'PREPAID'
),

latest_per_user AS (
  SELECT *
  FROM subs_filtered
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id
    ORDER BY valid_until DESC, created_at DESC
  ) = 1
),

final_filtered AS (
  SELECT
    lpu.status,
    lpu.payment_option,
    lpu.amount,
    lpu.currency,
    lpu.google_original_transaction_id,
    lpu.apple_original_transaction_id,
    lpu.user_id,
    lpu.email,
    lpu.created_at,
    lpu.valid_until,
    lpu.created_date,
    lpu.valid_until_date,
    lpu.derived_payment_date,
    DATE_DIFF(lpu.created_date, lpu.derived_payment_date, DAY) AS signed_diff_day,
    ABS(DATE_DIFF(lpu.created_date, lpu.derived_payment_date, DAY)) AS abs_diff_day
  FROM latest_per_user lpu
  CROSS JOIN params p
  WHERE ABS(DATE_DIFF(lpu.created_date, lpu.derived_payment_date, DAY)) <= 1
    AND lpu.derived_payment_date BETWEEN p.start_date AND p.end_date
)

SELECT
  status,
  payment_option,
  amount,
  currency,
  google_original_transaction_id,
  apple_original_transaction_id,
  user_id,
  email,
  created_at,
  valid_until,
  created_date,
  valid_until_date,
  derived_payment_date,
  signed_diff_day,
  abs_diff_day
FROM final_filtered
ORDER BY derived_payment_date, created_at;