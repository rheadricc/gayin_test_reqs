-- First Visitor Became Member Analizi
-- Amaç: İlk kez siteyi/app’i ziyaret eden kullanıcıların sonradan üyeliğe dönüştüğü kullanıcı sayısını hesaplamak
-- Kullanılan tablo:
--   analytics_236816681.events_*  : GA4 event verisi (first_visit, purchase vb.)
WITH
-- 1. İlk ziyaret tarihlerini alıyoruz
first_visits AS (
  SELECT
    user_pseudo_id,                           -- pseudo user id
    PARSE_DATE('%Y%m%d', event_date) AS first_visit_date -- ilk ziyaret tarihi
  FROM `analytics_236816681.events_*`
  WHERE event_name = 'first_visit'
    AND _TABLE_SUFFIX BETWEEN '20250801' AND '20250814' -- analiz aralığı
),
-- 2. İlk üyelik (purchase) tarihlerini alıyoruz
first_membership AS (
  SELECT
    user_pseudo_id, 
    MIN(PARSE_DATE('%Y%m%d', event_date)) AS membership_date -- ilk ödeme/üyelik tarihi
  FROM `analytics_236816681.events_*`
  WHERE event_name IN (
      'purchase',
      'in_app_purchase',
      'in_app_premium_purchase',
      'AnalyticsEventInAppPurchase'
    )
    AND user_id IS NOT NULL
    AND _TABLE_SUFFIX BETWEEN '20250701' AND '20250814' -- analiz aralığı (bir önceki dönemi kapsayabilir)
  GROUP BY user_pseudo_id
)
-- 3. İlk ziyaret eden kullanıcılar ile üyelik yapan kullanıcıları eşleştiriyoruz
SELECT
  fv.first_visit_date,  -- ilk ziyaret tarihi
  COUNT(DISTINCT fv.user_pseudo_id) AS total_first_visitors, -- toplam ilk ziyaretçi sayısı
  COUNT(DISTINCT CASE
                   WHEN fm.membership_date IS NOT NULL
                        AND fm.membership_date >= fv.first_visit_date
                   THEN fv.user_pseudo_id
                 END) AS visitors_who_became_members -- sonradan üye olan kullanıcı sayısı
FROM first_visits fv
LEFT JOIN first_membership fm
  ON fv.user_pseudo_id = fm.user_pseudo_id
GROUP BY fv.first_visit_date
ORDER BY fv.first_visit_date;
