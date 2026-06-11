Insert  `microgain-9f959.looker_report.TotalPaidUsers_BQ` 
with
 transactiontab as (SELECT
 distinct
    useruuid
  FROM
    (
      SELECT
        *
      FROM `datamarts.transaction_v2`
      WHERE userUUID not in (select distinct userUUID from `datamarts.promotions_v2`  WHERE  discountRatio > 0.9 AND code NOT LIKE "%_%D%")---Ödeme yapmayan promolar
    ) premium_users
      WHERE DATETIME_SUB(DATETIME_ADD(CAST(DATE_SUB(CURRENT_DATE("Europe/Istanbul"),INTERVAL 1 DAY) AS DATETIME), INTERVAL 1 DAY), INTERVAL 1 SECOND)
       BETWEEN DATE(CreatedAt) AND DATE(ExpiresAt)
      and CASE WHEN subscriptionType IS NULL THEN 'Monthly' ELSE subscriptionType END NOT IN ('Yearly')
 ),
 acess as(     
  SELECT
 distinct
    uuid useruuid
  FROM
    (
      SELECT
        *
      FROM `datamarts.access`
      WHERE UUID not in (select distinct userUUID from `datamarts.promotions_v2`  WHERE  discountRatio > 0.9 AND code NOT LIKE "%_%D%")---Ödeme yapmayan promolar
    ) premium_users
      WHERE DATETIME_SUB(DATETIME_ADD(CAST(DATE_SUB(CURRENT_DATE("Europe/Istanbul"),INTERVAL 1 DAY) AS DATETIME), INTERVAL 1 DAY), INTERVAL 1 SECOND)
         BETWEEN DATE(CreatedAt) AND DATE(ExpiresAt)
 )
select distinct 
    current_date("Europe/Istanbul")-1 as Date , 
    'Toplam Ücretli Abonelik' Title,
    4 rownum,
    useruuid 
    from
(
  select useruuid from transactiontab
    union all
  select useruuid from acess
)