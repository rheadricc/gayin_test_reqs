
-- Haftalık_Top_İzlenen_Karşılaştırma
-- Bu sorgu, son iki haftanın izlenme sayılarını karşılaştırır.
-- Kullanılan tablolar:
--   microgain-9f959.looker_report.content_report_streaming_V2 : içerik izlenme kayıtları
--   microgain-9f959.Backoffice_metadata.ContentMetaData        : içeriklerin meta bilgileri (isim, tür, originals bilgisi vb.)
WITH
-- Haftaların tarih parametreleri: 
-- firstweek: 16 gün önce - 9 gün önce arası
-- secondweek: 8 gün önce - 1 gün önce arası
params AS (
  SELECT CURRENT_DATE()-16 AS firstweek_start_date,
         CURRENT_DATE()-9  AS firstweek_end_date,
         CURRENT_DATE()-8  AS secondweek_start_date,
         CURRENT_DATE()-1  AS secondweek_end_date
),
-- İlk hafta izlenme sayıları
firstweek AS ( 
  SELECT 
    DISTINCT
    unique_playlistid, -- içerik (playlist) id
    COUNT(DISTINCT CONCAT(user_id,video_id,ga_session_id)) AS firstweek_watch_cnt, -- benzersiz izlenme sayısı
    ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT CONCAT(user_id,video_id,ga_session_id)) DESC) AS rn_firstweek -- sıralama
  FROM `microgain-9f959.looker_report.content_report_streaming_V2`
  WHERE event_date BETWEEN (SELECT firstweek_start_date FROM params) 
                       AND (SELECT firstweek_end_date   FROM params)
  GROUP BY 1
),
-- İkinci hafta izlenme sayıları
secondweek AS ( 
  SELECT 
    DISTINCT
    unique_playlistid, -- içerik (playlist) id
    COUNT(DISTINCT CONCAT(user_id,video_id,ga_session_id)) AS secondweek_watch_cnt, -- benzersiz izlenme sayısı
    ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT CONCAT(user_id,video_id,ga_session_id)) DESC) AS rn_secondweek -- sıralama
  FROM `microgain-9f959.looker_report.content_report_streaming_V2`
  WHERE event_date BETWEEN (SELECT secondweek_start_date FROM params) 
                       AND (SELECT secondweek_end_date   FROM params)
  GROUP BY 1
)
-- Final sorgu: iki haftanın izlenme sayılarını karşılaştırır
SELECT
  DISTINCT
  COALESCE(con.displayname,con1.displayname)         AS DisplayName,     -- içerik adı
  COALESCE(con.genres,con1.genres)                   AS Genres,          -- tür bilgisi
  COALESCE(con.contenttype_id,con1.contenttype_id)   AS ContentType,     -- içerik tipi
  COALESCE(con.IsGainOriginals,con1.IsGainOriginals) AS IsGainOriginals, -- Originals içerik mi
  firstweek_watch_cnt,  -- ilk hafta izlenme sayısı
  secondweek_watch_cnt, -- ikinci hafta izlenme sayısı
  rn_firstweek,         -- ilk hafta sıralaması
  rn_secondweek         -- ikinci hafta sıralaması
FROM firstweek fw
FULL JOIN secondweek sw 
       ON fw.unique_playlistid = sw.unique_playlistid -- hem ilk hem ikinci haftada olan içerikler birleşir
JOIN `microgain-9f959.Backoffice_metadata.ContentMetaData` con 
       ON fw.unique_playlistid = con.titleid -- ilk haftadan gelen id için metadata
JOIN `microgain-9f959.Backoffice_metadata.ContentMetaData` con1 
       ON sw.unique_playlistid = con.titleid -- ikinci haftadan gelen id için metadata
ORDER BY 5 DESC; -- ilk hafta izlenme sayısına göre sırala
