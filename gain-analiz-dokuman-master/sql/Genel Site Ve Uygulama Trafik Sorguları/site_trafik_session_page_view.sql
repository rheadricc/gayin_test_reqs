
-- İSTENİLEN PERİODDA SİTE TRAFİĞİ HOMEPAGE_VİEWS VE SESSİON BAZINDA PAGE VİEW VS ANALİZİ İÇİN SORGU

-- Günlük metrik: page_view, homepage page_view, unique users, session_starts
-- Tarihler inclusive. Istanbul timezone kullanılıyor.
WITH
params AS (
  SELECT
    'Europe/Istanbul' AS tz,
    DATE '2025-04-24' AS a1_start, DATE '2025-04-27' AS a1_end,
    DATE '2025-09-26' AS a2_start, DATE '2025-09-29' AS a2_end,
    r'^https://www\.gain\.tv(/(home)?([?#].*)?)?$' AS homepage_re
),
-- Normalize events and extract common params
events_flat AS (
  SELECT
    DATE(TIMESTAMP_MICROS(event_timestamp), p.tz) AS event_date,
    COALESCE(user_id, user_pseudo_id) AS user_id_normalized,
    event_name,
    -- extract page_location / page_path / link_url where available
    (SELECT value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'page_location' LIMIT 1) AS page_location,
    (SELECT value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'link_url' LIMIT 1) AS link_url,
    (SELECT CAST(value.int_value AS STRING) FROM UNNEST(event_params) ep WHERE ep.key = 'ga_session_id' LIMIT 1) AS ga_session_id,
    (SELECT value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'page_title' LIMIT 1) AS page_title
  FROM `microgain-9f959.analytics_236816681.events_*`, params p
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', LEAST(p.a1_start, p.a2_start))
                          AND FORMAT_DATE('%Y%m%d', GREATEST(p.a1_end, p.a2_end))
),
-- mark homepage views and assign period label
annotated AS (
  SELECT
    event_date,
    user_id_normalized,
    event_name,
    page_location,
    link_url,
    ga_session_id,
    page_title,
    CASE
      WHEN REGEXP_CONTAINS(COALESCE(page_location, link_url, ''), (SELECT homepage_re FROM params)) THEN TRUE
      ELSE FALSE
    END AS is_homepage,
    CASE
      WHEN event_date BETWEEN (SELECT a1_start FROM params) AND (SELECT a1_end FROM params) THEN '2025-04-24..2025-04-27'
      WHEN event_date BETWEEN (SELECT a2_start FROM params) AND (SELECT a2_end FROM params) THEN '2025-09-26..2025-09-29'
      ELSE 'other'
    END AS period_label
  FROM events_flat
)
SELECT
  period_label,
  event_date,
  COUNTIF(event_name = 'page_view') AS page_views,
  COUNTIF(event_name = 'page_view' AND is_homepage) AS homepage_views,
  COUNT(DISTINCT user_id_normalized) AS unique_users,
  COUNTIF(event_name = 'session_start') AS session_starts, -- session sayısı için session_start eventi
  SAFE_DIVIDE(COUNTIF(event_name = 'page_view'), NULLIF(COUNTIF(event_name = 'session_start'),0)) AS avg_pageviews_per_session
FROM annotated
WHERE period_label IN ('2025-04-24..2025-04-27','2025-09-26..2025-09-29')
GROUP BY period_label, event_date
ORDER BY period_label, event_date;


------------------------------------------------------------------------------------------------------------------------------------------------

--- Belirli bir ay periyodunda bakmak için


-- Günlük metrik: page_view, homepage page_view, unique users, session_starts
-- Dönem: 2025-09-01..2025-09-30 (dahil). Istanbul timezone.
WITH
params AS (
  SELECT
    'Europe/Istanbul' AS tz,
    DATE '2025-09-01' AS month_start,
    DATE '2025-09-30' AS month_end,
    CURRENT_DATE('Europe/Istanbul') AS today_tr,
    r'^https://www\.gain\.tv(/(home)?([?#].*)?)?$' AS homepage_re
),

-- 1) Tamamlanmış günler (events_*)
events_hist AS (
  SELECT
    DATE(TIMESTAMP_MICROS(event_timestamp), p.tz) AS event_date,
    COALESCE(user_id, user_pseudo_id) AS user_id_normalized,
    event_name,
    (SELECT value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'page_location' LIMIT 1) AS page_location,
    (SELECT value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'link_url' LIMIT 1) AS link_url,
    (SELECT CAST(value.int_value AS STRING) FROM UNNEST(event_params) ep WHERE ep.key = 'ga_session_id' LIMIT 1) AS ga_session_id,
    (SELECT value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'page_title' LIMIT 1) AS page_title
  FROM `microgain-9f959.analytics_236816681.events_*`, params p
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', p.month_start)
                          AND FORMAT_DATE('%Y%m%d', LEAST(p.month_end, DATE_SUB(p.today_tr, INTERVAL 1 DAY)))
    AND DATE(TIMESTAMP_MICROS(event_timestamp), p.tz) BETWEEN p.month_start AND LEAST(p.month_end, DATE_SUB(p.today_tr, INTERVAL 1 DAY))
),

-- 2) Bugün kısmi gün ise (events_intraday_*), sadece bugün
events_today AS (
  SELECT
    DATE(TIMESTAMP_MICROS(event_timestamp), p.tz) AS event_date,
    COALESCE(user_id, user_pseudo_id) AS user_id_normalized,
    event_name,
    (SELECT value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'page_location' LIMIT 1) AS page_location,
    (SELECT value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'link_url' LIMIT 1) AS link_url,
    (SELECT CAST(value.int_value AS STRING) FROM UNNEST(event_params) ep WHERE ep.key = 'ga_session_id' LIMIT 1) AS ga_session_id,
    (SELECT value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'page_title' LIMIT 1) AS page_title
  FROM `microgain-9f959.analytics_236816681.events_intraday_*`, params p
  WHERE _TABLE_SUFFIX = FORMAT_DATE('%Y%m%d', p.today_tr)
    AND p.today_tr BETWEEN p.month_start AND p.month_end
),

events_flat AS (
  SELECT * FROM events_hist
  UNION ALL
  SELECT * FROM events_today
),

annotated AS (
  SELECT
    event_date,
    user_id_normalized,
    event_name,
    page_location,
    link_url,
    ga_session_id,
    page_title,
    REGEXP_CONTAINS(COALESCE(page_location, link_url, ''), (SELECT homepage_re FROM params)) AS is_homepage
  FROM events_flat
)

SELECT
  event_date,
  COUNTIF(event_name = 'page_view') AS page_views,
  COUNTIF(event_name = 'page_view' AND is_homepage) AS homepage_views,
  COUNT(DISTINCT user_id_normalized) AS unique_users,
  COUNTIF(event_name = 'session_start') AS session_starts,
  SAFE_DIVIDE(COUNTIF(event_name = 'page_view'), NULLIF(COUNTIF(event_name = 'session_start'), 0)) AS avg_pageviews_per_session
FROM annotated
GROUP BY event_date
ORDER BY event_date;

