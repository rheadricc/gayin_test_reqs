-- ARPPU_(Old System) Analizi
-- Amaç: Eski sistem verilerine göre ödeme yapan kullanıcı başına ortalama gelir (ARPPU) hesaplamak
-- Kullanılan tablolar:
--   datamarts.transaction_v2 : ödeme ve abonelik bilgileri
WITH
-- 1. Her ay ve yıl için ödeme yapan kullanıcı sayısını buluyoruz
PayingUser AS (
  SELECT 
    DATE_TRUNC(DATE(CreatedAt,"Europe/Istanbul"), YEAR) AS Year,
    DATE_TRUNC(DATE(CreatedAt,"Europe/Istanbul"), MONTH) AS Month,
    COUNT(DISTINCT userId) AS Cnt
  FROM `datamarts.transaction_v2`
  WHERE DATE_TRUNC(DATE(CreatedAt,"Europe/Istanbul"), MONTH) >= DATE_TRUNC('2024-01-01', MONTH)
    AND price > 1
    AND COALESCE(subscriptionType, 'Monthly') NOT LIKE '%yıllık%'
  GROUP BY 1,2
),
-- 2. Her kullanıcı için ödemeyi ödeme tipine göre netleştiriyoruz
PayingBase AS (
  SELECT DISTINCT
    DATE_TRUNC(DATE(CreatedAt), YEAR) AS Year,
    DATE_TRUNC(DATE(CreatedAt), MONTH) AS Month,
    userid,
    CASE 
      WHEN paymentType IN ('Apple') THEN (price*0.70)/1.2
      WHEN paymentType IN ('Google') THEN (price*0.85)/1.2
      WHEN paymentType IN ('Payguru') THEN (price*0.85)/1.2
      WHEN paymentType IN ('Iyzico - Web','Iyzico - Mobil') THEN (price*0.963)/1.2
    END AS price -- net gelir
  FROM `datamarts.transaction_v2`
  WHERE DATE_TRUNC(DATE(CreatedAt), MONTH) >= DATE_TRUNC('2024-01-01', MONTH)
    AND COALESCE(subscriptionType, 'Monthly') NOT LIKE '%yıllık%'
),
-- 3. Aylık toplam net geliri hesaplıyoruz
Paying AS (
  SELECT
    Year,
    Month,
    SUM(price) AS Total
  FROM PayingBase
  GROUP BY 1,2
)
-- 4. Final: ARPPU hesaplama
SELECT
  p.Year,
  p.Month,
  Total AS Gelir,          -- aylık toplam net gelir
  Cnt AS UserCount,        -- ödeme yapan kullanıcı sayısı
  ROUND((Total / Cnt), 2) AS ARPPU  -- kullanıcı başına ortalama gelir
FROM PayingUser pu
LEFT JOIN Paying p 
  ON pu.Year = p.Year 
  AND pu.Month = p.Month;
