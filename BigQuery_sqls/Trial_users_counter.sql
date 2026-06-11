WITH trial_users AS (
  SELECT
    user_id,
    status,
    payment_option,
    free_trial_start_date,
    free_trial_end_date,
    valid_until,

    DATE(free_trial_start_date) AS trial_start_date,
    DATE(free_trial_end_date) AS trial_end_date,
    CURRENT_DATE("Europe/Istanbul") AS today,

    DATE_DIFF(
      CURRENT_DATE("Europe/Istanbul"),
      DATE(free_trial_start_date),
      DAY
    ) + 1 AS trial_day

  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE user_id IS NOT NULL
    AND status IN ('ACTIVE', 'ON_HOLD', 'IN_GRACE','CANCELED')
    AND payment_option != 'PREPAID'

    -- Free trial içinde olanlar
    AND free_trial_start_date IS NOT NULL
    AND free_trial_end_date IS NOT NULL
    AND CURRENT_DATE("Europe/Istanbul")
        BETWEEN DATE(free_trial_start_date) AND DATE(free_trial_end_date)
)

SELECT
  trial_day - 1 AS free_trial_day,
  COUNT(DISTINCT user_id) AS user_count
FROM trial_users
WHERE trial_day >= 1
GROUP BY free_trial_day
ORDER BY free_trial_day;