-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Output: category-level 3-month retention
-- Logic:
--   - first category = user's first meaningful watched content's first genre
--   - retention_3m = user streamed at least once between day 31 and day 90 after first watch
--   - dashboard date filter is shifted back by 90 days for cohort selection

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

cohort_window AS (
  SELECT
    DATE_SUB(ds_start, INTERVAL 90 DAY) AS cohort_start,
    DATE_SUB(ds_end,   INTERVAL 90 DAY) AS cohort_end
  FROM params
),

/* =====================================================
   1) CONTENT GENRE MAP
   ===================================================== */
contents AS (
  SELECT
    CAST(video_id AS STRING) AS video_id,
    ANY_VALUE(displayname) AS content_name,
    TRIM(SPLIT(ANY_VALUE(genres), ',')[SAFE_OFFSET(0)]) AS genre
  FROM `microgain-9f959.Backoffice_metadata.ContentMetaData`
  WHERE video_id IS NOT NULL
  GROUP BY video_id
),

/* =====================================================
   2) ALL STREAM EVENTS
   ===================================================== */
all_stream AS (
  SELECT
    CAST(user_id AS STRING) AS user_id,
    CAST(video_id AS STRING) AS video_id,
    Datetime_Ist,
    event_date
  FROM `microgain-9f959.looker_report.content_report_streaming_V2`
  WHERE user_id IS NOT NULL
    AND video_id IS NOT NULL
    AND Datetime_Ist IS NOT NULL
),

/* =====================================================
   3) KEEP ONLY STREAMS WITH VALID GENRE
   ===================================================== */
stream_with_genre AS (
  SELECT
    s.user_id,
    s.video_id,
    s.Datetime_Ist,
    s.event_date,
    c.genre
  FROM all_stream s
  JOIN contents c
    ON TRIM(s.video_id) = TRIM(c.video_id)
  WHERE c.genre IS NOT NULL
    AND TRIM(c.genre) != ''
),

/* =====================================================
   4) USERS FIRST MEANINGFUL WATCH
   ===================================================== */
first_valid_watch AS (
  SELECT
    user_id,
    event_date AS first_watch_date,
    video_id AS first_video_id,
    genre AS first_category
  FROM (
    SELECT
      s.*,
      ROW_NUMBER() OVER (
        PARTITION BY s.user_id
        ORDER BY s.Datetime_Ist ASC, s.video_id ASC
      ) AS rn
    FROM stream_with_genre s
  )
  WHERE rn = 1
),

/* =====================================================
   5) COHORT
      Dashboard filter shifted back by 90 days
   ===================================================== */
cohort AS (
  SELECT
    f.user_id,
    f.first_watch_date,
    f.first_video_id,
    f.first_category
  FROM first_valid_watch f
  CROSS JOIN cohort_window w
  WHERE f.first_watch_date BETWEEN w.cohort_start AND w.cohort_end
),

/* =====================================================
   6) RETAINED USERS:
      At least 1 stream between day 31..90 after first watch
   ===================================================== */
retained_users AS (
  SELECT DISTINCT
    c.user_id
  FROM cohort c
  JOIN all_stream s
    ON s.user_id = c.user_id
   AND s.event_date >= DATE_ADD(c.first_watch_date, INTERVAL 30 DAY)
   AND s.event_date <= DATE_ADD(c.first_watch_date, INTERVAL 90 DAY)
),

/* =====================================================
   7) FINAL AGG
   ===================================================== */
final AS (
  SELECT
    c.first_category,
    COUNT(DISTINCT c.user_id) AS users,
    COUNT(DISTINCT r.user_id) AS retained_users,
    SAFE_DIVIDE(COUNT(DISTINCT r.user_id), COUNT(DISTINCT c.user_id)) AS retention_3m
  FROM cohort c
  LEFT JOIN retained_users r
    ON c.user_id = r.user_id
  GROUP BY c.first_category
)

SELECT
  first_category,
  users,
  retained_users,
  retention_3m
FROM final
ORDER BY retention_3m DESC, users DESC;