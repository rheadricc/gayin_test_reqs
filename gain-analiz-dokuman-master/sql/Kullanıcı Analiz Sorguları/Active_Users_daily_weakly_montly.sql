
-- Active_Users_(DAU / WAU / MAU)
-- Kullanılan tablo:
--   analytics_236816681.events_2025* : Google Analytics (GA4) event datası
WITH
-- Kullanıcı bazlı temel tablo
base AS (
  SELECT
    DISTINCT
    event_date, -- event tarihi (GA formatında: YYYYMMDD)
    -- user_id bilgisi, öncelikli olarak event kayıtlarındaki property/parametrelerden alınır.
    COALESCE(
      user_id,
      (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = "user_gid"),
      (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = "user_id"),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = "user_gid"),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = "user_id")
    ) AS user_id,
    user_pseudo_id -- GA4 tarafından otomatik atanan user id (cihaz bazlı)
  FROM `analytics_236816681.events_2025*`
)
-- Final sorgu: Aktif kullanıcıların aylık (veya günlük/haftalık) sayısı
SELECT 
  COUNT(DISTINCT user_id)        AS monthly_Active_user_id,        -- benzersiz user_id ile aktif kullanıcı sayısı
  COUNT(DISTINCT user_pseudo_id) AS monthly_Active_user_pseudo_id, -- benzersiz pseudo_id ile aktif kullanıcı sayısı
  DATE_TRUNC(PARSE_DATE('%Y%m%d', event_date), MONTH) AS month     -- kırılım: aylık
  -- Not: DATE_TRUNC parametresi değiştirilerek farklı kırılımlar alınabilir:
  --   DAY   → DAU (Daily Active Users)
  --   WEEK  → WAU (Weekly Active Users)
  --   MONTH → MAU (Monthly Active Users)
FROM base
GROUP BY 3;
