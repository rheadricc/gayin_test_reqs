WITH
firstday AS (
  SELECT
    CAST(DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 1 DAY) AS STRING) AS time_id,
    value AS Total
  FROM `microgain-9f959.looker_report.Daily_Report_Metrics`
  WHERE date = DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 1 DAY)
    AND metric = 'Toplam Ücretli Abonelik'
),

yesterday AS (
  SELECT
    CAST(DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 2 DAY) AS STRING) AS time_id,
    value AS Total
  FROM `microgain-9f959.looker_report.Daily_Report_Metrics`
  WHERE date = DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 2 DAY)
    AND metric = 'Toplam Ücretli Abonelik'
),

lastday AS (
  SELECT
    CAST(DATE_SUB(DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 1 DAY), INTERVAL 6 DAY) AS STRING) AS time_id,
    value AS Total
  FROM `microgain-9f959.looker_report.Daily_Report_Metrics`
  WHERE date = DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 7 DAY)
    AND metric = 'Toplam Ücretli Abonelik'
),

month AS (
  SELECT
    CAST(DATE_TRUNC(DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 8 DAY), MONTH) AS STRING) AS time_id,
    value AS Total
  FROM `microgain-9f959.looker_report.Daily_Report_Metrics`
  WHERE date = DATE_TRUNC(DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 8 DAY), MONTH)
    AND metric = 'Toplam Ücretli Abonelik'
),

year AS (
  SELECT
    CAST(FORMAT_DATE('%Y-%m-%d', DATE_TRUNC(DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 60 DAY), YEAR)) AS STRING) AS time_id,
    value AS Total
  FROM `microgain-9f959.looker_report.Daily_Report_Metrics`
  WHERE date = DATE_TRUNC(DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 60 DAY), YEAR)
    AND metric = 'Toplam Ücretli Abonelik'
),

lastyear AS (
  SELECT
    CAST('2023-06-01' AS STRING) AS time_id,
    value AS Total
  FROM `microgain-9f959.looker_report.Daily_Report_Metrics`
  WHERE date = DATE '2023-06-01'
    AND metric = 'Toplam Ücretli Abonelik'
),

all_time_max AS (
  SELECT
    CAST(date AS STRING) AS time_id,
    value AS Total
  FROM `microgain-9f959.looker_report.Daily_Report_Metrics`
  WHERE metric = 'Toplam Ücretli Abonelik'
  QUALIFY ROW_NUMBER() OVER (ORDER BY value DESC, date DESC) = 1
),

alldata AS (
  SELECT *,'Son Gün' Donem FROM firstday
  UNION ALL SELECT *,'Önceki Gün' Donem FROM yesterday
  UNION ALL SELECT *,'Son Hafta' Donem FROM lastday
  UNION ALL SELECT *,'Son Ay' Donem FROM month
  UNION ALL SELECT *,'Son Yıl' Donem FROM year
  UNION ALL SELECT *,'Since 01-06-2023' Donem FROM lastyear
  UNION ALL SELECT *,'All Time Max' Donem FROM all_time_max
),

data AS (
  SELECT * FROM alldata
),

-- Find the latest 'Total' value (dünün değeri)
latest_value AS (
  SELECT Total AS latest_total
  FROM data
  WHERE time_id = CAST(
    FORMAT_DATE('%Y-%m-%d', DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 1 DAY))
    AS STRING
  )
)

SELECT DISTINCT
  d.donem,
  d.time_id,
  CASE
    WHEN d.donem = 'Son Gün' THEN 1
    WHEN d.donem = 'Önceki Gün' THEN 2
    WHEN d.donem = 'Son Hafta' THEN 3
    WHEN d.donem = 'Son Ay' THEN 4
    WHEN d.donem = 'Son Yıl' THEN 5
    WHEN d.donem = 'Since 01-06-2023' THEN 6
    WHEN d.donem = 'All Time Max' THEN 7
  END rownum,
  d.Total,
  lv.latest_total,
  ROUND(((lv.latest_total - d.Total) / d.Total), 4) AS percentage_difference,
  CAST(DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 1 DAY) AS STRING) AS current_date,
  REPLACE(FORMAT("%'d", CAST(d.Total AS INT64)), ",", ".") AS combine_total,
  REPLACE(FORMAT("%'d", CAST(lv.latest_total AS INT64)), ",", ".") AS combine_latest_total
FROM data d
CROSS JOIN latest_value lv
ORDER BY rownum;