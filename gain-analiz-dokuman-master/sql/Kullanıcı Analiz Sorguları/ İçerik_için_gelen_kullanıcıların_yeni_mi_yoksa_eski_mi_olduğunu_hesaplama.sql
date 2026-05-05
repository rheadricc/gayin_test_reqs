
-- İçerikiçin gelen kullanıcıların yeni mi yoksa eski mi olduğunu hesaplama
-- Kullanılan tablo:
--   looker_report.content_report_streaming_V2 : içerik izlenme kayıtları
WITH
-- Kullanıcıların içerikteki ilk izleme zamanını buluyoruz
firstwatch AS (
  SELECT
    MIN(datetime_ist) AS first_timestamp, -- ilk izleme tarihi
    user_pseudo_id, -- cihaz bazlı kullanıcı id
    user_id         -- sistem kullanıcı id
  FROM `looker_report.content_report_streaming_V2`
  GROUP BY 2,3
),
-- Belirlenen tarih aralığındaki kullanıcıların ilk izleyici olup olmadığını kontrol ediyoruz
lasttab AS (
  SELECT
    DISTINCT
    c.user_id,
    c.user_pseudo_id,
    fw.user_id        AS fw_user_id,
    fw.user_pseudo_id AS fw_user_pseudo_id
  FROM `looker_report.content_report_streaming_V2` c
  LEFT JOIN firstwatch fw 
         ON c.user_id = fw.user_id 
        AND c.user_pseudo_id = fw.user_pseudo_id
        AND c.datetime_ist = fw.first_timestamp
  WHERE 
    -- İncelenecek tarih aralığı
    c.event_date >= '2025-06-20' 
    AND c.event_date <= '2025-06-21'
    
    -- İncelenen içerik playlist ID’si
    AND c.unique_playlistid = 'yu9c9jcjRz3KVju7fABzBYPp'
)
-- Final sorgu: Kullanıcıların yeni mi eski mi olduğunu hesapla
SELECT
  COUNTIF(lasttab.fw_user_pseudo_id IS NOT NULL OR fw_user_id IS NOT NULL) AS coming_new, -- ilk defa gelen kullanıcılar
  COUNTIF(fw_user_pseudo_id IS NULL AND fw_user_id IS NULL)                 AS old_user   -- daha önce gelen kullanıcılar
FROM lasttab;
