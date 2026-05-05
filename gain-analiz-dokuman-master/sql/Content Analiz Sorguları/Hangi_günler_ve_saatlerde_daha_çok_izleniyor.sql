
-- Hangi_günler_ve_saatlerde_daha_çok_izleniyor?
SELECT
  -- Her kullanıcı+video kombinasyonunu tekilleştirerek izlenme sayısı
  COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id)) AS watch_count,
  -- Toplam izlenme sayısına göre yüzdesi
  ROUND(
    COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id)) 
    * 100.0 / SUM(COUNT(DISTINCT CONCAT(IFNULL(user_id,'n/a'), IFNULL(user_pseudo_id, 'n/a'), video_id))) 
      OVER(), 2
  ) AS percentage_of_total,
  -- Benzersiz kullanıcı sayısı
  COUNT(DISTINCT user_id) AS unique_users,
  -- İzlemenin gerçekleştiği gün (Pazartesi, Salı, ...)
  FORMAT_DATE('%A', DATE(Datetime_Ist)) AS day_of_week
FROM `microgain-9f959.looker_report.content_report_streaming_V2`
WHERE 
  playlistId = 'Modern Kadın 1. Sezon'  -- İlgili playlist
  AND event_date BETWEEN '2025-06-20' AND '2025-07-13'  -- Analiz tarih aralığı
  -- AND title = '1. Bölüm - 35\'lik'  -- İstenirse tek bölüm filtrelenebilir
GROUP BY day_of_week  -- Gün bazında grupla
ORDER BY watch_count DESC;  -- En çok izlenen günleri başa al
