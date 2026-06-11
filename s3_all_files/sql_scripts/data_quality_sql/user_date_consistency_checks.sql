SELECT
  userId,
  freeTrialStartDate,
  freeTrialEndDate,
  createdAt,
  updatedAt,
  CASE
    -- freeTrialEndDate eksik
    WHEN freeTrialStartDate IS NOT NULL AND (freeTrialEndDate IS NULL OR LOWER(TRIM(freeTrialEndDate)) = 'null') THEN
      'freeTrialStartDate exists but freeTrialEndDate is missing'

    -- tarih formatı geçersiz
    WHEN freeTrialStartDate IS NOT NULL AND freeTrialEndDate IS NOT NULL AND (
           SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', freeTrialStartDate) IS NULL
        OR SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', freeTrialEndDate) IS NULL
    ) THEN
      'invalid date format in freeTrialStartDate or freeTrialEndDate'

    -- tarih sıralaması yanlış
    WHEN freeTrialStartDate IS NOT NULL AND freeTrialEndDate IS NOT NULL AND
         DATE(SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', freeTrialEndDate)) <
         DATE(SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', freeTrialStartDate)) THEN
      'freeTrialEndDate is before freeTrialStartDate'

    -- tarih aralığı > 7 gün
    WHEN freeTrialStartDate IS NOT NULL AND freeTrialEndDate IS NOT NULL AND
         DATE_DIFF(
           DATE(SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', freeTrialEndDate)),
           DATE(SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', freeTrialStartDate)),
           DAY
         ) > 7 THEN
      'freeTrial date range > 7 days'

    -- createdAt > updatedAt
    WHEN createdAt IS NOT NULL AND updatedAt IS NOT NULL AND TIMESTAMP(createdAt) > TIMESTAMP(updatedAt) THEN
      'createdAt is after updatedAt'

    ELSE NULL
  END AS error_type

FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`

WHERE
  DATE(etl_date) = @etl_date
  AND is_current = TRUE
  AND subscription.status IS NOT NULL
  AND (
    -- free trial hataları
    (freeTrialStartDate IS NOT NULL AND (freeTrialEndDate IS NULL OR LOWER(TRIM(freeTrialEndDate)) = 'null'))
    OR (
      freeTrialStartDate IS NOT NULL AND freeTrialEndDate IS NOT NULL AND (
        SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', freeTrialStartDate) IS NULL
        OR SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', freeTrialEndDate) IS NULL
        OR DATE(SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', freeTrialEndDate)) <
           DATE(SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', freeTrialStartDate))
        OR DATE_DIFF(
             DATE(SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', freeTrialEndDate)),
             DATE(SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Ez', freeTrialStartDate)),
             DAY
           ) > 7
      )
    )
    -- created/updated kontrolü
    OR (
      createdAt IS NOT NULL AND updatedAt IS NOT NULL AND TIMESTAMP(createdAt) > TIMESTAMP(updatedAt)
    )
  );
