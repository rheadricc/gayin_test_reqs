-- İçeriğin kendi zamanında bölüm bazlı ne kadar izlendiğini ve trendini görmek için sorgu (ESKİ SİSTEM)
-- Kullanılan tablolar:
--   datamarts.jw_video_master_category                   : eski sistemdeki içerik metadata bilgileri (title, bölüm numarası vb.)
--   looker_report.content_report_streaming_V2            : izlenme kayıtları (event bazlı)
--   microgain-9f959.looker_report.mapping_users_with_pseudo_id_clean : user_id ↔ user_pseudo_id eşleşme tablosu
WITH  
-- İçerik metadata bilgilerini (eski sistem) alıyoruz
contentsnew AS (
  SELECT
    *
  FROM `datamarts.jw_video_master_category`
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
    event_date >= '2022-01-01' 
    AND event_date <= '2022-02-28'
    -- İncelenen içerik ID (playlist)
    -- AND unique_playlistid = 'yu9c9jcjRz3KVju7fABzBYPp' -- Modern Kadın
    AND unique_playlistid = 'fSlSfKs2' -- Gain Açık Mikrofon
)
-- Final sorgu: bölüm bazlı izlenmeleri ve kullanıcı eşleşmelerini listeliyoruz
SELECT
  DISTINCT
  w.event_date,       -- izlenme tarihi
  w.user_pseudo_id,   -- pseudo kullanıcı id
  w.ga_session_id,    -- session id
  c.title,            -- video başlığı (eski sistemde title alanı)
  c.EpisodeNumber,    -- bölüm numarası
  IFNULL(w.user_id, mu.mapped_user_id) AS user_id -- user_id eşleşmesi (öncelik event tablosu
