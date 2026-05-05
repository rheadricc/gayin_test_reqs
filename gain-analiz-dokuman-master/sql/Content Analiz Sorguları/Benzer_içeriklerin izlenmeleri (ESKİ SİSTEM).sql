-- Benzer_içeriklerin izlenmeleri (ESKİ SİSTEM)
-- Kullanılan tablolar:
--   datamarts.jw_video_master_category                   : eski sistem içerik metadata (title, episodeNumber, tags)
--   looker_report.content_report_streaming_V2            : izlenme kayıtları (event bazlı)
--   microgain-9f959.looker_report.mapping_users_with_pseudo_id_clean : user_id ↔ user_pseudo_id eşleşmesi
WITH  
-- İçerik metadata bilgilerini hazırlıyoruz (eski sistem)
contentsnew AS (
  SELECT 
    playlistId,
    videoid,
    unique_playlistId,
    title AS video_name,
    SAFE_CAST(CAST(episodeNumber AS FLOAT64) AS INT64) AS EpisodeNumber,
    STRING_AGG(DISTINCT TRIM(tag.item), ',') AS tags -- içerik etiketleri
  FROM `datamarts.jw_video_master_category`,
       UNNEST(tags.list) AS tag  -- JSON array içindeki etiketleri açıyoruz
  WHERE SAFE_CAST(CAST(episodeNumber AS FLOAT64) AS INT64) != 0 -- bölüm numarası 0 olmayan içerikler
  GROUP BY 1,2,3,4,5
),
-- Benzer içerik eşleştirme (tag bazlı)
similar_content AS (
  SELECT 
    a.playlistId        AS content_a,
    b.playlistId        AS content_b,
    a.unique_playlistId AS title_a,
    b.unique_playlistId AS title_b,
    ARRAY_AGG(DISTINCT common.tag) AS common_tags -- ortak etiketler
  FROM contentsnew a
  JOIN contentsnew b
       ON a.playlistId < b.playlistId -- self-join (aynı tablo üzerinde)
  JOIN UNNEST(SPLIT(a.tags, ',')) AS tag_a
  JOIN UNNEST(SPLIT(b.tags, ',')) AS tag_b
       ON TRIM(tag_a) = TRIM(tag_b) -- ortak tag eşleşmesi
  JOIN UNNEST([STRUCT(TRIM(tag_a) AS tag)]) AS common
  WHERE a.unique_playlistId = 'fSlSfKs2' -- referans içerik ID
  GROUP BY 1,2,3,4
)
-- Final sorgu: Benzer içeriklerin izlenme kayıtları
SELECT
  DISTINCT
  w.event_date,        -- izlenme tarihi
  w.user_pseudo_id,    -- pseudo kullanıcı id
  w.ga_session_id,     -- session id
  c.playlistId,        -- playlist id
  c.video_name,        -- video adı
  c.EpisodeNumber,     -- bölüm numarası
  IFNULL(w.user_id, mu.mapped_user_id) AS user_id -- user_id eşleşmesi
FROM `looker_report.content_report_streaming_V2` w
JOIN contentsnew c 
     ON w.video_id = c.videoid -- izlenme kayıtları ile içerik bilgisi eşleşmesi
LEFT JOIN `microgain-9f959.looker_report.mapping_users_with_pseudo_id_clean` mu 
     ON w.user_pseudo_id = mu.user_pseudo_id -- pseudo id ↔ gerçek user id eşleştirmesi
WHERE event_date BETWEEN '2022-01-01' AND '2022-02-28'
  AND w.unique_playlistId IN (
    -- sadece benzer içerikler dahil ediliyor
    SELECT title_b 
    FROM similar_content
  );
