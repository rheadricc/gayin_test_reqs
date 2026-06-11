create or replace table `test_dataset.guncel_premium_users` as
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
            WHERE DATE(created_At) >= '2025-02-03' and DATE(created_At) <= CURRENT_DATE("Europe/Istanbul") - 1
        ) WHERE rownum = 1
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
)
    SELECT
        --CURRENT_DATE("Europe/Istanbul") - 1 AS Date,
        DISTINCT user_id
    FROM ReportData
    where DATE(created_at) <= CURRENT_DATE("Europe/Istanbul") - 1
    --and DATE(valid_until) >= CURRENT_DATE - 1
    and status IN ('ACTIVE','CANCELED')
    and subscription_plan_id is not null