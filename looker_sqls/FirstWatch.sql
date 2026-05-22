WITH
contents AS (
  SELECT DISTINCT
    video_id,
    displayname AS content_name
  FROM `microgain-9f959.Backoffice_metadata.ContentMetaData`
),

all_stream AS (
  SELECT
    v.event_date AS day,
    v.user_id,
    v.video_id,
    v.ga_session_id,
    v.Datetime_Ist
  FROM `microgain-9f959.looker_report.content_report_streaming_V2` v
  WHERE v.user_id IS NOT NULL
),

first_watch_time AS (
  SELECT
    user_id,
    MIN(Datetime_Ist) AS first_watch_ts
  FROM all_stream
  GROUP BY 1
),

first_watch_content AS (
  SELECT
    day,
    user_id,
    video_id
  FROM (
    SELECT
      a.day,
      a.user_id,
      a.video_id,
      ROW_NUMBER() OVER (
        PARTITION BY a.user_id
        ORDER BY a.Datetime_Ist, a.video_id
      ) AS rn
    FROM all_stream a
    JOIN first_watch_time f
      ON a.user_id = f.user_id
     AND a.Datetime_Ist = f.first_watch_ts
  )
  WHERE rn = 1
),

/* subs_payment mantığı */
payment_daily AS (
  SELECT DISTINCT
    DATE(created_at, "Europe/Istanbul") AS day,
    user_id
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE user_id IS NOT NULL
),

/* elastic_active_user aynı mantıkla */
elastic_payment_daily AS (
  SELECT DISTINCT
    DATE(SAFE_CAST(created_at AS TIMESTAMP), "Europe/Istanbul") AS day,
    user_id
  FROM `microgain-9f959.looker_report.elastic_active_user`
  WHERE user_id IS NOT NULL
    AND SAFE_CAST(created_at AS TIMESTAMP) IS NOT NULL
),

daily_content_watch AS (
  SELECT
    s.day,
    COALESCE(c.content_name, 'UNKNOWN') AS content_name,
    COUNT(DISTINCT s.user_id) AS izleyen_user,
    COUNT(DISTINCT CONCAT(s.user_id, s.video_id, s.ga_session_id)) AS view_cnt
  FROM all_stream s
  LEFT JOIN contents c
    ON s.video_id = c.video_id
  GROUP BY 1, 2
),

daily_content_firstwatch AS (
  SELECT
    fwc.day,
    COALESCE(c.content_name, 'UNKNOWN') AS content_name,
    COUNT(DISTINCT fwc.user_id) AS first_watch_user
  FROM first_watch_content fwc
  LEFT JOIN contents c
    ON fwc.video_id = c.video_id
  GROUP BY 1, 2
),

/* subs_payment ile */
daily_content_watch_and_pay AS (
  SELECT
    s.day,
    COALESCE(c.content_name, 'UNKNOWN') AS content_name,
    COUNT(DISTINCT s.user_id) AS izleyip_abone_olan_user
  FROM all_stream s
  JOIN payment_daily p
    ON s.day = p.day
   AND s.user_id = p.user_id
  LEFT JOIN contents c
    ON s.video_id = c.video_id
  GROUP BY 1, 2
),

/* elastic_active_user ile */
daily_content_watch_and_pay_elastic AS (
  SELECT
    s.day,
    COALESCE(c.content_name, 'UNKNOWN') AS content_name,
    COUNT(DISTINCT s.user_id) AS izleyip_abone_olan_user_elastic
  FROM all_stream s
  JOIN elastic_payment_daily e
    ON s.day = e.day
   AND s.user_id = e.user_id
  LEFT JOIN contents c
    ON s.video_id = c.video_id
  GROUP BY 1, 2
)

SELECT
  w.day,
  w.content_name,
  w.izleyen_user,
  w.view_cnt,
  COALESCE(f.first_watch_user, 0) AS first_watch_user,
  COALESCE(p.izleyip_abone_olan_user, 0) AS izleyip_abone_olan_user,
  COALESCE(pe.izleyip_abone_olan_user_elastic, 0) AS izleyip_abone_olan_user_elastic
FROM daily_content_watch w
LEFT JOIN daily_content_firstwatch f
  ON w.day = f.day AND w.content_name = f.content_name
LEFT JOIN daily_content_watch_and_pay p
  ON w.day = p.day AND w.content_name = p.content_name
LEFT JOIN daily_content_watch_and_pay_elastic pe
  ON w.day = pe.day AND w.content_name = pe.content_name;