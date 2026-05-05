--Kullanıcı_İzlenme_Analizi:_Platform,_Şehir,_Bölge_ve_Ülke_Bazında_Trendler
-- ===============================
-- 1️⃣ Hangi device_platform daha çok izleniyor?
-- ===============================
SELECT
  -- Her kullanıcı+video kombinasyonunu tekilleştirerek izlenme sayısı
  COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id)) AS watch_count,
  -- Toplam izlenme sayısına göre yüzdesi
  ROUND(
    COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id)) 
    * 100.0 / SUM(COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id))) OVER(), 2
  ) AS percentage_of_total,
  -- Benzersiz kullanıcı sayısı
  COUNT(DISTINCT user_id) AS unique_users,
  -- Toplam kullanıcıya göre yüzdesi
  ROUND(COUNT(DISTINCT user_id) * 100.0 / SUM(COUNT(DISTINCT user_id)) OVER(), 2) AS perc_of_total_usrs,
  -- İzlemenin gerçekleştiği cihaz platformu (Android, iOS vb.)
  device_platform
FROM `microgain-9f959.looker_report.content_report_streaming_V2`
WHERE 
  playlistId = 'Modern Kadın 1. Sezon'  -- Analiz yapılacak playlist
  AND event_date BETWEEN '2025-06-20' AND '2025-07-16'  -- Tarih aralığı
GROUP BY device_platform
ORDER BY watch_count DESC;

-- ===============================
-- 2️⃣ Hangi şehir (city) daha çok izleniyor?
-- ===============================
SELECT
  COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id)) AS watch_count,
  ROUND(COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id)) * 100.0 / SUM(COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id))) OVER(), 2) AS percentage_of_total,
  COUNT(DISTINCT user_id) AS unique_users,
  ROUND(COUNT(DISTINCT user_id) * 100.0 / SUM(COUNT(DISTINCT user_id)) OVER(), 2) AS perc_of_total_usrs,
  g_city  -- Kullanıcının bulunduğu şehir
FROM `microgain-9f959.looker_report.content_report_streaming_V2`
WHERE 
  playlistId = 'Modern Kadın 1. Sezon'
  AND event_date BETWEEN '2025-06-20' AND '2025-07-16'
GROUP BY g_city
ORDER BY watch_count DESC;

-- ===============================
-- 3️⃣ Hangi bölge (continent) daha çok izleniyor?
-- ===============================
SELECT
  COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id)) AS watch_count,
  ROUND(COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id)) * 100.0 / SUM(COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id))) OVER(), 2) AS percentage_of_total,
  COUNT(DISTINCT user_id) AS unique_users,
  ROUND(COUNT(DISTINCT user_id) * 100.0 / SUM(COUNT(DISTINCT user_id)) OVER(), 2) AS perc_of_total_usrs,
  g_continent  -- Kullanıcının bulunduğu kıta/bölge
FROM `microgain-9f959.looker_report.content_report_streaming_V2`
WHERE 
  playlistId = 'Modern Kadın 1. Sezon'
  AND event_date BETWEEN '2025-06-20' AND '2025-07-16'
GROUP BY g_continent
ORDER BY watch_count DESC;

-- ===============================
-- 4️⃣ Hangi ülke daha çok izleniyor?
-- ===============================
SELECT
  COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id)) AS watch_count,
  ROUND(COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id)) * 100.0 / SUM(COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id))) OVER(), 2) AS percentage_of_total,
  COUNT(DISTINCT user_id) AS unique_users,
  ROUND(COUNT(DISTINCT user_id) * 100.0 / SUM(COUNT(DISTINCT user_id)) OVER(), 2) AS perc_of_total_usrs,
  g_country  -- Kullanıcının bulunduğu ülke
FROM `microgain-9f959.looker_report.content_report_streaming_V2`
WHERE 
  playlistId = 'Modern Kadın 1. Sezon'
  AND event_date BETWEEN '2025-06-20' AND '2025-07-16'
GROUP BY g_country
ORDER BY watch_count DESC;
