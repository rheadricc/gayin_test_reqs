
-- Haftalık İçerik İzlenme Karşılaştırma Raporu
-- Amaç:
-- Belirli bir tarih aralığındaki (DS_START_DATE - DS_END_DATE)
-- içerik izlenmelerini ve kullanıcı sayılarını hesaplamak
-- ve önceki eş uzunluktaki dönem ile karşılaştırmak.
-- ========================================
-- 🔹 Tarih parametreleri tanımlanıyor
DECLARE DS_START_DATE STRING DEFAULT '20250808';  -- Başlangıç tarihi (YYYYMMDD formatında)
DECLARE DS_END_DATE STRING DEFAULT '20250814';    -- Bitiş tarihi (YYYYMMDD formatında)
-- ========================================
-- FW Selected Date Analizi
-- ========================================
WITH
-- 1️⃣ İçerik bilgilerini temel tablodan çekiyoruz
contents_info AS (
  SELECT
    displayname,          -- İçerik adı
    playlistid,           -- Playlist kimliği
    video_name,           -- Video adı
    contenttype_id,       -- İçerik türü (ör: film, dizi, klip)
    genres,               -- Tür bilgisi (ör: drama, komedi)
    video_id              -- Benzersiz video kimliği
  FROM `Backoffice_metadata.ContentMetaData`
),
-- 2️⃣ Seçilen dönem izlenme verileri (DS_START_DATE - DS_END_DATE)
selected_period_watch AS (
  SELECT
    c.displayname,
    c.contenttype_id,
    c.genres,
    COUNT(DISTINCT CONCAT(user_id, v.video_id, ga_session_id)) AS view_count, -- Toplam izlenme sayısı
    COUNT(DISTINCT user_id) AS usr_cnt                                         -- Benzersiz kullanıcı sayısı
  FROM `microgain-9f959.looker_report.content_report_streaming_V2` v
  JOIN contents_info c 
    ON v.video_id = c.video_id
  WHERE event_date BETWEEN DATE(PARSE_DATE('%Y%m%d', DS_START_DATE)) 
                       AND DATE(PARSE_DATE('%Y%m%d', DS_END_DATE))
    AND user_id IS NOT NULL
  GROUP BY 1,2,3
),
-- 3️⃣ Önceki dönem izlenme verileri
-- Seçilen aralığın uzunluğu kadar geriye gidilerek oluşturulur.
prev_period_watch AS (
  SELECT
    c.displayname,
    c.contenttype_id,
    c.genres,
    COUNT(DISTINCT CONCAT(user_id, v.video_id, ga_session_id)) AS view_count, -- Önceki dönem izlenme sayısı
    COUNT(DISTINCT user_id) AS usr_cnt                                         -- Önceki dönem kullanıcı sayısı
  FROM `microgain-9f959.looker_report.content_report_streaming_V2` v
  JOIN contents_info c 
    ON v.video_id = c.video_id
  WHERE event_date 
    BETWEEN 
      DATE_SUB(PARSE_DATE('%Y%m%d', DS_START_DATE), 
        INTERVAL (CAST(DS_END_DATE AS INT64) - CAST(DS_START_DATE AS INT64)) + 1 DAY)
      AND 
      DATE_SUB(PARSE_DATE('%Y%m%d', DS_END_DATE), 
        INTERVAL (CAST(DS_END_DATE AS INT64) - CAST(DS_START_DATE AS INT64)) + 1 DAY)
    AND user_id IS NOT NULL
  GROUP BY 1,2,3
)
-- 4️⃣ Sonuçların birleştirilmesi ve karşılaştırma metrikleri
SELECT 
  COALESCE(spw.displayname, ppw.displayname) AS displayname,         -- İçerik adı
  COALESCE(spw.contenttype_id, ppw.contenttype_id) AS category,      -- İçerik kategorisi
  COALESCE(spw.genres, ppw.genres) AS genres,                        -- Tür bilgisi
  -- Seçilen dönem metrikleri
  spw.usr_cnt AS selected_period_user_cnt,                           -- Kullanıcı sayısı
  spw.view_count AS selected_period_view_cnt,                        -- İzlenme sayısı
  -- Önceki dönem metrikleri
  ppw.usr_cnt AS prev_period_user_cnt,                               -- Önceki dönem kullanıcı sayısı
  ppw.view_count AS prev_period_view_cnt,                            -- Önceki dönem izlenme sayısı
  -- Fark ve yüzde değişim hesaplamaları
  (spw.usr_cnt - ppw.usr_cnt) AS usr_cnt_diff,                       -- Kullanıcı farkı
  ROUND((spw.usr_cnt - ppw.usr_cnt) / ppw.usr_cnt * 100, 2) AS usr_cnt_chg_perc,  -- Kullanıcı % değişimi
  (spw.view_count - ppw.view_count) AS view_count_diff,              -- İzlenme farkı
  ROUND((spw.view_count - ppw.view_count) / ppw.view_count * 100, 2) AS view_cnt_chg_perc -- İzlenme % değişimi
FROM selected_period_watch spw
LEFT JOIN prev_period_watch ppw 
  ON spw.displayname = ppw.displayname;
