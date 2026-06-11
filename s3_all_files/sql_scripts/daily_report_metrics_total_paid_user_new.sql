INSERT `microgain-9f959.looker_report.Daily_Report_Metrics_Merged-BQ-AWS_NEW` 
With
BqData as (
SELECT
  *
FROM
  `microgain-9f959.looker_report.Daily_Report_Metrics`
WHERE date = date_sub(CURRENT_DATE("Europe/Istanbul"),Interval 1 Day)
and Title != "İptal Edilen Abonelik"
  ),
AwsData as (
SELECT
  *
FROM
  `microgain-9f959.looker_report.Daily_Report_Metrics_AWS`
WHERE date = date_sub(CURRENT_DATE("Europe/Istanbul"),Interval 1 Day)
),
TotalPaidUser as (
    select count(distinct useruuid) cnt from
  (
  SELECT * FROM `microgain-9f959.looker_report.TotalPaidUsers_AWS` where Date = current_date("Europe/Istanbul") -1 
    UNION ALL
  SELECT * FROM `microgain-9f959.looker_report.TotalPaidUsers_BQ` where Date = current_date("Europe/Istanbul") -1
  )
)
SELECT
  ifnull(ad.date,bq.date) as Date,
  ifnull(ad.metric,bq.title) as Title,
  ifnull(ad.rownum,bq.rownum) Rownum,
  CASE
    WHEN ifnull(COALESCE(ad.rownum,0),COALESCE(bq.rownum,0)) = 3 THEN (select cnt from TotalPaidUser) 
    ELSE IFNULL((COALESCE(bq.value,0) + ad.Value) ,0)
  END Value
from
  AwsData ad 
    LEFT JOIN BqData bq on bq.date = ad.Date and bq.Title = ad.Metric