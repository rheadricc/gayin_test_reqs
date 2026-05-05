-- GENEL UYGULAMA VE WEB İÇİN PAGE VİEW TRAFİK SORGUSU

WITH
params AS (
  SELECT
    'Europe/Istanbul' AS tz,
    CURRENT_DATE('Europe/Istanbul') AS today,
    r'^https://www\.gain\.tv(/(home)?([?#].*)?)?$' AS homepage_re  -- https://www.gain.tv/ veya /home (+utm/#)
),
last_sat AS (
  SELECT
    DATE_SUB(p.today, INTERVAL MOD(EXTRACT(DAYOFWEEK FROM p.today) - 7 + 7, 7) DAY) AS last_saturday,
    p.tz, p.today, p.homepage_re
  FROM params p
),
win AS (
  SELECT
    DATE_SUB(last_saturday, INTERVAL 7 DAY) AS start_date,  -- geçen haftanın cumartesisi
    today AS end_date,
    tz, homepage_re
  FROM last_sat
),

-- 1) WEB: GA4 page_view + homepage URL (events in 236816681)
web AS (
  SELECT
    DATE(DATETIME(TIMESTAMP_MICROS(event_timestamp), w.tz)) AS event_date_tr,
    'web' AS channel
  FROM `microgain-9f959.analytics_236816681.events_*`, win w
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', w.start_date)
                          AND FORMAT_DATE('%Y%m%d', w.end_date)
    AND event_name = 'page_view'
    AND REGEXP_CONTAINS(
          (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location'),
          w.homepage_re
        )
),

-- 2) MOBİL APP: screen_view + firebase_screen_class = 'MainActivity' (events in 236816681)
mobile AS (
  SELECT
    DATE(DATETIME(TIMESTAMP_MICROS(event_timestamp), w.tz)) AS event_date_tr,
    'mobile_app' AS channel
  FROM `microgain-9f959.analytics_236816681.events_*`, win w
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', w.start_date)
                          AND FORMAT_DATE('%Y%m%d', w.end_date)
    AND event_name = 'screen_view'
    AND (SELECT value.string_value FROM UNNEST(event_params)
         WHERE key = 'firebase_screen_class') = 'MainActivity'
),

-- 3) SMART TV (Android/Apple TV’ler): screen_view + 'TVMainActivity' (events in 236816681)
tv_core AS (
  SELECT
    DATE(DATETIME(TIMESTAMP_MICROS(event_timestamp), w.tz)) AS event_date_tr,
    'smart_tv' AS channel
  FROM `microgain-9f959.analytics_236816681.events_*`, win w
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', w.start_date)
                          AND FORMAT_DATE('%Y%m%d', w.end_date)
    AND event_name = 'screen_view'
    AND (SELECT value.string_value FROM UNNEST(event_params)
         WHERE key = 'firebase_screen_class') = 'TVMainActivity'
),

-- 4) SMART TV (LG/Vestel/Arçelik): ayrı dataset (analytics_271525484), yine 'TVMainActivity'
tv_oem AS (
  SELECT
    DATE(DATETIME(TIMESTAMP_MICROS(event_timestamp), w.tz)) AS event_date_tr,
    'smart_tv' AS channel
  FROM `microgain-9f959.analytics_271525484.events_*`, win w
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', w.start_date)
                          AND FORMAT_DATE('%Y%m%d', w.end_date)
    AND event_name = 'screen_view'
    AND (SELECT value.string_value FROM UNNEST(event_params)
         WHERE key = 'firebase_screen_class') = 'TVMainActivity'
),

unioned AS (
  SELECT * FROM web
  UNION ALL
  SELECT * FROM mobile
  UNION ALL
  SELECT * FROM tv_core
  UNION ALL
  SELECT * FROM tv_oem
)

-- Toplam (kanalsız)
SELECT
  event_date_tr,
  COUNT(*) AS homepage_main_screen_total
FROM unioned
GROUP BY event_date_tr
ORDER BY event_date_tr;

-- ---- Kanala göre bakmak için ----
-- SELECT
--   event_date_tr,
--   channel,
--   COUNT(*) AS homepage_main_screen
-- FROM unioned
-- GROUP BY event_date_tr, channel
-- ORDER BY event_date_tr, channel;