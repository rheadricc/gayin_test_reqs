
-- İçeriği_izleyenlerin_gender_dağılımı
-- Kullanılan tablolar:
--   looker_report.content_report_streaming_V2 : içerik izlenme kayıtları
--   gain_model_prod.prod_dim_user_raw          : kullanıcı bilgileri (gender dahil)
WITH
-- İçeriği izleyen kullanıcıları buluyoruz
watchers AS (
  SELECT
    DISTINCT 
    user_id,    -- kullanıcı id
    g_country,  -- ülke bilgisi
    g_city      -- şehir bilgisi
  FROM `looker_report.content_report_streaming_V2`
  WHERE 
    event_date >= '2025-06-19' -- başlangıç tarihi
    AND unique_playlistid = 'yu9c9jcjRz3KVju7fABzBYPp' -- analiz edilen içerik ID'si
),
-- Kullanıcıların gender bilgilerini alıyoruz
userGender AS (
  SELECT
    userid, -- kullanıcı id
    gender  -- kullanıcı cinsiyet bilgisi
  FROM `gain_model_prod.prod_dim_user_raw`
)
-- Final sorgu: içerik izleyen kullanıcıların gender dağılımını hesapla
SELECT
  COUNT(DISTINCT w.user_id) AS usr_cnt, -- her gender için benzersiz kullanıcı sayısı
  ug.gender                 AS gender   -- cinsiyet bilgisi
FROM watchers w
JOIN userGender ug 
     ON w.user_id = ug.userid -- kullanıcı id eşleşmesi
GROUP BY 2; -- gender'a göre gruplama

