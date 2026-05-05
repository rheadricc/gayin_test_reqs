
-- İçeriğinkendi zamanında bölüm bazlı ne kadar izlendiğini ve trendini görmek için sorgu
-- Kullanılan tablolar:
--   Backoffice_metadata.ContentMetaData                        : içeriklerin metadata bilgileri (video adı, bölüm numarası vb.)
--   looker_report.content_report_streaming_V2                  : izlenme kayıtları (event bazlı)
--   microgain-9f959.looker_report.mapping_users_with_pseudo_id_clean : user_id ↔ user_pseudo_id eşleşme tablosu
WITH  
-- İçerik metadata bilgilerini alıyoruz
contentsnew AS (
  SELECT
    *
  FROM `Backoffice_metadata.ContentMetaData`
),
-- Belirtilen tarih aralığındaki izlenme eventlerini çekiyoruz
watches AS (
  SELECT
    event_date,      -- izlenme tarihi
    datetime_ist,    -- izlenme zamanı (IST timezone)
    video_id,        -- izlenen video id
    user_pseudo_id,  -- GA tarafından atanan kullanıcı id
    ga_session_id,   -- session id
    user_id          -- sistem kullanıcı id
  FROM `looker_report.content_report_streaming_V2`
  WHERE 
    event_date >= '2025-06-20' 
    AND event_date <= '2025-06-21'
    AND unique_playlistid = 'yu9c9jcjRz3KVju7fABzBYPp' -- İncelenen içerik: Modern Kadın
)
-- Final sorgu: bölüm bazlı izlenmeleri ve kullanıcı eşleşmelerini listeliyoruz
SELECT
  DISTINCT
  w.event_date,       -- izlenme tarihi
  w.user_pseudo_id,   -- pseudo kullanıcı id
  w.ga_session_id,    -- session id
  c.video_name,       -- video adı
  c.EpisodeNumber,    -- bölüm numarası
  IFNULL(w.user_id, mu.mapped_user_id) AS user_id -- user_id eşleşmesi (öncelik event tablosu, yoksa mapping tablosu)
FROM watches w
JOIN contentsnew c 
     ON w.video_id = c.video_id -- video metadata ile eşleştirme
LEFT JOIN `microgain-9f959.looker_report.mapping_users_with_pseudo_id_clean` mu 
     ON w.user_pseudo_id = mu.user_pseudo_id; -- pseudo id ↔ gerçek user id eşleştirmesi
