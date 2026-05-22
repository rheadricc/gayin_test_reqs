-- SCHEDULED QUERY
-- Name: Daily_Report_Metrics
-- Schedule: Daily 06:00 UTC

INSERT INTO `microgain-9f959.looker_report.Daily_Report_Metrics`
WITH original_data AS (
    SELECT
        date(date) date,
        payment_type_totals_Apple AS Apple,
        payment_type_totals_Google AS Google,
        payment_type_totals_iyzico AS iyzico,
        payment_type_totals_payguru AS payguru,
        all_user AS all_user,
        event_count AS event_count,
        total_churn_sum AS total_churn_sum,
        promo_gain_hediye AS promo_gain_hediye,
        promo_gain_kampanyasi AS promo_gain_kampanyasi,
        promo_marka_isbirligi AS promo_marka_isbirligi,
        promo_prepaid AS promo_prepaid
    FROM `looker_report.daily_report_data`
    where date(date) = date_sub(current_date("Europe/Istanbul"),Interval 1 Day)
    --date_sub(current_date("Europe/Istanbul"),INTERVAL 1 DAY)
),
finaltab as (
SELECT
    date,
    case
        when metric = 'event_count' then 'Yeni Üyelik Kaydı'
        when metric = 'iyzico' then 'Yeni Abonelik Satışı'
        when metric = 'Apple' then 'Yeni Abonelik Satışı'
        when metric = 'Google' then 'Yeni Abonelik Satışı'
        when metric = 'payguru' then 'Yeni Abonelik Satışı'
        when metric = 'all_user' then 'Yeni Ziyaretçi'
        when metric = 'total_churn_sum' then 'Churn (İptal)'
        when metric = 'promo_gain_hediye' then 'Toplam Promo Katılım'
        when metric = 'promo_prepaid' then 'Toplam Promo Katılım'
        when metric = 'promo_gain_kampanyasi' then 'Toplam Promo Katılım'
        when metric = 'promo_marka_isbirligi' then 'Toplam Promo Katılım'
    end category,
    case
        when metric = 'event_count' then 'Yeni Üyelik Kaydı'
        when metric = 'iyzico' then 'Kredi Kartı'
        when metric = 'Apple' then 'Apple'
        when metric = 'Google' then 'Google'
        when metric = 'payguru' then 'Mobil Ödeme'
        when metric = 'all_user' then 'Yeni Ziyaretçi'
        when metric = 'total_churn_sum' then 'Churn (İptal)'
        when metric = 'promo_gain_hediye' then 'Others'
        when metric = 'promo_prepaid' then 'Others'
        when metric = 'promo_gain_kampanyasi' then '7 Gün Ücretsiz'
        when metric = 'promo_marka_isbirligi' then 'İş Ortakları'
    end sub_category,
    metric,
    value
FROM
    original_data
UNPIVOT (
    value FOR metric IN (
        Apple,
        Google,
        iyzico,
        payguru,
        all_user,
        event_count,
        total_churn_sum,
        promo_gain_hediye,
        promo_gain_kampanyasi,
        promo_marka_isbirligi,
        promo_prepaid
    )
)
ORDER BY date
),
firstday as (
    /*SELECT date_sub(current_date("Europe/Istanbul"),Interval 1 Day) AS time_id,
      'Toplam Ücretli Abonelik' Title,
          COUNT(DISTINCT Id) AS Total
    FROM
      (SELECT *
      FROM `microgain-9f959.datamarts.access`
      WHERE ItemAccessId NOT IN
          (SELECT ItemAccessId
            FROM `microgain-9f959.datamarts.tmp_access_id`)) base
    WHERE EXISTS
        (SELECT *
        FROM
          (SELECT *
            FROM `microgain-9f959.datamarts.access`
            WHERE ItemAccessId NOT IN
                (SELECT ItemAccessId
                FROM `microgain-9f959.datamarts.tmp_access_id`)) premium_users
        WHERE base.Id = premium_users.Id
          AND DATETIME_SUB(DATETIME_ADD(CAST(DATE_SUB(current_date("Europe/Istanbul"),INTERVAL 1 DAY) AS DATETIME), INTERVAL 1 DAY), INTERVAL 1 SECOND) BETWEEN DATETIME(CreatedAt, 'Europe/Istanbul') AND DATETIME(ExpiresAt, 'Europe/Istanbul'))
          AND ItemAccessId NOT IN (select accessId
    FROM
    (SELECT
                            accessId,
                      CASE WHEN subscriptionType IS NULL THEN 'Monthly' ELSE subscriptionType END as subscriptionType
                    FROM `datamarts.transaction_v2`
    )
    WHERE subscriptionType = "Yearly")*/
    SELECT
    CAST(DATE_SUB(CURRENT_DATE("Europe/Istanbul"),INTERVAL 1 DAY) AS STRING) AS time_id,
    count(distinct userId) AS Total
  FROM
    (
      SELECT
        *
      FROM `datamarts.transaction_v2`
        WHERE --price > 1
          userid not in (select distinct userid from `datamarts.promotions_v2`  WHERE  discountRatio > 0.9 AND code NOT LIKE "%_%D%")---Ödeme yapmayan promolar
    ) premium_users
      WHERE --'2024-12-08 23:59:59'
        DATETIME_SUB(DATETIME_ADD(CAST(DATE_SUB(CURRENT_DATE("Europe/Istanbul"),INTERVAL 1 DAY) AS DATETIME), INTERVAL 1 DAY), INTERVAL 1 SECOND)
            BETWEEN DATETIME(CreatedAt, 'Europe/Istanbul') AND DATETIME(ExpiresAt, 'Europe/Istanbul')
            and CASE WHEN subscriptionType IS NULL THEN 'Monthly' ELSE subscriptionType END NOT IN ('Yearly')
),
alldata as  
(
  select
    date,
    case 
      when metric in ('event_count') then 'Yeni Kayıt Yapan'
      when metric in ('Apple','Google','iyzico','payguru') then 'Yeni Abonelik Satın Alan'
      when metric in ('total_churn_sum') then 'İptal Edilen Abonelik'
      when metric in ('promo_gain_kampanyasi') then '7 Günlük Promosyon Kullanımı'
      else 'Other'
    end Title,
    case 
      when metric in ('event_count') then 0
      when metric in ('Apple','Google','iyzico','payguru') then 2
      when metric in ('total_churn_sum') then 3
      when metric in ('promo_gain_kampanyasi') then 7
      else 0
    end RowNum,
    sum(value) value
  from finaltab
    group by 1,2,3
    UNION ALL
  SELECT 
    date_sub(current_date("Europe/Istanbul"),INTERVAL 1 DAY) time_id,
    'Toplam Ücretli Abonelik' title,
    4 rownum,
    COALESCE(SUM(total), 0) AS value
  FROM
  (
    SELECT 
      total
    FROM firstday
  )
    UNION ALL
  SELECT 
    date_sub(current_date("Europe/Istanbul"),INTERVAL 1 DAY) time_id, 
    'Yeni Kayıt Yapan' Title,
    1 Rownum,
    COALESCE(SUM(value), 0) AS value
  FROM
  (
    SELECT 
      Count(id) value  
  FROM `microgain-9f959.datamarts.audience` 
    where date(createdat) = date_sub(current_date("Europe/Istanbul"),INTERVAL 1 DAY)
  )
    UNION ALL
  SELECT 
    date_sub(current_date("Europe/Istanbul"),INTERVAL 1 DAY) time_id,
    'Grace Period Sürecindeki Kullanıcılar' Title,
    5 rownum,
    COALESCE(SUM(value), 0) AS value
  FROM
  (
    SELECT 
      COUNT(DISTINCT userId) as value --*--userId, createdAt, originalExpireDate, expireDate
    FROM `microgain-9f959.datamarts.transaction_graceperiod`
    WHERE originalExpireDate IS NOT NULL  
            AND DATETIME_SUB(DATE_TRUNC(CURRENT_DATETIME('Europe/Istanbul'), DAY), INTERVAL 1 SECOND)
    BETWEEN DATETIME(originalExpireDate, 'Europe/Istanbul')
            AND DATETIME(expireDate, 'Europe/Istanbul')-- And paymentTransactionID != "dummy"
  )
    UNION ALL
  SELECT 
    date_sub(current_date("Europe/Istanbul"), INTERVAL 1 DAY) AS time_id,
    '15 Günlük Promosyon Kullanımı' AS Title,
    9 AS RowNum,
    COALESCE(SUM(value), 0) AS value
  FROM
  (
    SELECT 
    COALESCE(count(user_id),0) value
  FROM `microgain-9f959.looker_report.Promotion_Conversion` pr
    LEFT JOIN  `microgain-9f959.looker_report.promo_legend` pl on pr.promo_name = pl.promo_name
  where premium_status in ('Promo-New')
    and time_id = date_sub(current_date("Europe/Istanbul"),Interval 1 Day)
    and pl.kurgu = '15 Gün Ücretsiz'
  )
    UNION ALL
   SELECT 
    date_sub(current_date("Europe/Istanbul"),INTERVAL 1 DAY) time_id,
    '15 Günlük Premium Devam Edenler' Title,
    8 rownum,
    COALESCE(SUM(value), 0) AS value
  FROM
  (
    SELECT 
      COUNT(DISTINCT Id) as value
    FROM
      (
        SELECT 
          DISTINCT userId as Id --*--userId, createdAt, originalExpireDate, expireDate
        FROM `microgain-9f959.datamarts.transaction_graceperiod`
            WHERE originalExpireDate IS NOT NULL
                  AND DATETIME_SUB(DATE_TRUNC(CURRENT_DATETIME('Europe/Istanbul'), DAY), INTERVAL 1 SECOND)
        BETWEEN DATETIME(originalExpireDate, 'Europe/Istanbul') AND DATETIME(expireDate, 'Europe/Istanbul')
                And paymentTransactionID = "dummy" 
                AND LOWER(promotion) IN ("15 gün premium")
        UNION ALL
      SELECT 
        DISTINCT userId as Id 
      FROM `microgain-9f959.datamarts.promotions_v2`
        WHERE DATETIME_SUB(DATE_TRUNC(CURRENT_DATETIME('Europe/Istanbul'), DAY), INTERVAL 1 SECOND)
        BETWEEN DATETIME(createdAt, 'Europe/Istanbul') AND DATETIME(expiryDate, 'Europe/Istanbul')
          AND name = "15 gün premium" 
          AND promotionCode = "ASKADASI"
    )
  )  
    UNION ALL
     SELECT 
    date_sub(current_date("Europe/Istanbul"),INTERVAL 1 DAY) time_id,
    '7 Günlük Premium Devam Edenler' Title,
    6 rownum,
    COALESCE(SUM(value), 0) AS value
  FROM
  (
    SELECT 
      COUNT(DISTINCT Id) as value
    FROM
      (
        SELECT 
          DISTINCT userId as Id --*--userId, createdAt, originalExpireDate, expireDate
        FROM `microgain-9f959.datamarts.transaction_graceperiod`
            WHERE originalExpireDate IS NOT NULL
                  AND DATETIME_SUB(DATE_TRUNC(CURRENT_DATETIME('Europe/Istanbul'), DAY), INTERVAL 1 SECOND)
        BETWEEN DATETIME(originalExpireDate, 'Europe/Istanbul') AND DATETIME(expireDate, 'Europe/Istanbul')
                And paymentTransactionID = "dummy" 
                AND LOWER(promotion) IN ("1 hafta premium")
        UNION ALL
      SELECT 
        DISTINCT userId as Id 
      FROM `microgain-9f959.datamarts.promotions_v2`
        WHERE DATETIME_SUB(DATE_TRUNC(CURRENT_DATETIME('Europe/Istanbul'), DAY), INTERVAL 1 SECOND)
        BETWEEN DATETIME(createdAt, 'Europe/Istanbul') AND DATETIME(expiryDate, 'Europe/Istanbul')
          AND name = "1 hafta premium" 
          --AND promotionCode = "ASKADASI"
    )
  )  
)
  select * from alldata
    where rownum != 0
    order by rownum
