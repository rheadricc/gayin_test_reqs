-- Kural 1: IYZICO için cardNumber boş olamaz
SELECT
  userId,
  'cardNumber is NULL or empty for IYZICO' AS rule_violation
FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`
WHERE is_current = TRUE
  AND DATE(etl_date) = @etl_date
  AND createdAt >= '2025-01-25'
  AND subscription.paymentOption = 'IYZICO'
  AND (subscription.cardNumber IS NULL OR subscription.cardNumber = '')

UNION ALL

-- Kural 2: PLAY_STORE için googleOriginalTransactionId boş olamaz
SELECT
  userId,
  'googleOriginalTransactionId is NULL or empty for PLAY_STORE' AS rule_violation
FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`
WHERE is_current = TRUE
  AND DATE(etl_date) = @etl_date
  AND createdAt >= '2025-01-25'
  AND subscription.paymentOption = 'PLAY_STORE'
  AND (subscription.googleOriginalTransactionId IS NULL OR subscription.googleOriginalTransactionId = '')

UNION ALL

-- Kural 3: APP_STORE için appleOriginalTransactionId boş olamaz
SELECT
  userId,
  'appleOriginalTransactionId is NULL or empty for APP_STORE' AS rule_violation
FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`
WHERE is_current = TRUE
  AND DATE(etl_date) = @etl_date
  AND createdAt >= '2025-01-25'
  AND subscription.paymentOption = 'APP_STORE'
  AND (subscription.appleOriginalTransactionId IS NULL OR subscription.appleOriginalTransactionId = '')

UNION ALL

-- Kural 4: verificationStatus = TRUE ise isEmailPermitted boş olamaz
SELECT
  userId,
  'isEmailPermitted is NULL despite verificationStatus = TRUE' AS rule_violation
FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`
WHERE is_current = TRUE
  AND DATE(etl_date) = @etl_date
  AND createdAt >= '2025-01-25'
  AND verificationStatus = TRUE
  AND communicationConsent.isEmailPermitted IS NULL

UNION ALL

-- Kural 5: promotionCode varsa appliedPromotions.code boş olamaz
SELECT
  userId,
  'appliedPromotions.code is NULL despite valid promotionCode' AS rule_violation
FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`
WHERE is_current = TRUE
  AND DATE(etl_date) = @etl_date
  AND createdAt >= '2025-01-25'
  AND EXISTS (
    SELECT 1
    FROM UNNEST(promotionCodes) AS promo
    JOIN UNNEST(subscription.appliedPromotions) AS ap ON promo.promotionCode = ap.code
    WHERE promo.promotionCode IS NOT NULL AND promo.promotionCode != ''
      AND (ap.code IS NULL OR ap.code = '')
  )

UNION ALL

-- Kural 6: promotionId varsa name/code/type alanları boş olamaz
SELECT
  userId,
  'promotionId exists but name/code/type is missing' AS rule_violation
FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`
WHERE is_current = TRUE
  AND DATE(etl_date) = @etl_date
  AND createdAt >= '2025-01-25'
  AND EXISTS (
    SELECT 1 FROM UNNEST(subscription.appliedPromotions) AS ap
    WHERE ap.promotionId IS NOT NULL
      AND (
        ap.name IS NULL OR ap.name = '' OR
        ap.code IS NULL OR ap.code = '' OR
        ap.type IS NULL OR ap.type = ''
      )
  )

UNION ALL

-- Kural 7: isFreePremium = TRUE ise, süre bilgileri ve kullanım süresi dolu olmalı
SELECT
  userId,
  'isFreePremium is TRUE but required fields are missing' AS rule_violation
FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`,
UNNEST(subscription.appliedPromotions) AS ap,
UNNEST(ap.benefits) AS benefit
WHERE
  DATE(etl_date) = @etl_date
  AND is_current = TRUE
  AND (
    (benefit.isFreePremium = TRUE AND (
      (benefit.freePremiumByDay IS NULL AND benefit.freePremiumByMonth IS NULL)
      OR benefit.usedPeriod IS NULL
    ))
  )

UNION ALL

-- Kural 8: amount = 0 ve graceUntil-createdAt > 10 gün ise promotionCode boş olamaz
SELECT
  userId,
  'missing promotionCode despite amount = 0 and graceUntil > 10 days after createdAt' AS rule_violation
FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`
WHERE
  is_current = TRUE
  AND DATE(etl_date) = @etl_date
  AND createdAt >= '2025-01-25'
  AND subscription.amount = 0
  AND DATE_DIFF(DATE(subscription.graceUntil), DATE(createdAt), DAY) > 10
  AND (
    promotionCodes IS NULL
    OR ARRAY_LENGTH(
      ARRAY(
        SELECT 1
        FROM UNNEST(promotionCodes) AS promo
        WHERE promo.promotionCode IS NOT NULL AND promo.promotionCode != ''
      )
    ) = 0
  );
