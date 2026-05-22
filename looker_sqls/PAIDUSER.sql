-- =========================
-- 1️⃣ PREPAID USER HESABI
-- =========================
WITH BaseData AS (
  SELECT
    UPPER(status) AS status,
    subscription_plan_id,
    user_id,
    created_at
  FROM `microgain-9f959.test_dataset.elastic_user`
  WHERE user_id IS NOT NULL
    AND DATE(created_at, "Europe/Istanbul") <= DATE('2025-02-03')
),

UpdateData AS (
  SELECT * EXCEPT(rn)
  FROM (
    SELECT
      UPPER(status) AS status,
      subscription_plan_id,
      user_id,
      created_at,
      payment_option,
      ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) AS rn
    FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
    WHERE user_id IS NOT NULL
      AND DATE(created_at, "Europe/Istanbul") > DATE('2025-02-03')
      AND DATE(created_at, "Europe/Istanbul") <= DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 1 DAY)
  )
  WHERE rn = 1
),

ReportData AS (
  SELECT
    COALESCE(bd.user_id, ud.user_id) AS user_id,
    CASE
      WHEN ud.created_at IS NULL THEN bd.status
      WHEN bd.created_at IS NULL THEN ud.status
      WHEN bd.created_at > ud.created_at THEN bd.status
      ELSE ud.status
    END AS status,
    COALESCE(bd.subscription_plan_id, ud.subscription_plan_id) AS subscription_plan_id,
    CASE
      WHEN ud.created_at IS NULL THEN bd.created_at
      WHEN bd.created_at IS NULL THEN ud.created_at
      WHEN bd.created_at > ud.created_at THEN bd.created_at
      ELSE ud.created_at
    END AS created_at,
    CASE
      WHEN bd.created_at > ud.created_at OR ud.created_at IS NULL THEN NULL
      ELSE ud.payment_option
    END AS payment_option
  FROM BaseData bd
  FULL JOIN UpdateData ud
    ON bd.user_id = ud.user_id
),

prepaid_user_cnt AS (
  SELECT
    COUNT(DISTINCT user_id) AS prepaid_user_cnt
  FROM ReportData
  WHERE DATE(created_at, "Europe/Istanbul") <= DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 1 DAY)
    AND status IN ('ACTIVE','CANCELED')
    AND subscription_plan_id IS NOT NULL
    AND LOWER(payment_option) LIKE '%prepaid%'
),

-- =========================
-- 2️⃣ DÜNÜN METRİKLERİ
-- =========================
yesterday AS (
  SELECT *
  FROM `microgain-9f959.looker_report.Daily_Report_Metrics`
  WHERE date = DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 1 DAY)
),

-- rownum 8,2,5,4 toplamı
selected_rows_sum AS (
  SELECT SUM(value) AS selected_sum
  FROM yesterday
  WHERE rownum IN (8,2,5,4)
),

-- rownum = 1 değeri
row1 AS (
  SELECT value AS row1_value
  FROM yesterday
  WHERE rownum = 1
)

-- =========================
-- 3️⃣ SONUÇ
-- =========================
SELECT
  r.row1_value
    - s.selected_sum
    - p.prepaid_user_cnt AS final_result
FROM row1 r
CROSS JOIN selected_rows_sum s
CROSS JOIN prepaid_user_cnt p;