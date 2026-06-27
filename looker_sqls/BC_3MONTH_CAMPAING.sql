-- BC_3MONTH_CAMPAIGN
-- Conversion mantığı:
-- Kullanıcı kampanya kodunu kullandıktan sonra,
-- kampanyalı dönemi bittikten sonraki ilk ücretli ödemesinde
-- artık aynı kampanya promosyonundan yararlanmıyorsa
-- ve ödeme indirimsizse conversion sayılır.

-- Looker Studio params:
-- @DS_START_DATE , @DS_END_DATE -> format: YYYYMMDD
--
-- Looker kurulumu:
-- 1) Platform Kullanım Dağılımı
--    Boyut: platform
--    Metrik: SUM(selected_period_platform_users)
--    Tarih aralığı: sayfa filtresini devralmalı; ayrıca "Dün" filtresi verilmemeli.
-- 2) Tekil İzleyici
--    Metrik: SUM(daily_unique_watchers_anchor)
-- 3) Ortalama İzleme Süresi
--    Metrik: MAX(daily_avg_user_watch_time_anchor)
--    Bu alan yalnızca watch_time_second ölçülebilen izleyicileri kapsar.
-- 4) streaming_data_available = FALSE olan günlerde streaming kaynağı eksiktir;
--    NULL değerler gerçek sıfır olarak yorumlanmamalıdır.

WITH params AS (
  SELECT
    GREATEST(PARSE_DATE('%Y%m%d', @DS_START_DATE), DATE '2026-03-30') AS start_date,
    LEAST(
      PARSE_DATE('%Y%m%d', @DS_END_DATE),
      DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
    ) AS end_date
),

promo_map AS (
  SELECT 'KWH380HBAC8HAYGCHWBYOF0X' AS promotionId, 'Kulüp' AS campaign, 'BJK' AS campaign_detail UNION ALL
  SELECT 'GCV1YCXPE9O0BU12BACR5T3E', 'Kulüp', 'GS' UNION ALL
  SELECT 'KQ4RNTYRPG0NIEBG86LUBPU1', 'Kulüp', 'FB' UNION ALL
  SELECT '9K1ZNAV2XRLCFHYIG718654H', '3AY_129', 'GAIN3AY'
),

date_spine AS (
  SELECT day
  FROM params,
  UNNEST(GENERATE_DATE_ARRAY(start_date, end_date)) AS day
),

subs_campaign_history AS (
  SELECT *
  FROM (
    SELECT
      s.user_id,
      s.email,
      s.created_at,
      s.valid_until,
      s.status,
      s.amount,
      s.amount_before_promotions,
      s.payment_option,
      ap.promotionId,
      ap.name AS promotion_name,
      ap.applyDate,
      pm.campaign,
      pm.campaign_detail,
      ROW_NUMBER() OVER (
        PARTITION BY s.user_id, ap.promotionId
        ORDER BY ap.applyDate DESC, s.created_at DESC
      ) AS rn
    FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
    CROSS JOIN UNNEST(s.applied_promotions) ap
    JOIN promo_map pm
      ON ap.promotionId = pm.promotionId
    CROSS JOIN params p
    WHERE DATE(s.created_at) <= p.end_date
  )
  WHERE rn = 1
),

elastic_campaign_history AS (
  SELECT *
  FROM (
    SELECT
      eau.user_id,
      eau.email,
      SAFE_CAST(eau.created_at AS TIMESTAMP) AS created_at,
      SAFE_CAST(eau.valid_until AS TIMESTAMP) AS valid_until,
      eau.status,
      CAST(NULL AS INT64) AS amount,
      CAST(NULL AS INT64) AS amount_before_promotions,
      CAST(NULL AS STRING) AS payment_option,
      pm.promotionId,
      CAST(NULL AS STRING) AS promotion_name,
      CAST(NULL AS TIMESTAMP) AS applyDate,
      pm.campaign,
      pm.campaign_detail,
      ROW_NUMBER() OVER (
        PARTITION BY eau.user_id, pm.promotionId
        ORDER BY SAFE_CAST(eau.valid_until AS TIMESTAMP) DESC,
                 SAFE_CAST(eau.created_at AS TIMESTAMP) DESC
      ) AS rn
    FROM `microgain-9f959.looker_report.elastic_active_user` eau
    JOIN promo_map pm
      ON REGEXP_CONTAINS(COALESCE(eau.applied_promotions, ''), pm.promotionId)
    CROSS JOIN params p
    WHERE SAFE_CAST(eau.created_at AS TIMESTAMP) <= TIMESTAMP(p.end_date)
  )
  WHERE rn = 1
),

elastic_current AS (
  SELECT *
  FROM (
    SELECT
      eau.user_id,
      eau.email,
      SAFE_CAST(eau.created_at AS TIMESTAMP) AS created_at,
      SAFE_CAST(eau.valid_until AS TIMESTAMP) AS valid_until,
      eau.status,
      ROW_NUMBER() OVER (
        PARTITION BY eau.user_id
        ORDER BY SAFE_CAST(eau.valid_until AS TIMESTAMP) DESC,
                 SAFE_CAST(eau.created_at AS TIMESTAMP) DESC
      ) AS rn
    FROM `microgain-9f959.looker_report.elastic_active_user` eau
    CROSS JOIN params p
    WHERE SAFE_CAST(eau.created_at AS TIMESTAMP) <= TIMESTAMP(p.end_date)
  )
  WHERE rn = 1
),

campaign_users_base AS (
  SELECT
    sch.user_id,
    sch.email,
    sch.created_at,
    sch.valid_until,
    sch.status,
    sch.amount,
    sch.amount_before_promotions,
    sch.payment_option,
    sch.promotionId,
    sch.promotion_name,
    sch.applyDate,
    sch.campaign,
    sch.campaign_detail
  FROM subs_campaign_history sch

  UNION ALL

  SELECT
    ech.user_id,
    ech.email,
    ech.created_at,
    ech.valid_until,
    ech.status,
    ech.amount,
    ech.amount_before_promotions,
    ech.payment_option,
    ech.promotionId,
    ech.promotion_name,
    ech.applyDate,
    ech.campaign,
    ech.campaign_detail
  FROM elastic_campaign_history ech
  LEFT JOIN subs_campaign_history sch
    ON ech.user_id = sch.user_id
  WHERE sch.user_id IS NULL
),

campaign_users AS (
  SELECT
    cub.user_id,
    COALESCE(ec.email, cub.email) AS email,
    cub.created_at,
    COALESCE(DATE(cub.applyDate), DATE(cub.created_at)) AS campaign_start_date,
    COALESCE(ec.valid_until, cub.valid_until) AS valid_until,
    COALESCE(ec.status, cub.status) AS status,
    cub.amount,
    cub.amount_before_promotions,
    cub.payment_option,
    cub.promotionId,
    cub.promotion_name,
    cub.applyDate,
    cub.campaign,
    cub.campaign_detail
  FROM campaign_users_base cub
  LEFT JOIN elastic_current ec
    ON cub.user_id = ec.user_id
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
    cu.campaign,
    cu.campaign_detail,
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
   AND cr.event_date >= cu.campaign_start_date
  CROSS JOIN params p
  WHERE cr.event_date BETWEEN p.start_date AND p.end_date
),

streaming_day_coverage AS (
  SELECT
    cr.event_date AS day,
    COUNT(*) AS source_event_rows,
    COUNTIF(cr.watch_time_second IS NOT NULL) AS source_measured_rows
  FROM `microgain-9f959.looker_report.content_report_streaming_V2` cr
  CROSS JOIN params p
  WHERE cr.event_date BETWEEN p.start_date AND p.end_date
  GROUP BY cr.event_date
),

watch_user_platform_day AS (
  SELECT
    day,
    user_id,
    campaign,
    campaign_detail,
    platform,
    SUM(watch_time_second) AS day_platform_watch_time,
    COUNT(*) AS day_platform_events
  FROM watch_base
  GROUP BY 1,2,3,4,5
),

/* Dominant platform for that specific day, only among users who watched. */
user_day_platform AS (
  SELECT
    day,
    user_id,
    campaign,
    campaign_detail,
    platform
  FROM watch_user_platform_day
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY day, user_id, campaign, campaign_detail
    ORDER BY
      IF(day_platform_watch_time > 0, 1, 0) DESC,
      day_platform_watch_time DESC,
      day_platform_events DESC,
      platform
  ) = 1
),

/* Dominant platform across the selected Looker period, only for watchers. */
selected_period_user_platform AS (
  SELECT
    user_id,
    campaign,
    campaign_detail,
    platform
  FROM (
    SELECT
      user_id,
      campaign,
      campaign_detail,
      platform,
      SUM(day_platform_watch_time) AS selected_watch_time,
      SUM(day_platform_events) AS selected_events
    FROM watch_user_platform_day
    GROUP BY user_id, campaign, campaign_detail, platform
  )
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY user_id, campaign, campaign_detail
    ORDER BY
      IF(selected_watch_time > 0, 1, 0) DESC,
      selected_watch_time DESC,
      selected_events DESC,
      platform
  ) = 1
),

selected_period_platform_distribution AS (
  SELECT
    campaign,
    campaign_detail,
    sp.platform,
    COUNT(DISTINCT sp.user_id) AS selected_period_platform_users
  FROM selected_period_user_platform sp
  GROUP BY campaign, campaign_detail, sp.platform
),

new_subs AS (
  SELECT
    cu.campaign_start_date AS day,
    cu.campaign,
    cu.campaign_detail,
    COALESCE(udp.platform, 'Unknown') AS platform,
    COUNT(DISTINCT cu.user_id) AS new_subscribers
  FROM campaign_users cu
  CROSS JOIN params p
  LEFT JOIN user_day_platform udp
    ON udp.user_id = cu.user_id
   AND udp.campaign = cu.campaign
   AND udp.campaign_detail = cu.campaign_detail
   AND udp.day = cu.campaign_start_date
  WHERE cu.campaign_start_date BETWEEN p.start_date AND p.end_date
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
    ON d.day BETWEEN cu.campaign_start_date AND DATE(cu.valid_until)
  LEFT JOIN user_day_platform udp
    ON udp.user_id = cu.user_id
   AND udp.campaign = cu.campaign
   AND udp.campaign_detail = cu.campaign_detail
   AND udp.day = d.day
  WHERE cu.status IN ('ACTIVE', 'CANCELED', 'IN_GRACE', 'ON_HOLD', 'EXPIRED')
  GROUP BY 1,2,3,4
),

total_used_users AS (
  SELECT
    d.day,
    cu.campaign,
    cu.campaign_detail,
    COALESCE(udp.platform, 'Unknown') AS platform,
    COUNT(DISTINCT cu.user_id) AS total_used_users
  FROM date_spine d
  JOIN campaign_users cu
    ON cu.campaign_start_date <= d.day
  LEFT JOIN user_day_platform udp
    ON udp.user_id = cu.user_id
   AND udp.campaign = cu.campaign
   AND udp.campaign_detail = cu.campaign_detail
   AND udp.day = d.day
  GROUP BY 1,2,3,4
),

churn AS (
  SELECT
    d.day,
    cu.campaign,
    cu.campaign_detail,
    COALESCE(udp.platform, 'Unknown') AS platform,
    COUNT(DISTINCT cu.user_id) AS churn_users
  FROM date_spine d
  JOIN campaign_users cu
    ON cu.campaign_start_date <= d.day
   AND DATE(cu.valid_until) <= d.day
  LEFT JOIN user_day_platform udp
    ON udp.user_id = cu.user_id
   AND udp.campaign = cu.campaign
   AND udp.campaign_detail = cu.campaign_detail
   AND udp.day = d.day
  WHERE cu.status IN ('EXPIRED','IN_GRACE','ON_HOLD')
  GROUP BY 1,2,3,4
),

campaign_conversion_candidates_raw AS (
  SELECT
    cu.user_id,
    cu.campaign,
    cu.campaign_detail,
    cu.promotionId,
    s2.created_at AS conversion_created_at,
    s2.valid_until AS conversion_valid_until,
    s2.amount,
    s2.amount_before_promotions,
    s2.payment_option,
    s2.applied_promotions
  FROM campaign_users cu
  JOIN `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s2
    ON cu.user_id = s2.user_id
   AND s2.created_at > cu.valid_until
   AND s2.amount > 0
   AND s2.payment_option IS NOT NULL
   AND s2.payment_option != 'PREPAID'
   AND s2.amount_before_promotions IS NOT NULL
   AND s2.amount = s2.amount_before_promotions
),

campaign_conversion_candidates AS (
  SELECT *
  FROM (
    SELECT
      *,
      ROW_NUMBER() OVER (
        PARTITION BY user_id, promotionId
        ORDER BY conversion_created_at
      ) AS rn
    FROM campaign_conversion_candidates_raw ccr
    WHERE NOT EXISTS (
      SELECT 1
      FROM UNNEST(IFNULL(ccr.applied_promotions, [])) ap2
      WHERE ap2.promotionId = ccr.promotionId
    )
  )
  WHERE rn = 1
),

conversion_base AS (
  SELECT
    user_id,
    campaign,
    campaign_detail,
    conversion_created_at AS next_payment_date
  FROM campaign_conversion_candidates
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
   AND udp.campaign = cb.campaign
   AND udp.campaign_detail = cb.campaign_detail
   AND udp.day = DATE(cb.next_payment_date)
  WHERE DATE(cb.next_payment_date) BETWEEN p.start_date AND p.end_date
  GROUP BY 1,2,3,4
),

watch_metrics AS (
  SELECT
    wb.day,
    wb.campaign,
    wb.campaign_detail,
    COALESCE(udp.platform, 'Unknown') AS platform,
    COUNT(DISTINCT wb.user_id) AS unique_watchers,
    SUM(wb.watch_time_second) AS total_watch_time,
    COUNT(*) AS daily_watches,
    COUNT(DISTINCT IF(wb.watch_time_second > 0, wb.user_id, NULL)) AS measured_watchers,
    SAFE_DIVIDE(
      SUM(wb.watch_time_second),
      COUNT(DISTINCT IF(wb.watch_time_second > 0, wb.user_id, NULL))
    ) AS avg_user_watch_time
  FROM watch_base wb
  LEFT JOIN user_day_platform udp
    ON udp.user_id = wb.user_id
   AND udp.campaign = wb.campaign
   AND udp.campaign_detail = wb.campaign_detail
   AND udp.day = wb.day
  GROUP BY 1,2,3,4
),

watch_daily_summary AS (
  SELECT
    wb.day,
    wb.campaign,
    wb.campaign_detail,
    COUNT(DISTINCT wb.user_id) AS daily_unique_watchers,
    COUNT(DISTINCT IF(wb.watch_time_second > 0, wb.user_id, NULL)) AS daily_measured_watchers,
    SUM(wb.watch_time_second) AS daily_total_watch_time,
    SAFE_DIVIDE(
      SUM(wb.watch_time_second),
      COUNT(DISTINCT IF(wb.watch_time_second > 0, wb.user_id, NULL))
    ) AS daily_avg_user_watch_time
  FROM watch_base wb
  GROUP BY wb.day, wb.campaign, wb.campaign_detail
)

SELECT
  d.day,
  c.campaign,
  c.campaign_detail,
  p.platform,

  COALESCE(tu.total_used_users, 0)   AS total_used_users,
  COALESCE(ns.new_subscribers, 0)    AS new_subscribers,
  COALESCE(a.active_subscribers, 0)  AS active_subscribers,
  COALESCE(ch.churn_users, 0)        AS churn_users,
  COALESCE(cd.conversions, 0)        AS conversions,

  COALESCE(w.unique_watchers, 0)     AS unique_watchers,
  COALESCE(w.total_watch_time, 0)    AS total_watch_time,
  COALESCE(w.daily_watches, 0)       AS daily_watches,
  w.measured_watchers,
  w.avg_user_watch_time,

  /* Use this field for the platform donut with aggregation SUM or MAX. */
  IF(
    d.day = prm.end_date,
    sppd.selected_period_platform_users,
    NULL
  ) AS selected_period_platform_users,

  /*
    Platform-independent daily anchors. They are populated on only one
    platform row so SUM remains safe when platform is not a chart dimension.
  */
  IF(
    p.platform = 'Unknown' AND sdc.day IS NOT NULL,
    COALESCE(wds.daily_unique_watchers, 0),
    NULL
  ) AS daily_unique_watchers_anchor,
  IF(
    p.platform = 'Unknown' AND sdc.day IS NOT NULL,
    wds.daily_measured_watchers,
    NULL
  ) AS daily_measured_watchers_anchor,
  IF(
    p.platform = 'Unknown' AND sdc.day IS NOT NULL,
    COALESCE(wds.daily_total_watch_time, 0),
    NULL
  ) AS daily_total_watch_time_anchor,
  IF(
    p.platform = 'Unknown' AND sdc.day IS NOT NULL,
    wds.daily_avg_user_watch_time,
    NULL
  ) AS daily_avg_user_watch_time_anchor,

  sdc.day IS NOT NULL AS streaming_data_available,
  COALESCE(sdc.source_event_rows, 0) AS streaming_source_event_rows,
  COALESCE(sdc.source_measured_rows, 0) AS streaming_source_measured_rows

FROM date_spine d
CROSS JOIN params prm
CROSS JOIN campaigns c
CROSS JOIN platforms p
LEFT JOIN total_used_users tu
  ON d.day = tu.day
 AND c.campaign = tu.campaign
 AND c.campaign_detail = tu.campaign_detail
 AND p.platform = tu.platform
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
LEFT JOIN selected_period_platform_distribution sppd
  ON c.campaign = sppd.campaign
 AND c.campaign_detail = sppd.campaign_detail
 AND p.platform = sppd.platform
LEFT JOIN watch_daily_summary wds
  ON d.day = wds.day
 AND c.campaign = wds.campaign
 AND c.campaign_detail = wds.campaign_detail
LEFT JOIN streaming_day_coverage sdc
  ON d.day = sdc.day

ORDER BY 1,2,3,4;
