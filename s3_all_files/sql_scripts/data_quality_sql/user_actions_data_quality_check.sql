-- user_actions tablosu için T-1 data quality kontrolleri

-- Kural: status NULL veya geçersiz
SELECT
  user_id,
  'status is NULL or invalid (must be DELETE_ACCOUNT, VERIFY_EMAIL, SIGNUP)' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.user_actions`
WHERE DATE(inserted_date) = @etl_date
  AND (status IS NULL OR status NOT IN ('DELETE_ACCOUNT', 'VERIFY_EMAIL', 'SIGNUP'))

UNION ALL

-- Kural: user_id NULL veya geçersiz UUID
SELECT
  user_id,
  'user_id is NULL or invalid UUID format' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.user_actions`
WHERE DATE(inserted_date) = @etl_date
  AND (
    user_id IS NULL OR NOT REGEXP_CONTAINS(user_id, r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
  )

UNION ALL

-- Kural: email NULL
SELECT
  user_id,
  'email is NULL' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.user_actions`
WHERE DATE(inserted_date) = @etl_date
  AND email IS NULL

UNION ALL

-- Kural: created_at NULL
SELECT
  user_id,
  'created_at is NULL' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.user_actions`
WHERE DATE(inserted_date) = @etl_date
  AND created_at IS NULL

UNION ALL

-- Kural: inserted_date NULL
SELECT
  user_id,
  'inserted_date is NULL' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.user_actions`
WHERE DATE(inserted_date) = @etl_date
  AND inserted_date IS NULL

UNION ALL

-- Kural: status = 'VERIFY_EMAIL' ise verification_at NULL olamaz
SELECT
  user_id,
  'status is VERIFY_EMAIL but verification_at is NULL' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.user_actions`
WHERE DATE(inserted_date) = @etl_date
  AND status = 'VERIFY_EMAIL'
  AND verification_at IS NULL;
