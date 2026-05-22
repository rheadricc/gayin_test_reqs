-- Looker Studio parametreleri: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)

WITH
params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

-- 1️⃣ Tarih tablosu (date spine)
calendar AS (
  SELECT day AS event_date
  FROM params,
  UNNEST(GENERATE_DATE_ARRAY(ds_start, ds_end)) AS day
),

contents AS (
  SELECT DISTINCT
    video_id,
    displayname
  FROM `microgain-9f959.Backoffice_metadata.ContentMetaData`
),

base AS (
  SELECT
    v.event_date,
    v.user_id,
    v.video_id,
    v.ga_session_id
  FROM `microgain-9f959.looker_report.content_report_streaming_V2` v
  JOIN params p ON TRUE
  WHERE v.user_id IS NOT NULL
    AND v.event_date BETWEEN p.ds_start AND p.ds_end
),

aggregated AS (
  SELECT
    b.event_date,
    b.video_id,
    COUNT(DISTINCT b.user_id) AS user_cnt,
    COUNT(DISTINCT CONCAT(b.user_id, b.video_id, b.ga_session_id)) AS view_cnt
  FROM base b
  GROUP BY 1,2
)

SELECT
  cal.event_date,
  c.displayname AS content_name,
  IFNULL(a.user_cnt, 0) AS user_cnt,
  IFNULL(a.view_cnt, 0) AS view_cnt
FROM calendar cal
CROSS JOIN contents c
LEFT JOIN aggregated a
  ON cal.event_date = a.event_date
  AND c.video_id = a.video_id
ORDER BY cal.event_date, view_cnt DESC;