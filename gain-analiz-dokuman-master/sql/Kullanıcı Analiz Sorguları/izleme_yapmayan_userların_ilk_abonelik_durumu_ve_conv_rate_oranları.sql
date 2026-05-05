-- abonelik oluşturup izleme yapmayanlar, segmentasyona göre, promo ile mi başlamış paid ile mi bunların aylık kırılımları ve promo isimleri vs conv rate oranları ile sql

WITH
BaseData as (
SELECT
    status,
    subscription_plan_id,
    valid_until,
    user_id,
    email,
    registered_at,
    created_at,
    grace_until,
    free_trial_start_date,
    free_trial_end_date,
    REPLACE(applied_promotions,'[]',null) AS applied_promotions
FROM `test_dataset.elastic_user`
    where date(created_at) <= '2025-02-03'
    --and free_trial_start_date = ''
    --order by 1
),
UpdateData as (
     SELECT
        *
    FROM
        (
        SELECT
            status,
            subscription_plan_id,
            valid_until,
            user_id,
            email,
            amount,
            registered_at,
            created_at,
            grace_until,
            free_trial_start_date,
            free_trial_end_date,
            ap.promotionid AS PromotionID,
            ap.applyDate AS PromotionApplyDate,
            ap.name AS PromotionName,
            ap.code AS PromotionCode,
            ap.type AS PromotionType,
            benefits.freePremiumByDay AS freePremiumByDay,
            benefits.freePremiumByMonth AS freePremiumByMonth,
            benefits.isFreePremium AS isFreePremium,
            ROW_NUMBER() OVER(PARTITION BY user_id ORDER BY created_at DESC) AS rownum
        FROM `aws_s3_to_bq_migration.subs_payment`
        LEFT JOIN UNNEST(applied_promotions) ap
        LEFT JOIN UNNEST(ap.benefits) benefits
            WHERE DATE(created_At) >= '2025-02-01' and DATE(created_At) <= CURRENT_DATE("Europe/Istanbul") - 1
        ) --WHERE rownum = 1
),
ReportData as (
SELECT
    CASE
        WHEN bd.created_at > ud.created_at THEN bd.status
        WHEN  ud.created_at is null THEN bd.status
        ELSE ud.status
    END status,
   IFNULL(bd.subscription_plan_id,ud.subscription_plan_id) subscription_plan_id,
   CASE
        WHEN bd.created_at > ud.created_at THEN bd.valid_until
        WHEN  ud.created_at is null THEN bd.valid_until
        ELSE ud.valid_until
    END valid_until,
    CASE
        WHEN bd.created_at > ud.created_at THEN bd.user_id
        WHEN  ud.created_at is null THEN bd.user_id
        ELSE ud.user_id
    END user_id,
    CASE
        WHEN bd.created_at > ud.created_at THEN bd.email
        WHEN  ud.created_at is null THEN bd.email
        ELSE ud.email
    END email,
    CASE
        WHEN bd.created_at > ud.created_at THEN bd.registered_at
        WHEN  ud.created_at is null THEN bd.registered_at
        ELSE ud.registered_at
    END registered_at,
    CASE
        WHEN bd.created_at > ud.created_at THEN bd.created_at
        WHEN  ud.created_at is null THEN bd.created_at
        ELSE ud.created_at
    END created_at,
    CASE
        WHEN bd.created_at > ud.created_at THEN bd.grace_until
        WHEN  ud.created_at is null THEN bd.grace_until
        ELSE ud.grace_until
    END grace_until,
    CASE
        WHEN bd.created_at > ud.created_at THEN bd.free_trial_start_date
        WHEN  ud.created_at is null THEN bd.free_trial_start_date
        ELSE ud.free_trial_start_date
    END free_trial_start_date,
    CASE
        WHEN bd.created_at > ud.created_at THEN bd.free_trial_end_date
        WHEN  ud.created_at is null THEN bd.free_trial_end_date
        ELSE ud.free_trial_end_date
    END free_trial_end_date,
    CASE
        WHEN bd.created_at > ud.created_at THEN bd.applied_promotions
        WHEN  ud.created_at is null THEN bd.applied_promotions
        ELSE ud.PromotionID
    END applied_promotions,
    PromotionApplyDate,
    freePremiumByDay,
    PromotionID,
    ud.amount
FROM BaseData bd
    FULL JOIN UpdateData ud ON bd.user_id = ud.user_id
),
allusers as (
    SELECT
      distinct user_id,
      date_trunc(DATE(created_at),month) AS paid_month
    from ReportData
    where status = 'ACTIVE'
    AND DATE(created_at) >= '2024-01-01'
    --and user_id = 'ffff2bc7-1bad-4a87-8e8d-47fd0a42d10b'
),
eskipayment as (
  select 
    distinct useruuid,
    date_trunc(date(createdat), month) eskipaymentdate
  from `datamarts.transaction_v2`
  where useruuid is not null and DATE(createdAt) >= '2024-01-01' and DATE(access_created_at) >= '2024-01-01' --and useruuid = '411e703b-cded-4563-8da3-848edecbd929'
),
promotions AS (
  SELECT
    user_id,
    DATE(promo_pay_date) AS promo_date,
    DATE_TRUNC(DATE(promo_pay_date), MONTH) AS promo_month,
    promo_name,
    'promo' AS payment_type
  FROM `microgain-9f959.test_dataset.promo_kullanım_20250203`

  UNION ALL

  SELECT
    userUUID AS user_id,
    DATE(createdAt) AS promo_date,
    DATE_TRUNC(DATE(createdAt), MONTH) AS promo_month,
    name AS promo_name,
    'promo' AS payment_type
  FROM `microgain-9f959.datamarts.promotions_v2`
),
monthly_payments AS (
  SELECT DISTINCT
    user_id,
    DATE(created_at) AS pay_date,
    DATE_TRUNC(DATE(created_at), MONTH) AS paid_month,
    'paid' AS payment_type
  FROM ReportData
  WHERE status = 'ACTIVE'
    AND IFNULL(amount, 0) > 100
    AND DATE(created_at) BETWEEN DATE('2024-01-01') AND DATE('2025-07-31')
  
  UNION ALL

  SELECT DISTINCT
    useruuid AS user_id,
    DATE(createdAt) AS pay_date,
    DATE_TRUNC(DATE(createdAt), MONTH) AS paid_month,
    'paid' AS payment_type
  FROM `datamarts.transaction_v2`
  WHERE useruuid IS NOT NULL
    AND SAFE_CAST(price AS INT64) > 1
    AND DATE(createdAt) BETWEEN DATE('2024-01-01') AND DATE('2025-07-31')
    AND DATE(access_created_at) >= DATE('2024-01-01')
),
payment_and_promotions AS (
  SELECT 
    user_id,
    pay_date AS event_date,
    paid_month AS event_month,
    NULL AS promo_name,
    payment_type
  FROM monthly_payments

  UNION ALL

  SELECT
    user_id,
    promo_date AS event_date,
    promo_month AS event_month,
    promo_name,
    payment_type
  FROM promotions
),
calendar AS (
  SELECT DATE_TRUNC(DATE '2024-01-01' + INTERVAL m MONTH, MONTH) AS month
  FROM UNNEST(GENERATE_ARRAY(0, TIMESTAMP_DIFF(DATE '2025-07-01', DATE '2024-01-01', MONTH))) AS m
),
target_users AS (
  SELECT user_id
  FROM `test_dataset.payment_watch_dropoff_scd`
  WHERE dropoff_typepe = 'never_watched'
),
calendar_expanded AS (
  SELECT
    u.user_id,
    c.month
  FROM target_users u
  CROSS JOIN calendar c
),
filtered_payments AS (
  SELECT DISTINCT user_id, event_month, promo_name
  FROM payment_and_promotions 
),
missing_month_count as (
  SELECT
    ce.user_id,
    COUNTIF(fp.promo_name is null) AS paid_months_count,
    fp.promo_name
  FROM calendar_expanded ce
  JOIN filtered_payments fp
    ON ce.user_id = fp.user_id AND ce.month = fp.event_month
  WHERE fp.event_month IS NOT NULL
  GROUP BY ce.user_id, fp.promo_name
),
base_output as(
SELECT
  user_id,
  event_month,
  event_date,
  payment_type,
  promo_name
FROM payment_and_promotions
WHERE event_month BETWEEN '2024-01-01' AND '2025-07-01'
  AND user_id IN (
    SELECT user_id FROM `test_dataset.payment_watch_dropoff_scd`
    WHERE dropoff_typepe = 'never_watched' --and user_id = '000024f9-ab87-449f-8cc8-3dbc91d9b927'
)
ORDER BY user_id, event_date
),

summary_table as(
SELECT
  user_id,
  COUNTIF(payment_type = 'promo' AND promo_name = 'freetrial') AS freetrial_count,
  COUNTIF(payment_type = 'paid') AS paid_count,
  COUNTIF(payment_type = 'promo' AND promo_name = 'freetrial') > 0 AND 
  COUNTIF(payment_type = 'paid') > 0 AS freetrial_to_paid
FROM base_output
GROUP BY user_id),


year_diff as(
SELECT
  EXTRACT(YEAR FROM bo.event_month) AS year,
  bo.promo_name,
  COUNT(DISTINCT bo.user_id) AS promo_users,
  COUNT(DISTINCT CASE WHEN s.paid_count > 0 THEN bo.user_id END) AS converted_users,
  ROUND(
    COUNT(DISTINCT CASE WHEN s.paid_count > 0 THEN bo.user_id END) /
    COUNT(DISTINCT bo.user_id), 4
  ) AS conversion_rate
FROM base_output bo
JOIN summary_table s
  ON bo.user_id = s.user_id
WHERE bo.payment_type = 'promo'
GROUP BY year, bo.promo_name
ORDER BY year, conversion_rate DESC),

converted_users_2024 AS (
  SELECT DISTINCT bo.user_id
  FROM base_output bo
  JOIN summary_table s
    ON bo.user_id = s.user_id
  WHERE bo.payment_type = 'promo'
    AND promo_name != 'freetrial'
    AND s.paid_count > 0
    AND EXTRACT(YEAR FROM bo.event_month) = 2025
)
SELECT DISTINCT p.user_id
FROM `test_dataset.premium_users_20250729` p
JOIN converted_users_2024 c
  ON p.user_id = c.user_id
ORDER BY p.user_id;





-- ilgli promoya göre aylık conv rate hesaplama
SELECT
  FORMAT_DATE('%Y-%m', bo.event_month) AS month,
  bo.promo_name,
  COUNT(DISTINCT bo.user_id) AS promo_users,
  COUNT(DISTINCT CASE WHEN s.paid_count > 0 THEN bo.user_id END) AS converted_users,
  ROUND(
    COUNT(DISTINCT CASE WHEN s.paid_count > 0 THEN bo.user_id END) /
    COUNT(DISTINCT bo.user_id), 4
  ) AS conversion_rate
FROM base_output bo
JOIN summary_table s
  ON bo.user_id = s.user_id
WHERE bo.payment_type = 'promo'
  AND bo.promo_name IN ('1 hafta premium')--, '1 Ay Premium')
GROUP BY month, bo.promo_name
ORDER BY month, bo.promo_name;








-- full promo aylık conv rate hesaplama
SELECT
  bo.promo_name,
  COUNT(DISTINCT bo.user_id) AS promo_users,
  COUNT(DISTINCT CASE WHEN s.paid_count > 0 THEN bo.user_id END) AS converted_users,
  ROUND(
    COUNT(DISTINCT CASE WHEN s.paid_count > 0 THEN bo.user_id END) /
    COUNT(DISTINCT bo.user_id), 4
  ) AS conversion_rate
FROM base_output bo
JOIN summary_table s
  ON bo.user_id = s.user_id
WHERE bo.payment_type = 'promo'
GROUP BY bo.promo_name
ORDER BY conversion_rate DESC;


