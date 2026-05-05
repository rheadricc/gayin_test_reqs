-- Promosyon_Kullanımı_Analizi
-- Amaç: Belirli bir promosyonu kullanan aktif kullanıcıların listesini almak
-- Kullanılan tablo:
--   aws_s3_to_bq_migration.subs_payment : abonelik ve promosyon bilgileri
WITH users AS (
  -- 1. Kullanıcıların promosyon bilgilerini çekiyoruz
  SELECT DISTINCT
    status,
    subscription_plan_id,
    valid_until,
    user_id,
    email,
    created_at,
    ap.promotionid AS PromotionID,
    ap.applyDate AS PromotionApplyDate,
    ap.name AS PromotionName,
    ap.code AS PromotionCode,
    ap.type AS PromotionType,
    benefits.freePremiumByDay AS freePremiumByDay,
    benefits.freePremiumByMonth AS freePremiumByMonth,
    benefits.isFreePremium AS isFreePremium
  FROM `aws_s3_to_bq_migration.subs_payment`
  LEFT JOIN UNNEST(applied_promotions) ap
  LEFT JOIN UNNEST(ap.benefits) benefits
)
-- 2. İlgili promosyonu kullanan ve aktif olan kullanıcıları filtreliyoruz
SELECT DISTINCT
  user_id,
  status,
  PromotionID,
  PromotionApplyDate,
  PromotionName,
  PromotionCode
FROM users
WHERE LOWER(PromotionName) LIKE '%koc%'  -- promosyon adı filtreleme
  AND status = 'ACTIVE'                  -- sadece aktif kullanıcılar
  AND DATE(PromotionApplyDate) >= '2025-03-01'
  AND DATE(PromotionApplyDate) <= '2025-04-30'
ORDER BY PromotionApplyDate;
