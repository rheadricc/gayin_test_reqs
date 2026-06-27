-- Looker Studio params:
-- @DS_START_DATE , @DS_END_DATE -> format: YYYYMMDD

WITH params AS (
  SELECT
    GREATEST(PARSE_DATE('%Y%m%d', @DS_START_DATE), DATE '2026-03-30') AS start_date,
    PARSE_DATE('%Y%m%d', @DS_END_DATE) AS end_date
),

date_spine AS (
  SELECT day
  FROM params,
  UNNEST(GENERATE_DATE_ARRAY(start_date, end_date)) AS day
),

campaign_users AS (
  SELECT *
  FROM (
    SELECT
      s.user_id,
      s.email,
      s.created_at,
      s.valid_until,
      s.status,
      ap.promotionId,
      ap.name AS promotion_name,
      ap.applyDate,
      CASE
        WHEN ap.promotionId IN (
          'KWH380HBAC8HAYGCHWBYOF0X', -- BJK
          'GCV1YCXPE9O0BU12BACR5T3E', -- GS
          'KQ4RNTYRPG0NIEBG86LUBPU1'  -- FB
        ) THEN 'Kulüp'
        WHEN ap.promotionId = '9K1ZNAV2XRLCFHYIG718654H' THEN '3AY_129'
      END AS campaign,
      CASE
        WHEN ap.promotionId = 'KWH380HBAC8HAYGCHWBYOF0X' THEN 'BJK'
        WHEN ap.promotionId = 'GCV1YCXPE9O0BU12BACR5T3E' THEN 'GS'
        WHEN ap.promotionId = 'KQ4RNTYRPG0NIEBG86LUBPU1' THEN 'FB'
        WHEN ap.promotionId = '9K1ZNAV2XRLCFHYIG718654H' THEN 'GAIN3AY'
      END AS campaign_detail,
      ROW_NUMBER() OVER (
        PARTITION BY s.user_id
        ORDER BY ap.applyDate DESC, s.created_at DESC
      ) AS rn
    FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
    CROSS JOIN UNNEST(s.applied_promotions) ap
    CROSS JOIN params p
    WHERE ap.promotionId IN (
      'KWH380HBAC8HAYGCHWBYOF0X',
      'GCV1YCXPE9O0BU12BACR5T3E',
      'KQ4RNTYRPG0NIEBG86LUBPU1',
      '9K1ZNAV2XRLCFHYIG718654H'
    )
      AND DATE(s.created_at) <= p.end_date
      AND DATE(s.valid_until) >= p.start_date
  )
  WHERE rn = 1
),

campaigns AS (
  SELECT '3AY_129' AS campaign, 'GAIN3AY' AS campaign_detail UNION ALL
  SELECT 'Kulüp'   AS campaign, 'BJK'     AS campaign_detail UNION ALL
  SELECT 'Kulüp'   AS campaign, 'GS'      AS campaign_detail UNION ALL
  SELECT 'Kulüp'   AS campaign, 'FB'      AS campaign_detail
),

platforms AS (
  SELECT 'iOS' AS platform UNION ALL
  SELECT 'Android' UNION ALL
  SELECT 'Web' UNION ALL
  SELECT 'TV' UNION ALL
  SELECT 'Unknown'
),

watch_base AS (
  SELECT
    cr.event_date AS day,
    cr.user_id,
    CASE
      WHEN LOWER(cr.device_category) = 'smart tv' THEN 'TV'
      WHEN UPPER(cr.device_platform) = 'IOS' THEN 'iOS'
      WHEN UPPER(cr.device_platform) = 'ANDROID' THEN 'Android'
      WHEN UPPER(cr.device_platform) = 'WEB' THEN 'Web'
      ELSE 'Unknown'
    END AS platform,
    COALESCE(cr.watch_time_second, 0) AS watch_time_second
  FROM `microgain-9f959.looker_report.content_report_streaming_V2` cr
  JOIN campaign_users cu
    ON cr.user_id = cu.user_id
  CROSS JOIN params p
  WHERE cr.event_date BETWEEN p.start_date AND p.end_date
),

watch_user_platform_day AS (
  SELECT
    day,
    user_id,
    platform,
    SUM(watch_time_second) AS day_platform_watch_time,
    COUNT(*) AS day_platform_events
  FROM watch_base
  GROUP BY 1,2,3
),

user_day_campaign_days AS (
  SELECT
    d.day,
    cu.user_id
  FROM date_spine d
  JOIN campaign_users cu
    ON d.day BETWEEN DATE(cu.created_at) AND DATE(cu.valid_until)
),

user_day_platform_scores AS (
  SELECT
    u.day,
    u.user_id,
    p.platform,
    COALESCE(SUM(w.day_platform_watch_time), 0) AS cumulative_watch_time,
    COALESCE(SUM(w.day_platform_events), 0) AS cumulative_events
  FROM user_day_campaign_days u
  CROSS JOIN platforms p
  LEFT JOIN watch_user_platform_day w
    ON w.user_id = u.user_id
   AND w.platform = p.platform
   AND w.day <= u.day
  GROUP BY 1,2,3
),

user_day_platform AS (
  SELECT
    day,
    user_id,
    CASE
      WHEN cumulative_watch_time = 0 AND cumulative_events = 0 THEN 'Unknown'
      ELSE platform
    END AS platform
  FROM (
    SELECT
      day,
      user_id,
      platform,
      cumulative_watch_time,
      cumulative_events,
      ROW_NUMBER() OVER (
        PARTITION BY day, user_id
        ORDER BY cumulative_watch_time DESC, cumulative_events DESC, platform
      ) AS rn
    FROM user_day_platform_scores
  )
  WHERE rn = 1
),

new_subs AS (
  SELECT
    DATE(cu.created_at) AS day,
    cu.campaign,
    cu.campaign_detail,
    COALESCE(udp.platform, 'Unknown') AS platform,
    COUNT(DISTINCT cu.user_id) AS new_subscribers
  FROM campaign_users cu
  CROSS JOIN params p
  LEFT JOIN user_day_platform udp
    ON udp.user_id = cu.user_id
   AND udp.day = DATE(cu.created_at)
  WHERE DATE(cu.created_at) BETWEEN p.start_date AND p.end_date
  GROUP BY 1,2,3,4
),

active_subs AS (
  SELECT
    d.day,
    cu.campaign,
    cu.campaign_detail,
    COALESCE(udp.platform, 'Unknown') AS platform,
    COUNT(DISTINCT cu.user_id) AS active_subscribers
  FROM date_spine d
  JOIN campaign_users cu
    ON d.day BETWEEN DATE(cu.created_at) AND DATE(cu.valid_until)
  LEFT JOIN user_day_platform udp
    ON udp.user_id = cu.user_id
   AND udp.day = d.day
  WHERE cu.status IN ('ACTIVE', 'CANCELED', 'IN_GRACE', 'ON_HOLD', 'EXPIRED')
  GROUP BY 1,2,3,4
),

churn AS (
  SELECT
    DATE(cu.valid_until) AS day,
    cu.campaign,
    cu.campaign_detail,
    COALESCE(udp.platform, 'Unknown') AS platform,
    COUNT(DISTINCT cu.user_id) AS churn_users
  FROM campaign_users cu
  CROSS JOIN params p
  LEFT JOIN user_day_platform udp
    ON udp.user_id = cu.user_id
   AND udp.day = DATE(cu.valid_until)
  WHERE cu.status = 'EXPIRED'
    AND DATE(cu.valid_until) BETWEEN p.start_date AND p.end_date
  GROUP BY 1,2,3,4
),

conversion_base AS (
  SELECT
    cu.user_id,
    cu.campaign,
    cu.campaign_detail,
    MIN(s2.created_at) AS next_payment_date
  FROM campaign_users cu
  JOIN `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s2
    ON cu.user_id = s2.user_id
   AND s2.created_at > cu.valid_until
   AND s2.amount > 0
  GROUP BY 1,2,3
),

conversion_daily AS (
  SELECT
    DATE(cb.next_payment_date) AS day,
    cb.campaign,
    cb.campaign_detail,
    COALESCE(udp.platform, 'Unknown') AS platform,
    COUNT(DISTINCT cb.user_id) AS conversions
  FROM conversion_base cb
  CROSS JOIN params p
  LEFT JOIN user_day_platform udp
    ON udp.user_id = cb.user_id
   AND udp.day = DATE(cb.next_payment_date)
  WHERE DATE(cb.next_payment_date) BETWEEN p.start_date AND p.end_date
  GROUP BY 1,2,3,4
),

watch_metrics AS (
  SELECT
    wb.day,
    cu.campaign,
    cu.campaign_detail,
    COALESCE(udp.platform, 'Unknown') AS platform,
    COUNT(DISTINCT wb.user_id) AS unique_watchers,
    SUM(wb.watch_time_second) AS total_watch_time,
    COUNT(*) AS daily_watches,
    SAFE_DIVIDE(SUM(wb.watch_time_second), COUNT(DISTINCT wb.user_id)) AS avg_user_watch_time
  FROM watch_base wb
  JOIN campaign_users cu
    ON cu.user_id = wb.user_id
  LEFT JOIN user_day_platform udp
    ON udp.user_id = wb.user_id
   AND udp.day = wb.day
  GROUP BY 1,2,3,4
)

SELECT
  d.day,
  c.campaign,
  c.campaign_detail,
  p.platform,

  COALESCE(ns.new_subscribers, 0)    AS new_subscribers,
  COALESCE(a.active_subscribers, 0)  AS active_subscribers,
  COALESCE(ch.churn_users, 0)        AS churn_users,
  COALESCE(cd.conversions, 0)        AS conversions,

  COALESCE(w.unique_watchers, 0)     AS unique_watchers,
  COALESCE(w.total_watch_time, 0)    AS total_watch_time,
  COALESCE(w.daily_watches, 0)       AS daily_watches,
  COALESCE(w.avg_user_watch_time, 0) AS avg_user_watch_time

FROM date_spine d
CROSS JOIN campaigns c
CROSS JOIN platforms p
LEFT JOIN new_subs ns
  ON d.day = ns.day
 AND c.campaign = ns.campaign
 AND c.campaign_detail = ns.campaign_detail
 AND p.platform = ns.platform
LEFT JOIN active_subs a
  ON d.day = a.day
 AND c.campaign = a.campaign
 AND c.campaign_detail = a.campaign_detail
 AND p.platform = a.platform
LEFT JOIN churn ch
  ON d.day = ch.day
 AND c.campaign = ch.campaign
 AND c.campaign_detail = ch.campaign_detail
 AND p.platform = ch.platform
LEFT JOIN conversion_daily cd
  ON d.day = cd.day
 AND c.campaign = cd.campaign
 AND c.campaign_detail = cd.campaign_detail
 AND p.platform = cd.platform
LEFT JOIN watch_metrics w
  ON d.day = w.day
 AND c.campaign = w.campaign
 AND c.campaign_detail = w.campaign_detail
 AND p.platform = w.platform

ORDER BY 1,2,3,4;
