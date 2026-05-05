
-- DeviceCategory / Operating System Dağılımı
-- Amaç: Web, App ve TV üzerinden aktif olan kullanıcıların işletim sistemi dağılımını aylık bazda göstermek
-- Kullanılan tablolar:
--   analytics_236816681.events_* : Web ve App dataseti
--   analytics_271525484.events_* : TV dataseti
WITH basedata AS (
  -- 1. Web ve App dataseti
  SELECT
    DISTINCT
    event_date,
    user_id,
    device.operating_system AS operating_system
  FROM `analytics_236816681.events_*`
  WHERE _TABLE_SUFFIX >= '20250201' AND _TABLE_SUFFIX < '20250620'
  
  UNION ALL
  
  -- 2. TV dataseti
  SELECT
    DISTINCT
    event_date,
    user_id,
    device.operating_system AS operating_system
  FROM `analytics_271525484.events_*`
  WHERE _TABLE_SUFFIX >= '20250201' AND _TABLE_SUFFIX < '20250620'
)
-- 3. Kullanıcı sayısını aylık ve işletim sistemi bazında toplama
SELECT 
    COUNT(DISTINCT user_id) AS cnt_user,
    EXTRACT(MONTH FROM PARSE_DATE('%Y%m%d', event_date)) AS month,
    operating_system
FROM basedata
GROUP BY 2,3
ORDER BY 2,3;
