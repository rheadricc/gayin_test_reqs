
INSERT INTO `microgain-9f959.insider.insider_upsert_api_daily`
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
),
emailpermited as (
  SELECT
    *
  FROM
  (
    SELECT
      userId,
      communicationConsent.isEmailPermitted AS isEmailPermitted,
      ROW_NUMBER() OVER(PARTITION BY userId ORDER BY updatedAt  DESC) AS rownum
    FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`
  )
    WHERE rownum = 1
),
canceledusers AS 
(
  SELECT
    user_id userid,
    MAX(created_at) canceled_date
  FROM
    ReportData
  WHERE
    status = 'CANCELED'
  GROUP BY
    1
),
expiredusers AS 
(
  SELECT
    user_id userid,
    MAX(created_at) expired_date
  FROM
    ReportData
  WHERE
    status = 'EXPIRED'
  GROUP BY
    1
),
signedat as (
  SELECT
    userid,
    MAX(agr.signedAt) signedAt
  FROM
    `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`,
 UNNEST(agreements) AS agr
  GROUP BY
    1
),
baseinsiderdata as (
  SELECT DISTINCT
    a.userId AS uuid, 
    a.email AS email_address, 
    'STRING_VALUE' AS user_attribute, 
    CASE
      WHEN IFNULL(ul.status,a.subscription.status) IN ('ACTIVE','CANCELED') THEN true
      WHEN IFNULL(ul.status,a.subscription.status) IS NULL THEN null
      else false
    END subscription,
    cn.canceled_date AS cancel_request_date, 
    CASE
      WHEN DATE(freeTrialStartDate) >= CURRENT_DATE("UTC") AND CURRENT_DATE("UTC") <= DATE(freeTrialStartDate) THEN true
      ELSE false
    END free_trial, 
    ex.expired_date AS churn_date, 
    sg.signedAt AS signup_date,
    ep.isEmailPermitted,
    MAX(a.etl_date) etl_date
  FROM
  `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd` AS a
    LEFT JOIN canceledusers AS cn on a.userId = cn.userid
    LEFT JOIN expiredusers AS ex on a.userId = ex.userid
    LEFT JOIN signedat AS sg on a.userId = sg.userid
    LEFT JOIN ReportData AS ul on a.userId = ul.user_id
    LEFT JOIN emailpermited AS ep on a.userId = ep.userid
  WHERE is_current = true
    AND DATE(a.etl_date) = DATE('{{ ds }}')
  group by 1,2,3,4,5,6,7,8,9
)
SELECT
  *
FROM baseinsiderdata
 