INSERT INTO `microgain-9f959.looker_report.Daily_Report_Metrics_Merged-BQ-AWS`
With
BqData as (
SELECT
  *
FROM
  `microgain-9f959.looker_report.Daily_Report_Metrics`
WHERE
  date = date_sub(CURRENT_DATE("Europe/Istanbul"),Interval 1 Day)
  ),
AwsData as (
SELECT
  *
FROM
  `microgain-9f959.looker_report.Daily_Report_Metrics_AWS`
WHERE
  date = date_sub(CURRENT_DATE("Europe/Istanbul"),Interval 1 Day)
)
SELECT
  ifnull(bq.date,ad.date) as Date,
  ifnull(bq.title,ad.metric) as Title,
  ifnull(bq.rownum,ad.rownum) Rownum,
  (bq.value + ad.Value) as Value
from
  BqData bq
    FULL JOIN AwsData ad on bq.date = ad.Date and bq.Title = ad.Metric