
  SELECT
  userId,
  email,
  fullName,
  status,
  birthDate,
  createdAt,
  verificationStatus,
  ARRAY_LENGTH(profiles) AS profile_count,
  (
    SELECT ARRAY_AGG(profile.id IGNORE NULLS)
    FROM UNNEST(profiles) AS profile
  ) AS profile_ids,

  CASE
    WHEN userId IS NULL THEN 'userId is NULL'
    WHEN NOT REGEXP_CONTAINS(userId, r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') THEN 'userId invalid UUID'
    WHEN email IS NULL THEN 'email is NULL'
    WHEN fullName IS NULL THEN 'fullName is NULL'
    WHEN status IS NULL THEN 'status is NULL'
    WHEN createdAt IS NULL THEN 'createdAt is NULL'
    WHEN verificationStatus IS NULL THEN 'verificationStatus is NULL'
    WHEN DATE_DIFF(@etl_date, SAFE.PARSE_DATE('%d/%m/%Y', birthDate), YEAR) < 18 THEN 'under 18'
    WHEN profiles IS NULL OR ARRAY_LENGTH(profiles) = 0 THEN 'profiles is NULL or empty'
    WHEN EXISTS (
      SELECT 1
      FROM UNNEST(profiles) AS profile
      WHERE profile.id IS NULL OR NOT (
        REGEXP_CONTAINS(profile.id, r'^[A-Z0-9]{24}$') OR
        REGEXP_CONTAINS(profile.id, r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
      )
    ) THEN 'invalid profile.id format'
    ELSE 'unknown issue'
  END AS error_reason

FROM `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`

WHERE
  DATE(etl_date) = @etl_date
  AND createdAt >= '2025-01-25'
  AND (
    userId IS NULL
    OR NOT REGEXP_CONTAINS(userId, r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
    OR email IS NULL
    OR fullName IS NULL
    OR status IS NULL
    OR createdAt IS NULL
    OR verificationStatus IS NULL
    OR DATE_DIFF(@etl_date, SAFE.PARSE_DATE('%d/%m/%Y', birthDate), YEAR) < 18
    OR profiles IS NULL
    OR ARRAY_LENGTH(profiles) = 0
    OR EXISTS (
      SELECT 1
      FROM UNNEST(profiles) AS profile
      WHERE profile.id IS NULL OR NOT (
        REGEXP_CONTAINS(profile.id, r'^[A-Z0-9]{24}$') OR
        REGEXP_CONTAINS(profile.id, r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
      )
    )
  );

