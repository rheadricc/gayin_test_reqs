-- Looker Studio parametreleri: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Amaç:
--   expire olmadan önce kullanıcının son izlediği içeriği bulmak
-- Kaynaklar:
--   - stream: content_report_streaming_V2
--   - expire kaynakları: subs_payment + elastic_active_user
-- Output:
--   user_id bazlı son izlenen içerik detayları

WITH
params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

contents AS (
  SELECT
    video_id,
    ANY_VALUE(displayname)     AS displayname,
    ANY_VALUE(video_name)      AS video_name,
    ANY_VALUE(season_info)     AS season_info,
    ANY_VALUE(contenttype_id)  AS contenttype_id,
    ANY_VALUE(IsGainOriginals) AS IsGainOriginals,
    ANY_VALUE(genres)          AS genres
  FROM `microgain-9f959.Backoffice_metadata.ContentMetaData`
  GROUP BY video_id
),

contents_exploded AS (
  SELECT
    c.video_id,
    c.displayname,
    c.video_name,
    c.season_info,
    c.contenttype_id,
    c.IsGainOriginals,
    TRIM(g) AS genre
  FROM contents c
  LEFT JOIN UNNEST(SPLIT(COALESCE(c.genres, ''), ',')) AS g
  WHERE TRIM(g) IS NOT NULL
    AND TRIM(g) != ''
),

all_stream AS (
  SELECT
    CAST(v.user_id AS STRING) AS user_id,
    v.event_date AS day,
    v.video_id,
    v.ga_session_id,
    v.Datetime_Ist
  FROM `microgain-9f959.looker_report.content_report_streaming_V2` v
  WHERE v.user_id IS NOT NULL
    AND v.video_id IS NOT NULL
    AND v.Datetime_Ist IS NOT NULL
),

expire_base AS (
  SELECT DISTINCT
    CAST(user_id AS STRING) AS user_id,
    TIMESTAMP(valid_until) AS expire_ts,
    DATE(valid_until, "Europe/Istanbul") AS expire_day,
    'subs_payment' AS source_table
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  CROSS JOIN params p
  WHERE user_id IS NOT NULL
    AND valid_until IS NOT NULL
    AND DATE(valid_until, "Europe/Istanbul") BETWEEN p.ds_start AND p.ds_end

  UNION DISTINCT

  SELECT DISTINCT
    CAST(user_id AS STRING) AS user_id,
    SAFE_CAST(valid_until AS TIMESTAMP) AS expire_ts,
    DATE(SAFE_CAST(valid_until AS TIMESTAMP), "Europe/Istanbul") AS expire_day,
    'elastic_active_user' AS source_table
  FROM `microgain-9f959.looker_report.elastic_active_user`
  CROSS JOIN params p
  WHERE user_id IS NOT NULL
    AND SAFE_CAST(valid_until AS TIMESTAMP) IS NOT NULL
    AND DATE(SAFE_CAST(valid_until AS TIMESTAMP), "Europe/Istanbul") BETWEEN p.ds_start AND p.ds_end
),

last_watch_before_expire AS (
  SELECT
    user_id,
    expire_day,
    expire_ts,
    source_table,
    day AS last_watch_day,
    video_id,
    ga_session_id,
    Datetime_Ist AS last_watch_ts
  FROM (
    SELECT
      e.user_id,
      e.expire_day,
      e.expire_ts,
      e.source_table,
      s.day,
      s.video_id,
      s.ga_session_id,
      s.Datetime_Ist,
      ROW_NUMBER() OVER (
        PARTITION BY e.user_id, e.expire_ts
        ORDER BY s.Datetime_Ist DESC, s.video_id DESC
      ) AS rn
    FROM expire_base e
    JOIN all_stream s
      ON e.user_id = s.user_id
     AND s.Datetime_Ist <= DATETIME(e.expire_ts, "Europe/Istanbul")
  )
  WHERE rn = 1
)

SELECT
  l.user_id,
  l.expire_day,
  l.expire_ts,
  l.source_table,
  l.last_watch_day,
  l.last_watch_ts,
  c.displayname AS content_name,
  c.season_info AS sezon,

  CASE 
    WHEN SAFE_CAST(
      COALESCE(
        REGEXP_EXTRACT(LOWER(c.video_name), r'(?:bölüm|bolum|ep|episode)\s*([0-9]{1,3})'),
        REGEXP_EXTRACT(c.video_name, r'\b([0-9]{1,3})\b')
      ) AS INT64
    ) IS NULL
    THEN 'Trailer'
    ELSE CAST(
      SAFE_CAST(
        COALESCE(
          REGEXP_EXTRACT(LOWER(c.video_name), r'(?:bölüm|bolum|ep|episode)\s*([0-9]{1,3})'),
          REGEXP_EXTRACT(c.video_name, r'\b([0-9]{1,3})\b')
        ) AS INT64
      ) AS STRING
    )
  END AS bolum,

  CASE
    WHEN REGEXP_CONTAINS(LOWER(c.contenttype_id), r'tv')        THEN 'Dizi'
    WHEN REGEXP_CONTAINS(LOWER(c.contenttype_id), r'film')      THEN 'Film'
    WHEN REGEXP_CONTAINS(LOWER(c.contenttype_id), r'program')   THEN 'Program'
    WHEN REGEXP_CONTAINS(LOWER(c.contenttype_id), r'doc')       THEN 'Belgesel'
    ELSE c.contenttype_id
  END AS icerik_turu,

  STRING_AGG(DISTINCT c.genre, '-' ORDER BY c.genre) AS kategori,

  CASE 
    WHEN LOWER(CAST(c.IsGainOriginals AS STRING)) = 'true' THEN 'Orijinal'
    ELSE 'Orijinal Değil'
  END AS gain_original

FROM last_watch_before_expire l
JOIN contents_exploded c
  ON l.video_id = c.video_id

GROUP BY
  l.user_id,
  l.expire_day,
  l.expire_ts,
  l.source_table,
  l.last_watch_day,
  l.last_watch_ts,
  content_name,
  sezon,
  bolum,
  icerik_turu,
  gain_original

ORDER BY l.expire_day DESC, l.user_id;