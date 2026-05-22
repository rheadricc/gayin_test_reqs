-- SCHEDULED QUERY
-- Name: Daily_Report_Metrics_Yesterday_Insert
-- Schedule: Daily 21:01 UTC

--CREATE OR REPLACE TABLE `microgain-9f959.looker_report.Daily_Report_Metrics` AS
INSERT INTO `microgain-9f959.looker_report.Daily_Report_Metrics`
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
NewUsers as (
    ---Yanlış mantık hatası signup düşmüyor bize
    SELECT
        CURRENT_DATE("Europe/Istanbul") - 1 AS Date,
        0 /*count(DISTINCT user_id)*/ NewUserCount
    --FROM BaseData
    --where DATE(registered_At) = CURRENT_DATE - 1
   -- and DATE(created_At) = CURRENT_DATE - 1
),
NewSales as
(
    SELECT
        CURRENT_DATE("Europe/Istanbul") - 1 AS Date,
        count(DISTINCT user_id) NewSalesCount
    FROM ReportData
    where DATE(created_at) = CURRENT_DATE("Europe/Istanbul") - 1
    --and DATE(registered_At) = CURRENT_DATE - 1
    and status = 'ACTIVE'
    and subscription_plan_id is not null
),
CanceledUsers as
(
    SELECT
        CURRENT_DATE("Europe/Istanbul") - 1 AS Date,
        count(DISTINCT user_id) CanceledCount
    FROM ReportData
        where DATE(created_at) = CURRENT_DATE("Europe/Istanbul") - 1
            and status IN ('EXPIRED','ON_HOLD')
),
TotalPaidUsers as
(
    SELECT
        CURRENT_DATE("Europe/Istanbul") - 1 AS Date,
        count(DISTINCT user_id)  TotalPaidUserCount
    FROM ReportData
    where DATE(created_at) <= CURRENT_DATE("Europe/Istanbul") - 1
    --and DATE(valid_until) >= CURRENT_DATE - 1
    and status IN ('ACTIVE','CANCELED')
    and subscription_plan_id is not null
),
GraceUsers as
(
    SELECT
        CURRENT_DATE("Europe/Istanbul") - 1 AS Date,
        count(DISTINCT user_id) GraceUserCount
    FROM ReportData
    where DATE(grace_until) >= CURRENT_DATE("Europe/Istanbul") - 1
        and status = 'IN_GRACE'
        and subscription_plan_id is not null
),
SevenDaysTrialUsage as
(
select
        CURRENT_DATE("Europe/Istanbul") - 1 AS Date,
        count(DISTINCT user_id) AS SevenDaysTrialUsage,
    FROM ReportData
        where date(created_at) = CURRENT_DATE("Europe/Istanbul") - 1
            and date(free_trial_start_date) = CURRENT_DATE("Europe/Istanbul") - 1
            and date_diff(date(valid_until), date(free_trial_start_date), DAY) = 7
            and status = 'ACTIVE'
),
SevenDaysTrialContinue as
(
    SELECT
        CURRENT_DATE("Europe/Istanbul") - 1 as Date,
        COUNT(DISTINCT user_id) SevenDaysTrialContinue
    FROM ReportData
        where CURRENT_DATE("Europe/Istanbul") - 1 <= DATE(valid_until)
            and CURRENT_DATE("Europe/Istanbul") - 1 >= date(free_trial_start_date) and CURRENT_DATE("Europe/Istanbul") - 1 <= date(free_trial_end_date)
            and date_diff(date(valid_until), date(free_trial_start_date), DAY) = 7
),
SevenDaysPromoUsage as
(
SELECT
        CURRENT_DATE("Europe/Istanbul") - 1 as DATE,
        COUNT(DISTINCT user_id) SevenDaysPromoUsage
    FROM ReportData
where status = 'ACTIVE'
    and DATE(PromotionApplyDate) = CURRENT_DATE("Europe/Istanbul") - 1
    and freePremiumByDay = 7
),
SevenDaysPromoContinue as
(
    SELECT
        CURRENT_DATE("Europe/Istanbul") - 1 as Date,
        COUNT(DISTINCT user_id) SevenDaysPromoContinue
    FROM ReportData
where --status = 'ACTIVE' and
    DATE_ADD(DATE(PromotionApplyDate), INTERVAL 7 DAY) >= CURRENT_DATE("Europe/Istanbul") - 1
    and freePremiumByDay = 7
),
AbonelikSatinAlan as
(
    SELECT
        CURRENT_DATE("Europe/Istanbul") - 1 as Date,
        COUNT(DISTINCT user_id) AbonelikSatinAlan
    FROM ReportData
        where date(created_at) >= CURRENT_DATE("Europe/Istanbul") - 8 and DATE(created_at) <= CURRENT_DATE("Europe/Istanbul") - 1
        and status = 'ACTIVE'
),
TotalPromoUsers as
(
    SELECT
        CURRENT_DATE("Europe/Istanbul") - 1 AS Date,
        count(DISTINCT user_id)  TotalPromoUsers
    FROM ReportData
    where DATE(created_at) <= CURRENT_DATE("Europe/Istanbul") - 1
    --and DATE(valid_until) >= CURRENT_DATE - 1
    and status IN ('ACTIVE','CANCELED')
    and subscription_plan_id is not null
    and PromotionID IS NOT NULL
)
,
PvtData as
(
SELECT
    date,
    'Yeni Kayıt Yapan' AS metric,
    0 as rownum,
    newusercount AS value
FROM NewUsers
    UNION ALL
SELECT
    date,
    'Yeni Abonelik Satın Alan' AS metric,
    3 as rownum,
    newsalescount AS value
FROM NewSales
    UNION ALL
SELECT
    date,
    'İptal Edilen Abonelik' AS metric,
    4 as rownum,
    canceledcount AS value
FROM CanceledUsers
    UNION ALL
SELECT
    date,
    'Toplam Ücretli Abonelik' AS metric,
    1 as rownum,
    totalpaidusercount AS value
FROM TotalPaidUsers
    UNION ALL
SELECT
    date,
    'Grace Period Sürecindeki Kullanıcılar' AS metric,
    5 as rownum,
    graceusercount AS value
FROM GraceUsers
    UNION ALL
SELECT
    date,
    '7 Günlük Ücretsiz Deneme Kullanımı' AS metric,
    6 as rownum,
    a.SevenDaysTrialUsage AS value
FROM SevenDaysTrialUsage a
    UNION ALL
SELECT
    date,
    '7 Günlük Promosyon Kullanımı' AS metric,
    7 as rownum,
    a.SevenDaysPromoUsage AS value
FROM SevenDaysPromoUsage a
    UNION ALL
SELECT
    date,
    '7 Günlük Ücretsiz Deneme Devam Edenler' AS metric,
    8 as rownum,
    a.SevenDaysTrialContinue AS value
FROM SevenDaysTrialContinue a
    UNION ALL
SELECT
    date,
    '7 Günlük Promosyon Devam Eden' AS metric,
    9 as rownum,
    a.SevenDaysPromoContinue AS value
FROM SevenDaysPromoContinue a
    UNION ALL
SELECT
    date,
    'Son 1 Haftada Abonelik Satın Alan' AS metric,
    10 as rownum,
    a.AbonelikSatinAlan AS value
FROM AbonelikSatinAlan a
    UNION ALL
SELECT
    date,
    'Promosyon Kullanmış Ücretli Abone' AS metric,
    2 as rownum,
    a.TotalPromoUsers AS value
FROM TotalPromoUsers a
)
    SELECT * FROM pvtdata
    where rownum != 0 order by rownum