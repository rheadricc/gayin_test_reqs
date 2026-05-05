-- İlgili Promotion'ı Bulma

select * from `Backoffice_metadata.bo_promotions` where promotionId = 'U8FSK7YL53LBW3O6WH8EATH9'

select * from `microgain-9f959.Backoffice_metadata.bo_promotions` where lower (name) like '%alt%'


-- İlgili promosyonların kullanım sayısını bulma
SELECT
  ap.name,
  ap.promotionId,
  COUNT(DISTINCT sp.user_id) AS user_count
FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` AS sp,
UNNEST(sp.applied_promotions) AS ap
WHERE sp.user_id IS NOT NULL
  AND ap.promotionId IN (
    'ZPWMMXU4R0MAIW0NQ2SVIK6T',
    'U8FSK7YL53LBW3O6WH8EATH9'
  )
GROUP BY ap.promotionId,ap.name
ORDER BY ap.promotionId;


-- Tekil Promosyon kullanım sayısı bulma

SELECT COUNT(DISTINCT user_id) AS user_count
FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
WHERE user_id IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM UNNEST(applied_promotions) ap
    WHERE ap.promotionId = 'ZPWMMXU4R0MAIW0NQ2SVIK6T'
  );

-- promo kullanım, aylık kırılımlı

SELECT
  DATE_TRUNC(DATE(sp.created_at, "Europe/Istanbul"), MONTH) AS year_month,
  ap.name,
  ap.promotionId,
  COUNT(DISTINCT sp.user_id) AS user_count
FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` AS sp,
UNNEST(sp.applied_promotions) AS ap
WHERE sp.user_id IS NOT NULL
  AND ap.promotionId IN (
    'YBWAFVJE3NMRAYE3QGF1QRQT',
    'BNQ922GR3DGDL4ZCWDY433PX',
    'M3XCHNWK4MIHDALRTQ48CM27',
    'GEXS74JH8C0RHR2NPHJJM3DS'
  )
GROUP BY year_month, ap.promotionId, ap.name
ORDER BY year_month, ap.promotionId;  