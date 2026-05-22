WITH params AS (
  SELECT DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 1 DAY) AS latest_date
),

periods AS (
  SELECT 'Son Gün' AS donem, latest_date AS target_date, 1 AS sort_order
  FROM params

  UNION ALL
  SELECT 'Önceki Gün', DATE_SUB(latest_date, INTERVAL 1 DAY), 2
  FROM params

  UNION ALL
  SELECT 'Son Hafta', DATE_SUB(latest_date, INTERVAL 7 DAY), 3
  FROM params

  UNION ALL
  SELECT 'Son Ay', DATE_SUB(latest_date, INTERVAL 1 MONTH), 4
  FROM params

  UNION ALL
  SELECT 'Son Yıl', DATE_SUB(latest_date, INTERVAL 1 YEAR), 5
  FROM params
),

all_user_data AS (
  SELECT
    user_id,
    UPPER(status) AS status,
    subscription_plan_id,
    created_at,
    CAST(NULL AS STRING) AS payment_option
  FROM `microgain-9f959.test_dataset.elastic_user`
  WHERE user_id IS NOT NULL

  UNION ALL

  SELECT
    user_id,
    UPPER(status) AS status,
    subscription_plan_id,
    created_at,
    payment_option
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE user_id IS NOT NULL
),

user_snapshot AS (
  SELECT * EXCEPT(rn)
  FROM (
    SELECT
      p.donem,
      p.target_date,
      p.sort_order,
      a.user_id,
      a.status,
      a.subscription_plan_id,
      a.created_at,
      a.payment_option,
      ROW_NUMBER() OVER (
        PARTITION BY p.donem, a.user_id
        ORDER BY a.created_at DESC
      ) AS rn
    FROM periods p
    JOIN all_user_data a
      ON DATE(a.created_at, "Europe/Istanbul") <= p.target_date
  )
  WHERE rn = 1
),

prepaid_user_cnt AS (
  SELECT
    donem,
    target_date,
    sort_order,
    COUNT(DISTINCT user_id) AS prepaid_user_cnt
  FROM user_snapshot
  WHERE status IN ('ACTIVE','CANCELED')
    AND subscription_plan_id IS NOT NULL
    AND LOWER(payment_option) LIKE '%prepaid%'
  GROUP BY 1,2,3
),

daily_metrics AS (
  SELECT
    p.donem,
    p.target_date,
    p.sort_order,
    m.rownum,
    m.value
  FROM periods p
  JOIN `microgain-9f959.looker_report.Daily_Report_Metrics` m
    ON m.date = p.target_date
),

selected_rows_sum AS (
  SELECT
    donem,
    target_date,
    sort_order,
    SUM(value) AS selected_sum
  FROM daily_metrics
  WHERE rownum IN (8,2,5,4)
  GROUP BY 1,2,3
),

row1 AS (
  SELECT
    donem,
    target_date,
    sort_order,
    MAX(value) AS row1_value
  FROM daily_metrics
  WHERE rownum = 1
  GROUP BY 1,2,3
),

period_results AS (
  SELECT
    p.donem,
    p.target_date AS time_id,
    p.sort_order,
    r.row1_value
      - s.selected_sum
      - COALESCE(pc.prepaid_user_cnt, 0) AS Total
  FROM periods p
  LEFT JOIN row1 r
    ON p.donem = r.donem
   AND p.target_date = r.target_date
   AND p.sort_order = r.sort_order
  LEFT JOIN selected_rows_sum s
    ON p.donem = s.donem
   AND p.target_date = s.target_date
   AND p.sort_order = s.sort_order
  LEFT JOIN prepaid_user_cnt pc
    ON p.donem = pc.donem
   AND p.target_date = pc.target_date
   AND p.sort_order = pc.sort_order
),

since_result AS (
  SELECT
    'Since 01-06-2023' AS donem,
    DATE('2023-06-01') AS time_id,
    6 AS sort_order,
    value AS Total
  FROM `microgain-9f959.looker_report.Daily_Report_Metrics`
  WHERE date = DATE('2023-06-01')
    AND metric = 'Toplam Ücretli Abonelik'
)

SELECT
  donem,
  time_id,
  sort_order,
  Total
FROM period_results

UNION ALL

SELECT
  donem,
  time_id,
  sort_order,
  Total
FROM since_result