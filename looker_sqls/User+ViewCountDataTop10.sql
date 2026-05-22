WITH
params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),
contents AS (
  SELECT DISTINCT
    video_id,
    displayname,
    contenttype_id
  FROM `microgain-9f959.Backoffice_metadata.ContentMetaData`
),
base AS (
  SELECT
    v.user_id,
    v.video_id,
    v.ga_session_id
  FROM `microgain-9f959.looker_report.content_report_streaming_V2` v
  JOIN params p ON TRUE
  WHERE v.user_id IS NOT NULL
    AND v.event_date BETWEEN p.ds_start AND p.ds_end
),
base_enriched AS (
  SELECT
    b.user_id,
    b.video_id,
    b.ga_session_id,
    c.contenttype_id,
    c.displayname
  FROM base b
  JOIN contents c ON b.video_id = c.video_id
  WHERE c.contenttype_id = 'CHANGE_THIS_TO_CONTENT_TYPE_ID' -- TODO: Set the content type id e.g. documentary, movie, series, etc.
),
agg AS (
  SELECT
    video_id,
    ANY_VALUE(displayname) AS content_name,
    COUNT(DISTINCT user_id) AS total_user_cnt,
    COUNT(DISTINCT CONCAT(user_id, video_id, ga_session_id)) AS total_view_cnt
  FROM base_enriched
  GROUP BY video_id
)
SELECT
  content_name,
  total_user_cnt,
  total_view_cnt
FROM agg
ORDER BY total_view_cnt DESC
LIMIT 10;
