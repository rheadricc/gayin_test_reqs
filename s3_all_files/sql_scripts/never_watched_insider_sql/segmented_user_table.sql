CREATE OR REPLACE TABLE `test_dataset.payment_watch_dropoff_scd` AS
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
    PromotionID
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
  where useruuid is not null and createdAt >= '2024-01-01' and access_created_at >= '2024-01-01'
),
monthly_payments as (
  select
    *
  from allusers WHERE paid_month >= '2024-01-01'
    UNION ALL
  select
    *
  from eskipayment
),
monthly_watches AS (
  SELECT
    distinct user_id,
    DATE_TRUNC(event_date, MONTH) AS watch_month
  FROM `microgain-9f959.looker_report.content_report_streaming_V2`
  WHERE event_date >= '2024-01-01' --and user_id = '30e14d2b-b85c-4208-a4c5-5c8766f34249'
),

payment_watch_status AS (
  SELECT
    distinct p.user_id,
    p.paid_month,
    IF(w.user_id IS NOT NULL, TRUE, FALSE) AS watched
  FROM monthly_payments p
  LEFT JOIN monthly_watches w
    ON p.user_id = w.user_id AND p.paid_month <= w.watch_month
),

ranked_behavior AS (
  SELECT
    user_id,
    paid_month,
    watched,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY paid_month) AS month_order
  FROM payment_watch_status
),

last_watch_months AS (
  SELECT user_id, ifnull(MAX(paid_month), '1900-01-01') AS last_watch_month
  FROM payment_watch_status
  WHERE watched = TRUE
  GROUP BY user_id
),

first_watch_months AS (
  SELECT user_id, ifnull(MIN(paid_month), '1900-01-01') AS first_watch_month
  FROM payment_watch_status
  WHERE watched = TRUE
  GROUP BY user_id
),

post_watch_behavior AS (
  SELECT
    r.*,
    ifnull(lw.last_watch_month, '1900-01-01') as last_watch_month,
    ifnull(fw.first_watch_month, '1900-01-01') as first_watch_month,
    DATE_DIFF(r.paid_month, lw.last_watch_month, MONTH) AS months_after_last_watch
  FROM ranked_behavior r
  LEFT JOIN last_watch_months lw ON r.user_id = lw.user_id
  LEFT JOIN first_watch_months fw ON r.user_id = fw.user_id
  WHERE r.paid_month > ifnull(lw.last_watch_month, '1900-01-01') 
),

first_paid_months AS (
  SELECT user_id, ifnull(MIN(paid_month), '1900-01-01') AS first_paid_month
  FROM monthly_payments
  GROUP BY user_id
),

final_summary AS (
  SELECT
    pwb.user_id,
    pwb.last_watch_month,
    pwb.first_watch_month,
    COUNTIF(watched = FALSE) AS months_paid_but_not_watched,
    MAX(paid_month) AS last_paid_month,
    fpm.first_paid_month,
    if(last_watch_month = '1900-01-01', null, DATE_DIFF(MAX(paid_month), MAX(last_watch_month), MONTH)) AS months_after_watch
  FROM post_watch_behavior pwb
  left join first_paid_months fpm using(user_id) 
  GROUP BY user_id, last_watch_month,first_watch_month, first_paid_month
),
calendar AS (
  SELECT DATE_TRUNC(DATE '2024-01-01' + INTERVAL m MONTH, MONTH) AS month
  FROM UNNEST(GENERATE_ARRAY(0, TIMESTAMP_DIFF(DATE '2025-07-01', DATE '2024-01-01', MONTH))) AS m
),
target_users AS (
  SELECT user_id
  FROM final_summary
  
),
calendar_expanded AS (
  SELECT
    u.user_id,
    c.month
  FROM target_users u
  CROSS JOIN calendar c
),
filtered_payments AS (
  SELECT DISTINCT user_id, paid_month
  FROM monthly_payments
),
paid_month_count as(
SELECT
  ce.user_id,
  COUNT(*) AS paid_months_count
FROM calendar_expanded ce
LEFT JOIN filtered_payments fp
  ON ce.user_id = fp.user_id AND ce.month = fp.paid_month
WHERE fp.paid_month IS not NULL
GROUP BY ce.user_id 
ORDER BY paid_months_count DESC
) 

SELECT
  fs.*,
CASE
  -- Kullanıcı hiç izleme yapmamışsa (2024 ve sonrası için)
  WHEN last_watch_month = '1900-01-01' THEN 'never_watched'
  
  -- İzlemeyi bıraktıktan sonra en az 4 ay boyunca ödeme yapmaya devam eden kullanıcı
  WHEN months_after_watch >= 4 THEN 'long_after_watch'
  
  -- İzlemeyi bıraktıktan sonra tam 3 ay ödeme yapmış kullanıcı
  WHEN months_after_watch = 3 THEN 'exactly_3_months_gap'
  
  -- İzlemeyi bıraktıktan sonra tam 2 ay ödeme yapmış kullanıcı
  WHEN months_after_watch = 2 THEN 'exactly_2_months_gap'
  
  -- İzlemeyi bıraktıktan sonra sadece 1 ay ödeme yapmış kullanıcı
  WHEN months_after_watch = 1 AND months_paid_but_not_watched = 1 THEN 'abandoned_after_1_paid'
  
  -- Yukarıdaki kurallara uymayanlar
  ELSE 'other_uncategorized'
END AS dropoff_typepe, pmc.paid_months_count
FROM final_summary fs
left join paid_month_count pmc on fs.user_id = pmc.user_id