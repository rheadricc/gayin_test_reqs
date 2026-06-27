-- Looker Studio parametreleri: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)

WITH
params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE) AS ds_end
),

calendar AS (
  SELECT day AS event_date
  FROM params,
  UNNEST(GENERATE_DATE_ARRAY(ds_start, ds_end)) AS day
),

contents AS (
  SELECT
    video_id,
    ANY_VALUE(displayname) AS displayname,
    ANY_VALUE(video_name) AS video_name,
    ANY_VALUE(season_info) AS season_info,
    ANY_VALUE(contenttype_id) AS contenttype_id,
    ANY_VALUE(IsGainOriginals) AS IsGainOriginals,
    ANY_VALUE(genres) AS genres
  FROM `microgain-9f959.Backoffice_metadata.ContentMetaData`
  GROUP BY video_id
),

contents_fixed AS (
  SELECT
    c.video_id,
    c.displayname,
    c.video_name,
    c.season_info,
    c.contenttype_id,
    c.IsGainOriginals,
    STRING_AGG(DISTINCT TRIM(g), '-' ORDER BY TRIM(g)) AS kategori
  FROM contents c
  LEFT JOIN UNNEST(SPLIT(COALESCE(c.genres, ''), ',')) AS g
  WHERE TRIM(g) IS NOT NULL
    AND TRIM(g) != ''
  GROUP BY
    c.video_id,
    c.displayname,
    c.video_name,
    c.season_info,
    c.contenttype_id,
    c.IsGainOriginals
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

daily_content AS (
  SELECT
    event_date,
    video_id,
    COUNT(DISTINCT user_id) AS user_cnt,
    COUNT(DISTINCT CONCAT(
      CAST(user_id AS STRING), '|',
      CAST(video_id AS STRING), '|',
      IFNULL(CAST(ga_session_id AS STRING), 'no_session')
    )) AS view_cnt
  FROM base
  GROUP BY event_date, video_id
),

content_totals AS (
  SELECT
    video_id,
    SUM(view_cnt) AS total_view_cnt
  FROM daily_content
  GROUP BY video_id
),

ranked_content AS (
  SELECT
    video_id,
    total_view_cnt,
    DENSE_RANK() OVER (ORDER BY total_view_cnt DESC) AS content_rank
  FROM content_totals
)

SELECT
  cal.event_date,
  c.displayname AS content_name,
  c.season_info AS sezon,

  SAFE_CAST(
    REGEXP_EXTRACT(
      LOWER(c.video_name),
      r'(?:bölüm|bolum|ep|episode)\s*([0-9]+)'
    ) AS INT64
  ) AS bolum,

  c.contenttype_id AS icerik_turu,
  c.kategori AS kategori,
  c.IsGainOriginals AS IsGainOriginals,

  r.content_rank,

  IFNULL(d.user_cnt, 0) AS user_cnt,
  IFNULL(d.view_cnt, 0) AS view_cnt

FROM calendar cal
CROSS JOIN ranked_content r
JOIN contents_fixed c
  ON r.video_id = c.video_id
LEFT JOIN daily_content d
  ON cal.event_date = d.event_date
  AND r.video_id = d.video_id

GROUP BY
  cal.event_date,
  c.displayname,
  c.season_info,
  bolum,
  c.contenttype_id,
  c.kategori,
  c.IsGainOriginals,
  r.content_rank,
  d.user_cnt,
  d.view_cnt
