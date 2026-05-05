-- ARPU(Old System) Analizi
-- Amaç: Eski sistem verilerine göre kullanıcı başına ortalama gelir (ARPU) hesaplamak
-- Kullanılan tablolar:
--   datamarts.transaction_v2                : ödeme ve abonelik bilgileri
--   looker_report.Promotion_Conversion_hourly : promosyon dönüşüm kullanıcıları
--   microgain-9f959.looker_report.promo_legend : promosyon detayları
WITH
-- 1. Ödeme yapan kullanıcıların yıllık ve aylık bazda net fiyat ve nakit akışını hesaplıyoruz
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
    END AS netprice,       -- komisyon ve vergi düşülmüş net gelir
    CASE 
      WHEN paymentType IN ('Apple') THEN price*0.70
      WHEN paymentType IN ('Google') THEN price*0.85
      WHEN paymentType IN ('Payguru') THEN price*0.85
      WHEN paymentType IN ('Iyzico - Web','Iyzico - Mobil') THEN price*0.963
    END AS nakitakisi      -- nakit akışı (komisyon düşülmüş)
  FROM `datamarts.transaction_v2`
  WHERE DATE_TRUNC(DATE(CreatedAt), MONTH) >= DATE_TRUNC('2024-01-01', MONTH)
    AND COALESCE(subscriptionType, 'Monthly') NOT LIKE '%yıllık%'
),
-- 2. Yıllık ve aylık toplam net gelir ve nakit akışını hesaplıyoruz
Paying AS (
  SELECT
    Year,
    Month,
    SUM(netprice) AS NetTotal,
    SUM(nakitakisi) AS NakitAkisi
  FROM PayingBase
  GROUP BY 1,2
),
-- 3. Premium kullanıcı sayısını hesaplıyoruz (hem transaction_v2 hem de promosyon dönüşüm kullanıcıları)
PremiumUsers AS (
  SELECT
    DATE_TRUNC(CreatedAt, YEAR) AS Year,
    DATE_TRUNC(CreatedAt, MONTH) AS Month,
    COUNT(DISTINCT userid) AS Usercnt
  FROM (
    -- 3a. transaction_v2’den ödeme yapan kullanıcılar
    SELECT DISTINCT
      DATE(CreatedAt) AS CreatedAt,
      userid
    FROM `datamarts.transaction_v2`
    WHERE DATE_TRUNC(DATE(CreatedAt), MONTH) >= DATE_TRUNC('2024-01-01', MONTH)
    UNION ALL
    -- 3b. Promosyon ile premium olan kullanıcılar
    SELECT DISTINCT
      DATE(CreatedAt) AS CreatedAt,
      user_id AS userid
    FROM `looker_report.Promotion_Conversion_hourly` pr
    LEFT JOIN `microgain-9f959.looker_report.promo_legend` pl 
      ON pr.promo_name = pl.promo_name
    WHERE DATE_TRUNC(DATE(CreatedAt), MONTH) >= DATE_TRUNC('2024-01-01', MONTH)
      AND premium_status = 'New'
      AND kurgu = '7 Gün Ücretsiz'
  )
  GROUP BY Year, Month
)
-- 4. Final ARPU raporu: kullanıcı başına net gelir ve nakit akışı
SELECT
  p.Year,
  p.Month,
  NetTotal,
  NakitAkisi,
  Usercnt,
  ROUND((NetTotal / Usercnt), 2) AS ARPUNet,   -- kullanıcı başına net gelir
  ROUND((NakitAkisi / Usercnt), 2) AS ARPUAkis -- kullanıcı başına nakit akışı
FROM Paying p
LEFT JOIN PremiumUsers pu
  ON p.Year = pu.Year 
  AND p.Month = pu.Month;
