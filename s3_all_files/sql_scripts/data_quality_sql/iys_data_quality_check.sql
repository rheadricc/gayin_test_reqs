-- T-1 user verisi için null kontrolleri ve platform doğruluğu

-- status NULL
SELECT user_id, 'status is NULL' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.iys_subs`
WHERE DATE(inserted_date) = @etl_date
  AND status IS NULL

UNION ALL

-- user_id NULL
SELECT user_id, 'user_id is NULL' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.iys_subs`
WHERE DATE(inserted_date) = @etl_date
  AND user_id IS NULL

UNION ALL

-- full_name NULL
SELECT user_id, 'full_name is NULL' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.iys_subs`
WHERE DATE(inserted_date) = @etl_date
  AND full_name IS NULL

UNION ALL

-- email NULL
SELECT user_id, 'email is NULL' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.iys_subs`
WHERE DATE(inserted_date) = @etl_date
  AND email IS NULL

UNION ALL

-- is_email_permitted NULL
SELECT user_id, 'is_email_permitted is NULL' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.iys_subs`
WHERE DATE(inserted_date) = @etl_date
  AND is_email_permitted IS NULL

UNION ALL

-- platform NULL
SELECT user_id, 'platform is NULL' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.iys_subs`
WHERE DATE(inserted_date) = @etl_date
  AND platform IS NULL

UNION ALL

-- created_at NULL
SELECT user_id, 'created_at is NULL' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.iys_subs`
WHERE DATE(inserted_date) = @etl_date
  AND created_at IS NULL

UNION ALL

-- inserted_date NULL
SELECT user_id, 'inserted_date is NULL' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.iys_subs`
WHERE DATE(inserted_date) = @etl_date
  AND inserted_date IS NULL

UNION ALL

-- platform geçersiz
SELECT user_id, 'platform is not in (UNKNOWN, ANDROID, WEB, IOS)' AS rule_violation
FROM `microgain-9f959.aws_s3_to_bq_migration.iys_subs`
WHERE DATE(inserted_date) = @etl_date
  AND platform NOT IN ('UNKNOWN', 'ANDROID', 'WEB', 'IOS');
