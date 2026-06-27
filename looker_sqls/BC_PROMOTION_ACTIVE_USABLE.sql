-- BC_PROMOTION_ACTIVE_USABLE
-- Looker Studio params:
-- @DS_START_DATE , @DS_END_DATE -> format: YYYYMMDD

-- Conversion mantığı güncellendi:
-- Kullanıcı kampanya kodunu kullandıktan sonra,
-- kampanyalı dönemi bittikten sonraki ilk ücretli ödemesinde
-- artık aynı kampanya promosyonundan yararlanmıyorsa
-- ve ödeme indirimsizse conversion sayılır.

WITH params AS (
  SELECT
    GREATEST(PARSE_DATE('%Y%m%d', @DS_START_DATE), DATE '2026-01-01') AS start_date,
    PARSE_DATE('%Y%m%d', @DS_END_DATE) AS end_date
),

promo_map AS (
  SELECT DISTINCT
    p.promotionId,
    COALESCE(NULLIF(TRIM(p.name), ''), NULLIF(TRIM(p.promotionDescription), ''), p.promotionId) AS campaign
  FROM `microgain-9f959.Backoffice_metadata.bo_promotions` p
  WHERE p.promotionId IS NOT NULL
    AND UPPER(p.type) IN ('MASS','UNIQUE','USER_GROUP','PREPAID')
),

subs_campaign_history AS (
  SELECT *
  FROM (
    SELECT
      s.user_id,
      s.created_at,
      s.valid_until,
      s.status,
      s.amount,
      s.amount_before_promotions,
      s.payment_option,
      s.free_trial_end_date,
      ap.promotionId,
      pm.campaign,
      ROW_NUMBER() OVER (
        PARTITION BY s.user_id
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
      SAFE_CAST(eau.created_at AS TIMESTAMP) AS created_at,
      SAFE_CAST(eau.valid_until AS TIMESTAMP) AS valid_until,
      eau.status,
      CAST(NULL AS INT64) AS amount,
      CAST(NULL AS INT64) AS amount_before_promotions,
      CAST(NULL AS STRING) AS payment_option,
      CAST(NULL AS TIMESTAMP) AS free_trial_end_date,
      pm.promotionId,
      pm.campaign,
      ROW_NUMBER() OVER (
        PARTITION BY eau.user_id
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
      SAFE_CAST(eau.valid_until AS TIMESTAMP) AS valid_until,
      eau.status,
      ROW_NUMBER() OVER (
        PARTITION BY eau.user_id
        ORDER BY SAFE_CAST(eau.valid_until AS TIMESTAMP) DESC
      ) AS rn
    FROM `microgain-9f959.looker_report.elastic_active_user` eau
    CROSS JOIN params p
    WHERE SAFE_CAST(eau.created_at AS TIMESTAMP) <= TIMESTAMP(p.end_date)
  )
  WHERE rn = 1
),

campaign_users AS (
  SELECT
    cub.user_id,
    cub.created_at,
    COALESCE(ec.valid_until, cub.valid_until) AS valid_until,
    COALESCE(ec.status, cub.status) AS status,
    cub.amount,
    cub.amount_before_promotions,
    cub.payment_option,
    cub.free_trial_end_date,
    cub.promotionId,
    cub.campaign
  FROM (
    SELECT * FROM subs_campaign_history
    UNION ALL
    SELECT * FROM elastic_campaign_history ech
    WHERE NOT EXISTS (
      SELECT 1 FROM subs_campaign_history sch WHERE sch.user_id = ech.user_id
    )
  ) cub
  LEFT JOIN elastic_current ec
    ON cub.user_id = ec.user_id
),

campaign_users_distinct AS (
  SELECT DISTINCT
    user_id,
    campaign,
    promotionId,
    created_at,
    valid_until,
    status,
    amount,
    amount_before_promotions,
    payment_option,
    free_trial_end_date
  FROM campaign_users
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
  JOIN campaign_users_distinct cu
    ON cr.user_id = cu.user_id
  CROSS JOIN params p
  WHERE cr.event_date BETWEEN p.start_date AND p.end_date
),

user_platform AS (
  SELECT user_id, platform
  FROM (
    SELECT
      user_id,
      platform,
      SUM(watch_time_second) AS wt,
      ROW_NUMBER() OVER (
        PARTITION BY user_id
        ORDER BY SUM(watch_time_second) DESC
      ) AS rn
    FROM watch_base
    GROUP BY 1,2
  )
  WHERE rn = 1
),

total_used_users AS (
  SELECT
    cu.campaign,
    COALESCE(up.platform, 'Unknown') AS platform,
    COUNT(DISTINCT cu.user_id) AS total_used_users
  FROM campaign_users_distinct cu
  CROSS JOIN params p
  LEFT JOIN user_platform up
    ON cu.user_id = up.user_id
  WHERE DATE(cu.created_at) <= p.end_date
  AND cu.status != 'NONE'
  GROUP BY 1,2
),

new_subs AS (
  SELECT
    cu.campaign,
    COALESCE(up.platform, 'Unknown') AS platform,
    COUNT(DISTINCT cu.user_id) AS new_subscribers
  FROM campaign_users_distinct cu
  CROSS JOIN params p
  LEFT JOIN user_platform up ON cu.user_id = up.user_id
  WHERE DATE(cu.created_at) = p.end_date
  GROUP BY 1,2
),

active_subs AS (
  SELECT
    cu.campaign,
    COALESCE(up.platform, 'Unknown') AS platform,
    COUNT(DISTINCT cu.user_id) AS active_subscribers
  FROM campaign_users_distinct cu
  CROSS JOIN params p
  LEFT JOIN user_platform up ON cu.user_id = up.user_id
  WHERE DATE(cu.created_at) <= p.end_date
    AND DATE(cu.valid_until) >= p.end_date
    AND cu.status IN ('ACTIVE', 'CANCELED', 'IN_GRACE', 'ON_HOLD', 'EXPIRED')
  GROUP BY 1,2
),

churn AS (
  SELECT
    cu.campaign,
    COALESCE(up.platform, 'Unknown') AS platform,
    COUNT(DISTINCT cu.user_id) AS churn_users
  FROM campaign_users_distinct cu
  CROSS JOIN params p
  LEFT JOIN user_platform up ON cu.user_id = up.user_id
  WHERE DATE(cu.valid_until) <= p.end_date
    AND cu.status IN ('ON_HOLD','IN_GRACE', 'EXPIRED')
  GROUP BY 1,2
),

campaign_conversion_candidates_raw AS (
  SELECT
    cu.user_id,
    cu.campaign,
    cu.promotionId,
    s2.created_at AS conversion_created_at,
    s2.valid_until AS conversion_valid_until,
    s2.amount,
    s2.amount_before_promotions,
    s2.payment_option,
    s2.applied_promotions
  FROM campaign_users_distinct cu
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
    conversion_created_at AS next_payment_date
  FROM campaign_conversion_candidates
),

conversions AS (
  SELECT
    cb.campaign,
    COALESCE(up.platform, 'Unknown') AS platform,
    COUNT(DISTINCT cb.user_id) AS conversions
  FROM conversion_base cb
  CROSS JOIN params p
  LEFT JOIN user_platform up
    ON cb.user_id = up.user_id
  WHERE DATE(cb.next_payment_date) <= p.end_date
  GROUP BY 1,2
),

watch_metrics AS (
  SELECT
    cu.campaign,
    COALESCE(up.platform, 'Unknown') AS platform,
    COUNT(DISTINCT wb.user_id) AS unique_watchers,
    SUM(wb.watch_time_second) AS total_watch_time,
    SAFE_DIVIDE(COUNT(*), DATE_DIFF(p.end_date, p.start_date, DAY) + 1) AS daily_watches,
    SAFE_DIVIDE(SUM(wb.watch_time_second), COUNT(DISTINCT wb.user_id)) AS avg_user_watch_time
  FROM watch_base wb
  JOIN campaign_users_distinct cu ON wb.user_id = cu.user_id
  LEFT JOIN user_platform up ON wb.user_id = up.user_id
  CROSS JOIN params p
  GROUP BY 1,2,p.start_date,p.end_date
),

campaign_platforms AS (
  SELECT pm.campaign, pl.platform
  FROM (SELECT DISTINCT campaign FROM promo_map) pm
  CROSS JOIN platforms pl
)

SELECT
  cp.campaign,
  cp.platform,

  COALESCE(tu.total_used_users, 0) AS total_used_users,
  COALESCE(a.active_subscribers, 0) AS active_subscribers,
  COALESCE(ns.new_subscribers, 0) AS new_subscribers,
  COALESCE(ch.churn_users, 0) AS churn_users,
  COALESCE(cv.conversions, 0) AS conversions,
  COALESCE(w.unique_watchers, 0) AS unique_watchers,
  COALESCE(w.total_watch_time, 0) AS total_watch_time,
  COALESCE(w.daily_watches, 0) AS daily_watches,
  COALESCE(w.avg_user_watch_time, 0) AS avg_user_watch_time

FROM campaign_platforms cp
LEFT JOIN total_used_users tu USING (campaign, platform)
LEFT JOIN active_subs a USING (campaign, platform)
LEFT JOIN new_subs ns USING (campaign, platform)
LEFT JOIN churn ch USING (campaign, platform)
LEFT JOIN conversions cv USING (campaign, platform)
LEFT JOIN watch_metrics w USING (campaign, platform)

WHERE COALESCE(tu.total_used_users, 0) > 1

ORDER BY active_subscribers DESC, new_subscribers DESC;
