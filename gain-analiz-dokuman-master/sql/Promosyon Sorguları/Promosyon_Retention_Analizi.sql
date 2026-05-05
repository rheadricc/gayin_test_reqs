
-- PromosyonRetention Analizi
-- Amaç: Promosyonla gelen kullanıcıların ücretsiz süre sonunda ödeme yapıp yapmadığını incelemek
-- Kullanılan tablolar:
--   aws_s3_to_bq_migration.subs_payment        : abonelik ödeme bilgileri, applied_promotions ve benefits içerir
--   test_dataset.bo_promotion_passive          : promosyon detayları
WITH
-- 1. Tüm ödeme yapan kullanıcıları ve uygulanan promosyon bilgilerini alıyoruz
all_users_payment AS (
  SELECT
    status,
    subscription_plan_id,
    valid_until,
    user_id,
    email,
    registered_at,
    created_at,
    grace_until,
    free_trial_start_date,
    free_trial_end_date,
    ap.promotionid AS PromotionID,
    ap.applyDate AS PromotionApplyDate,
    ap.name AS PromotionName,
    ap.code AS PromotionCode,
    ap.type AS PromotionType,
    benefits.freePremiumByDay AS freePremiumByDay,
    benefits.freePremiumByMonth AS freePremiumByMonth,
    benefits.isFreePremium AS isFreePremium,
    amount
  FROM `aws_s3_to_bq_migration.subs_payment`
  LEFT JOIN UNNEST(applied_promotions) ap
  LEFT JOIN UNNEST(ap.benefits) benefits
  WHERE DATE(created_at) >= '2025-02-01' 
    AND DATE(created_at) <= CURRENT_DATE("Europe/Istanbul") - 1
    AND status = 'ACTIVE'
),
-- 2. Promosyonların sağladığı ücretsiz gün sayısını alıyoruz
promotions_info AS (
  SELECT
    promotionId,
    IFNULL(
      IFNULL(
        CAST(JSON_VALUE(REPLACE(benefits, "'", '"'), '$[0].freePremiumByDay') AS INT64),
        CAST(JSON_VALUE(REPLACE(benefits, "'", '"'), '$[0].freePremiumByMonth') AS INT64) * 30
      ),
      0
    ) AS freePremiumByDay
  FROM `test_dataset.bo_promotion_passive` 
),
-- 3. Promosyon uygulanan kullanıcıları seçiyoruz ve freePremiumByDay ile eşleştiriyoruz
promotion_users AS (
  SELECT
    user_id,
    email,
    created_at,
    PromotionApplyDate,
    PromotionName,
    pi.freePremiumByDay
  FROM all_users_payment aup
  LEFT JOIN promotions_info pi 
    ON aup.PromotionID = pi.promotionid
  WHERE aup.PromotionID IS NOT NULL
    AND amount < 14900  -- promosyonlu ödeme miktarı sınırı
),
-- 4. Ödeme yapan kullanıcıları belirliyoruz (tam abonelik ücreti)
paying_users AS (
  SELECT
    user_id,
    email,
    MIN(created_at) AS created_at
  FROM all_users_payment
  WHERE amount = 14900
  GROUP BY 1,2
),
-- 5. Promosyon kullanıcıları ile ödeme yapan kullanıcıları eşleştiriyoruz
ranked_payments AS (
  SELECT
    pro.user_id AS promotion_users,
    pay.user_id AS pay_users,
    pro.PromotionApplyDate,
    pro.PromotionName,
    pay.created_at AS payment_created_at,
    freePremiumByDay,
    TIMESTAMP_DIFF(pay.created_at, pro.PromotionApplyDate, DAY) AS purchase_after_promotions,
    ROW_NUMBER() OVER (PARTITION BY pro.user_id, pro.PromotionApplyDate ORDER BY pay.created_at) AS rn
  FROM promotion_users pro
  LEFT JOIN paying_users pay
    ON pro.user_id = pay.user_id
   AND pay.created_at > pro.PromotionApplyDate
),
-- 6. Promosyon sonrası satın alma durumunu sınıflandırıyoruz
ReportData AS (
  SELECT
    promotion_users,
    pay_users,
    PromotionApplyDate,
    PromotionName,
    payment_created_at AS first_payment_after_promotion,
    purchase_after_promotions,
    freePremiumByDay,
    CASE 
      WHEN purchase_after_promotions <= freePremiumByDay THEN 'PurchaseAfterPromotion'
      WHEN purchase_after_promotions IS NULL OR purchase_after_promotions > freePremiumByDay THEN 'NoPurchase'
      ELSE 'Unknown'
    END AS PurchaseStatus,
    IF(purchase_after_promotions IS NULL,'NoPurchase','PurchaseAfterPromotion') AS PurchaseStatus2
  FROM ranked_payments
  WHERE rn = 1
)
-- 7. Final çıktı: her promosyon için kullanıcı sayısı ve satın alma durumu
SELECT
  COUNT(DISTINCT promotion_users) AS user_count,
  PromotionName,
  PurchaseStatus2
FROM ReportData
GROUP BY 2,3;
