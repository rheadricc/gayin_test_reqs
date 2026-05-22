-- Looker Studio parametreleri: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)

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

-- ✅ genres string -> tekil genre satırlarına explode
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
  WHERE TRIM(g) IS NOT NULL AND TRIM(g) != ''
),

base AS (
  SELECT
    v.event_date,              -- ✅ Looker’ın tarih boyutu
    v.user_id,
    v.video_id,
    v.ga_session_id
  FROM `microgain-9f959.looker_report.content_report_streaming_V2` v
  JOIN params p ON TRUE
  WHERE v.user_id IS NOT NULL
    AND v.event_date BETWEEN p.ds_start AND p.ds_end
)

SELECT
  b.event_date,                -- ✅ date chart’a bağlanacak alan
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

  -- ✅ artık tekil genre
  --c.genre AS kategori,
  STRING_AGG(DISTINCT c.genre, '-' ORDER BY c.genre) AS kategori,

CASE 
  WHEN LOWER(CAST(c.IsGainOriginals AS STRING)) = 'true' THEN 'Orijinal'
  ELSE 'Orijinal Değil'
END AS gain_original,

  COUNT(DISTINCT b.user_id) AS user_cnt,
  COUNT(DISTINCT CONCAT(b.user_id, b.video_id, b.ga_session_id)) AS view_cnt

FROM base b
JOIN contents_exploded c
  ON b.video_id = c.video_id

GROUP BY
  b.event_date, content_name, sezon, bolum, icerik_turu, IsGainOriginals

ORDER BY view_cnt DESC;
