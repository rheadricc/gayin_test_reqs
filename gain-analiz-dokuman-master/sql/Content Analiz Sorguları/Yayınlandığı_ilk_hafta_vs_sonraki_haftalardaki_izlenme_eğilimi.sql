
-- Yayınlandığı_ilk_hafta_vs_sonraki_haftalardaki_izlenme_eğilimi
WITH 
-- 1️⃣ base: Videoların izlenme kayıtlarını alıyoruz ve yayın tarihine göre haftaları hesaplıyoruz
base AS (
  SELECT
    playlistId,  -- Playlist ID
    IFNULL(user_id,'n/a') AS user_id,  -- Kullanıcı ID, boşsa 'n/a'
    IFNULL(user_pseudo_id, 'n/a') AS user_pseudo_id,  -- Kullanıcı pseudo ID, boşsa 'n/a'
    video_id,  -- Video ID
    DATE(Datetime_Ist) AS view_date,  -- İzlenme tarihi
    DATE('2025-06-20') AS published_date,  -- Yayın tarihi sabit alınmış
    -- Yayın tarihine göre videonun kaçıncı haftada izlendiğini hesapla
    FLOOR(DATE_DIFF(DATE(Datetime_Ist), DATE('2025-06-20'), DAY) / 7) AS custom_week_id,
    -- Yayınlandığı haftayı hesapla (bu örnekte sabit tarih olduğu için 0 olacak)
    FLOOR(DATE_DIFF(DATE('2025-06-20'), DATE('2025-06-20'), DAY) / 7) AS published_week_id
  FROM
    `microgain-9f959.looker_report.content_report_streaming_V2`
  WHERE 
    event_date BETWEEN '2025-06-20' AND '2025-07-13'  -- Analiz yapılacak tarih aralığı
    AND playlistId = 'Modern Kadın 1. Sezon'  -- Sadece ilgili playlist
),
-- 2️⃣ weekly_views: Haftalık izlenme sayısını hesapla
weekly_views AS (
  SELECT
    playlistId,
    custom_week_id - published_week_id AS week_since_publish,  -- Yayınlanma sonrası kaçıncı hafta
    COUNT(DISTINCT CONCAT(user_id, user_pseudo_id, video_id)) AS views_in_week  -- Haftalık izlenme sayısı (unique kullanıcı+video)
  FROM
    base
  GROUP BY
    playlistId, week_since_publish
),
-- 3️⃣ first_week_views: İlk hafta izlenme sayısını alıyoruz
first_week_views AS (
  SELECT
    playlistId,
    views_in_week AS first_week_views  -- İlk haftadaki izlenme sayısı
  FROM
    weekly_views
  WHERE
    week_since_publish = 0  -- Yayınlandığı hafta
)
-- 4️⃣ Ana çıktı: Haftalık izlenmeleri ve ilk haftaya oranını göster
SELECT
  w.playlistId,
  w.week_since_publish,  -- Yayın sonrası hafta numarası
  w.views_in_week,  -- O hafta izlenme sayısı
  f.first_week_views,  -- İlk hafta izlenme sayısı
  ROUND(100.0 * w.views_in_week / f.first_week_views, 2) AS percent_of_first_week  -- İlk haftaya göre yüzde
FROM
  weekly_views w
JOIN
  first_week_views f
ON
  w.playlistId = f.playlistId
ORDER BY
  w.playlistId, w.week_since_publish;
