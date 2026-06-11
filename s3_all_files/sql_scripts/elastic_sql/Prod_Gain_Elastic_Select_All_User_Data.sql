CREATE OR REPLACE TABLE `microgain-9f959.gain_model_prod.prod_user_dim_scd2_stage`
PARTITION BY DATE(effective_start)
CLUSTER BY userId AS
WITH prepared_raw AS (
  SELECT r.* EXCEPT(etl_date),
         CAST(@etl_date AS TIMESTAMP) AS etl_date
  FROM `microgain-9f959.gain_model_prod.prod_dim_user_raw` r
  WHERE DATE(r.etl_date) = @etl_date
),
prepared_current AS (
  SELECT * EXCEPT(etl_date)
  FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`
  WHERE is_current = TRUE
    AND DATE(effective_start) = CAST(@etl_date AS DATE)
)
SELECT
  r.*,
  CURRENT_TIMESTAMP() AS effective_start,
  TIMESTAMP('9999-12-31 23:59:59') AS effective_end,
  TRUE AS is_current
FROM prepared_raw r
LEFT JOIN prepared_current s
  ON r.userId = s.userId
WHERE
  s.userId IS NULL
  OR TO_JSON_STRING(STRUCT(
      r.userId, r.customerId, r.email, r.fullName, r.status, r.verificationStatus,
      r.agreements, r.profiles, r.createdAt, r.updatedAt, r.preferredCulture,
      r.communicationConsent, r.verificationAt, r.freeTrialStartDate, r.freeTrialEndDate,
      r.subscription, r.promotionCodes, r.birthDate, r.checkPromotionErrorInfo,
      r.gender, r.city, r.countryCode, r.missingPersonalInfoRemindedAt, r.missingPersonalInfoReminderCount,
      r.address, r.district,
      r.appliedApplicationForms,
      r.securePayment3DCallBackInfo                 -- ✅ NEW (JSON olarak)
  )) != TO_JSON_STRING(STRUCT(
      s.userId, s.customerId, s.email, s.fullName, s.status, s.verificationStatus,
      s.agreements, s.profiles, s.createdAt, s.updatedAt, s.preferredCulture,
      s.communicationConsent, s.verificationAt, s.freeTrialStartDate, s.freeTrialEndDate,
      s.subscription, s.promotionCodes, s.birthDate, s.checkPromotionErrorInfo,
      s.gender, s.city, s.countryCode, s.missingPersonalInfoRemindedAt, s.missingPersonalInfoReminderCount,
      s.address, s.district,
      s.appliedApplicationForms,
      s.securePayment3DCallBackInfo                 -- ✅ NEW
  ));
