BEGIN

-- 1. Stage tabloyu oluştur
CREATE OR REPLACE TABLE `microgain-9f959.test_dataset.user_dim_scd2_stage_copy_v3`
PARTITION BY DATE(effective_start)
CLUSTER BY userId AS
WITH prepared_raw AS (
  SELECT
    r.* EXCEPT(etl_date),
    CAST(@etl_date AS TIMESTAMP) AS etl_date  -- ✅ burası düzeltildi
  FROM `microgain-9f959.test_dataset.dim_user_raw_copy_v3` r
  WHERE DATE(r.etl_date) = @etl_date
),
prepared_current AS (
  SELECT *
  FROM `microgain-9f959.test_dataset.dim_user_partial_scd_copy_v3`
  WHERE is_current = TRUE
)
SELECT
  r.*,
  CURRENT_TIMESTAMP() AS effective_start,
  TIMESTAMP('9999-12-31 23:59:59') AS effective_end,
  TRUE AS is_current
FROM prepared_raw r
LEFT JOIN prepared_current s
ON r.userId = s.userId
WHERE s.userId IS NULL OR (
  -- Primitive field karşılaştırmaları
  r.customerId != s.customerId OR
  r.email != s.email OR
  r.fullName != s.fullName OR
  r.status != s.status OR
  r.verificationStatus != s.verificationStatus OR
  r.createdAt != s.createdAt OR
  r.updatedAt != s.updatedAt OR
  r.preferredCulture != s.preferredCulture OR
  r.verificationAt != s.verificationAt OR
  r.freeTrialStartDate != s.freeTrialStartDate OR
  r.freeTrialEndDate != s.freeTrialEndDate OR
  r.birthDate != s.birthDate OR
  r.gender != s.gender OR
  r.city != s.city OR
  r.countryCode != s.countryCode OR
  r.missingPersonalInfoRemindedAt != s.missingPersonalInfoRemindedAt OR
  r.missingPersonalInfoReminderCount != s.missingPersonalInfoReminderCount OR

  -- Nested/repeated field karşılaştırmaları (JSON stringify ile)
  TO_JSON_STRING(r.agreements) != TO_JSON_STRING(s.agreements) OR
  TO_JSON_STRING(r.profiles) != TO_JSON_STRING(s.profiles) OR
  TO_JSON_STRING(r.communicationConsent) != TO_JSON_STRING(s.communicationConsent) OR
  TO_JSON_STRING(r.subscription) != TO_JSON_STRING(s.subscription) OR
  TO_JSON_STRING(r.promotionCodes) != TO_JSON_STRING(s.promotionCodes) OR
  TO_JSON_STRING(r.checkPromotionErrorInfo) != TO_JSON_STRING(s.checkPromotionErrorInfo)
)

-- 2. Eski kayıtları geçersiz yap
UPDATE `microgain-9f959.test_dataset.dim_user_partial_scd_copy_v3`
SET
  is_current = FALSE,
  effective_end = CURRENT_TIMESTAMP()
WHERE is_current = TRUE
  AND userId IN (
    SELECT DISTINCT userId
    FROM `microgain-9f959.test_dataset.user_dim_scd2_stage_copy_v3`
  );

-- 3. Yeni versiyonları ekle
INSERT INTO `microgain-9f959.test_dataset.dim_user_partial_scd_copy_v3`
SELECT *
FROM `microgain-9f959.test_dataset.user_dim_scd2_stage_copy_v3`;

END;
