
-- Session Count Analizi
-- Amaç: Günlük toplam session sayısı ve session_start event sayısını hesaplamak
-- Kullanılan tablo:
--   analytics_236816681.events_* : GA4 event verisi
WITH
-- 1. Sadece 'session_start' eventlerini sayıyoruz
session_start AS (
  SELECT
    PARSE_DATE('%Y%m%d', event_date) AS session_date, -- tarih
    FORMAT_DATE('%A', PARSE_DATE('%Y%m%d', event_date)) AS gun_adi, -- haftanın günü
    COUNT(DISTINCT CONCAT(
      user_pseudo_id, "-", 
      CAST((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS STRING)
    )) AS session_start_cnt -- session_start sayısı
  FROM `analytics_236816681.events_*`
  WHERE event_name = 'session_start'
    AND _TABLE_SUFFIX BETWEEN '20250801' AND '20250814' -- analiz aralığı
  GROUP BY 1,2
),
-- 2. Tüm session’ları (user bazlı) sayıyoruz
all_sessions AS (
  SELECT
    PARSE_DATE('%Y%m%d', event_date) AS session_date,
    FORMAT_DATE('%A', PARSE_DATE('%Y%m%d', event_date)) AS gun_adi,
    COUNT(DISTINCT CONCAT(
      user_pseudo_id, "-", 
      CAST((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS STRING)
    )) AS all_session_cnt -- tüm session sayısı
  FROM `analytics_236816681.events_*`
  WHERE user_pseudo_id IS NOT NULL
    AND _TABLE_SUFFIX BETWEEN '20250801' AND '20250814'
  GROUP BY 1,2
)
-- 3. Session start ve toplam session sayısını birleştiriyoruz
SELECT
  ases.session_date,       -- tarih
  ases.gun_adi,           -- haftanın günü
  ss.session_start_cnt,    -- session_start event sayısı
  ases.all_session_cnt     -- tüm session sayısı
FROM all_sessions ases
LEFT JOIN session_start ss 
  ON ases.session_date = ss.session_date;
