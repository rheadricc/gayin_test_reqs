CREATE OR REPLACE TABLE `microgain-9f959.test_dataset.user_dim_scd2_stage_copy`
PARTITION BY DATE(effective_start)
CLUSTER BY userId AS
SELECT
  r.userId,
  r.customerId,
  r.email,
  r.fullName,
  r.status,
  CAST(r.verificationStatus AS BOOL) AS verificationStatus,
  r.agreements,
  r.profiles,
  r.createdAt,
  r.updatedAt,
  r.preferredCulture,
  r.communicationConsent,
  r.verificationAt,
  r.freeTrialStartDate,
  r.freeTrialEndDate,
  r.subscription,
  r.promotionCodes,
  r.birthDate,
  r.checkPromotionErrorInfo,
  r.gender,
  r.city,
  r.countryCode,
  r.missingPersonalInfoRemindedAt,
  r.missingPersonalInfoReminderCount,
  CAST(r.etl_date AS TIMESTAMP) AS etl_date,
  CURRENT_TIMESTAMP() AS effective_start,
  TIMESTAMP('9999-12-31 23:59:59') AS effective_end,
  TRUE AS is_current
FROM `microgain-9f959.test_dataset.dim_user_raw_copy` r
LEFT JOIN (
  SELECT * FROM `microgain-9f959.test_dataset.dim_user_partial_scd_copy`
  WHERE is_current = TRUE
) s
ON r.userId = s.userId
  WHERE DATE(r.etl_date) = @etl_date
  AND (
    s.userId IS NULL OR
    r.email != s.email OR
    r.fullName != s.fullName OR
    r.status != s.status OR
    r.verificationStatus != s.verificationStatus OR
    r.preferredCulture != s.preferredCulture OR
    TO_JSON_STRING(r.communicationConsent) != TO_JSON_STRING(s.communicationConsent)
  );

UPDATE `microgain-9f959.test_dataset.dim_user_partial_scd_copy`
SET
  is_current = FALSE,
  effective_end = CURRENT_TIMESTAMP()
WHERE is_current = TRUE
  AND userId IN (
    SELECT userId FROM `microgain-9f959.test_dataset.user_dim_scd2_stage_copy`
  );

INSERT INTO `microgain-9f959.test_dataset.dim_user_partial_scd_copy`
SELECT * FROM `microgain-9f959.test_dataset.user_dim_scd2_stage_copy`;
