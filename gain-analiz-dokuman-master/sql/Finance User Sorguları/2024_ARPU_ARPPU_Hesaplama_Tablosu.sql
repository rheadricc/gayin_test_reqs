
-- 2024_ARPU/ARPPU_Hesaplama_Tablosu
-- Açıklama:
-- Bu sorgu, 2024 yılı için ARPU (Average Revenue Per User) ve ARPPU 
-- (Average Revenue Per Paying User) hesaplamalarını yapar.
-- Gelirler hem net gelir (komisyon vb. düşülmüş) hem de nakit akışı üzerinden hesaplanır.
-- Çıktı, yıllık, aylık ve günlük bazda kullanıcı başına gelirleri gösterir.
-- ======================================================
CREATE OR REPLACE TABLE `microgain-9f959.test_dataset.Arpu_Arppu_2024` AS
-- =======================================
-- 1. Ödeme yapan kullanıcılar ve net gelir
-- =======================================
WITH ARPU_2024_PayingBase AS (
  SELECT
    DISTINCT 
    DATE_TRUNC(DATE(createdat,"Europe/Istanbul"),YEAR) AS Year,
    DATE_TRUNC(DATE(createdat,"Europe/Istanbul"),MONTH) AS Month,
    DATE(createdat,"Europe/Istanbul") AS Date,
    userid, 
    -- Ödeme tipine göre net gelir ve nakit akışı hesaplaması
    CASE 
      WHEN paymentType IN ('Apple') THEN (price*0.70)/1.2
      WHEN paymentType IN ('Google') THEN (price*0.85)/1.2
      WHEN paymentType IN ('Payguru') THEN (price*0.85)/1.2
      WHEN paymentType IN ('Iyzico - Web','Iyzico - Mobil') THEN (price*0.963)/1.2
    END AS netprice,
    CASE 
      WHEN paymentType IN ('Apple') THEN price*0.70
      WHEN paymentType IN ('Google') THEN price*0.85
      WHEN paymentType IN ('Payguru') THEN price*0.85
      WHEN paymentType IN ('Iyzico - Web','Iyzico - Mobil') THEN price*0.963
    END AS nakitakisi
  FROM `datamarts.transaction_v2`
  WHERE DATE_TRUNC(DATE(createdat,"Europe/Istanbul"),MONTH) >= DATE_TRUNC('2024-01-01',MONTH)
    AND COALESCE(subscriptionType,'Monthly') NOT LIKE '%yıllık%'
),
-- =======================================
-- 2. Günlük toplam net gelir ve nakit akışı
-- =======================================
ARPU_2024_Paying AS (
  SELECT
    Year,
    Month,
    Date,
    SUM(netprice) AS NetTotal_2024,
    SUM(nakitakisi) AS NakitAkisi_2024
  FROM ARPU_2024_PayingBase
  GROUP BY 1,2,3
),
-- =======================================
-- 3. Premium kullanıcı sayısı
-- =======================================
ARPU_2024_PremiumUsers AS (
  SELECT
    DATE_TRUNC(CreatedAt,YEAR) AS Year,
    DATE_TRUNC(CreatedAt,MONTH) AS Month,
    DATE(CreatedAt) AS date,
    COUNT(DISTINCT userid) AS Usercnt
  FROM (
    -- Premium kullanıcıları transaction ve promosyonlardan al
    SELECT DISTINCT DATE(createdat,"Europe/Istanbul") AS CreatedAt, userid
    FROM `datamarts.transaction_v2`
    WHERE DATE_TRUNC(DATE(CreatedAt),MONTH) >= DATE_TRUNC('2024-01-01',MONTH)
    
    UNION ALL
    
    SELECT DISTINCT CreatedAt, user_id
    FROM `looker_report.Promotion_Conversion_hourly` pr
    LEFT JOIN `microgain-9f959.looker_report.promo_legend` pl ON pr.promo_name = pl.promo_name
    WHERE DATE_TRUNC(DATE(CreatedAt),MONTH) >= DATE_TRUNC('2024-01-01',MONTH)
      AND premium_status = 'New'
      AND kurgu = '7 Gün Ücretsiz'
  )
  GROUP BY 1,2,3
),
-- =======================================
-- 4. ARPU hesaplama (kullanıcı başına gelir)
-- =======================================
ARPU_2024_LastTab AS (
  SELECT
    p.Year,
    p.Month,
    p.date,
    NetTotal_2024,
    NakitAkisi_2024,
    Usercnt,
    ROUND((NetTotal_2024 / Usercnt),2) AS ARPUNet_2024,
    ROUND((NakitAkisi_2024 / Usercnt),2) AS ARPUAkis_2024
  FROM ARPU_2024_Paying p
  LEFT JOIN ARPU_2024_PremiumUsers pu ON p.Year = pu.Year AND p.date = pu.date
),
-- =======================================
-- 5. Ödeme yapan kullanıcı sayısı ve ARPPU
-- =======================================
ARPPU_2024_PayingUser AS (
  SELECT 
    DATE_TRUNC(DATE(CreatedAt,"Europe/Istanbul"),YEAR) AS Year,
    DATE_TRUNC(DATE(CreatedAt,"Europe/Istanbul"),MONTH) AS Month,
    DATE(CreatedAt,"Europe/Istanbul") AS date,
    COUNT(DISTINCT userId) AS Cnt
  FROM `datamarts.transaction_v2`
  WHERE DATE_TRUNC(DATE(CreatedAt,"Europe/Istanbul"),MONTH) >= DATE_TRUNC('2024-01-01',MONTH)
    AND price > 1
    AND COALESCE(subscriptionType,'Monthly') NOT LIKE '%yıllık%'
  GROUP BY 1,2,3
),
-- =======================================
-- 6. Ödeme yapan kullanıcılar için net gelir
-- =======================================
ARPPU_2024_PayingBase AS (
  SELECT DISTINCT
    DATE_TRUNC(DATE(createdat,"Europe/Istanbul"),YEAR) AS Year,
    DATE_TRUNC(DATE(createdat,"Europe/Istanbul"),MONTH) AS Month,
    DATE(createdat,"Europe/Istanbul") AS date,
    userid,
    CASE 
      WHEN paymentType IN ('Apple') THEN (price*0.70)/1.2
      WHEN paymentType IN ('Google') THEN (price*0.85)/1.2
      WHEN paymentType IN ('Payguru') THEN (price*0.85)/1.2
      WHEN paymentType IN ('Iyzico - Web','Iyzico - Mobil') THEN (price*0.963)/1.2
    END AS netprice,
    CASE 
      WHEN paymentType IN ('Apple') THEN price*0.70
      WHEN paymentType IN ('Google') THEN price*0.85
      WHEN paymentType IN ('Payguru') THEN price*0.85
      WHEN paymentType IN ('Iyzico - Web','Iyzico - Mobil') THEN price*0.963
    END AS nakitakisi
  FROM `datamarts.transaction_v2`
  WHERE DATE_TRUNC(DATE(CreatedAt),MONTH) >= DATE_TRUNC('2024-01-01',MONTH)
    AND COALESCE(subscriptionType,'Monthly') NOT LIKE '%yıllık%'
),
-- =======================================
-- 7. ARPPU hesaplama
-- =======================================
ARPPU_2024_Paying AS (
  SELECT
    Year,
    Month,
    date,
    SUM(netprice) AS NetTotal_2024,
    SUM(nakitakisi) AS NakitAkisiTotal_2024
  FROM ARPPU_2024_PayingBase
  GROUP BY 1,2,3
),
ARPPU_2024_LastTab AS (
  SELECT
    p.Year,
    p.Month,
    p.date,
    NetTotal_2024 AS NetGelir_2024,
    NakitAkisiTotal_2024 AS NetAkis_2024,
    Cnt AS UserCount,
    ROUND((NetTotal_2024 / Cnt),2) AS ARPPUNet_2024,
    ROUND((NakitAkisiTotal_2024 / Cnt),2) AS ARPPUAkis_2024
  FROM ARPPU_2024_PayingUser pu
  LEFT JOIN ARPPU_2024_Paying p ON pu.Year = p.Year AND pu.date = p.date
),
-- =======================================
-- 8. Son tablo: ARPU & ARPPU
-- =======================================
LastTab_2024 AS (    
  SELECT DISTINCT
    arp.YEAR,
    arp.month,
    arp.Date,
    FORMAT_DATE('%m-%d', arp.Date) AS MonthDay,
    arp.ARPUNet_2024,
    arp.ARPUAkis_2024,
    arppu.ARPPUNet_2024,
    arppu.ARPPUAkis_2024
  FROM ARPU_2024_LastTab arp 
  LEFT JOIN ARPPU_2024_LastTab arppu ON arp.date = arppu.date
  ORDER BY arp.date
)
-- =======================================
-- 9. Sonuç
-- =======================================
SELECT * FROM LastTab_2024
