-- Bu sorgu, `subs_payment` tablosundaki Google Play Store üzerinden yapılan ödemeleri, 
-- Google'ın sağladığı aylık ödeme verileriyle karşılaştırarak, eşleşmeyen kayıtları raporlar.
-- BQ içerisinde 'google_payment_join_subs_payment_*' isimli table'lar içerisinden tekrar okunabilir halde.

WITH subs_base AS (
  SELECT
    *
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE google_original_transaction_id IS NOT NULL
    AND TRIM(google_original_transaction_id) != ''
    -- İstersen bunu aç:
    -- AND payment_option = 'PLAY_STORE'
),

google_nov AS (
  SELECT DISTINCT
    TRIM(google_original_transaction_id) AS google_original_transaction_id
  FROM `microgain-9f959.bc_t.google_payment_nov2025`
  WHERE google_original_transaction_id IS NOT NULL
    AND TRIM(google_original_transaction_id) != ''
),

google_dec AS (
  SELECT DISTINCT
    TRIM(google_original_transaction_id) AS google_original_transaction_id
  FROM `microgain-9f959.bc_t.google_payment_dec2025`
  WHERE google_original_transaction_id IS NOT NULL
    AND TRIM(google_original_transaction_id) != ''
),

google_jan AS (
  SELECT DISTINCT
    TRIM(google_original_transaction_id) AS google_original_transaction_id
  FROM `microgain-9f959.bc_t.google_payment_jan2026`
  WHERE google_original_transaction_id IS NOT NULL
    AND TRIM(google_original_transaction_id) != ''
),

google_feb AS (
  SELECT DISTINCT
    TRIM(google_original_transaction_id) AS google_original_transaction_id
  FROM `microgain-9f959.bc_t.google_payment_feb2026`
  WHERE google_original_transaction_id IS NOT NULL
    AND TRIM(google_original_transaction_id) != ''
)

SELECT
  '2025-11' AS report_month,
  s.*
FROM subs_base s
LEFT JOIN google_nov g
  ON TRIM(s.google_original_transaction_id) = g.google_original_transaction_id
WHERE DATE(s.created_at) BETWEEN DATE '2025-11-01' AND DATE '2025-11-30'
  AND g.google_original_transaction_id IS NULL

UNION ALL

SELECT
  '2025-12' AS report_month,
  s.*
FROM subs_base s
LEFT JOIN google_dec g
  ON TRIM(s.google_original_transaction_id) = g.google_original_transaction_id
WHERE DATE(s.created_at) BETWEEN DATE '2025-12-01' AND DATE '2025-12-31'
  AND g.google_original_transaction_id IS NULL

UNION ALL

SELECT
  '2026-01' AS report_month,
  s.*
FROM subs_base s
LEFT JOIN google_jan g
  ON TRIM(s.google_original_transaction_id) = g.google_original_transaction_id
WHERE DATE(s.created_at) BETWEEN DATE '2026-01-01' AND DATE '2026-01-31'
  AND g.google_original_transaction_id IS NULL

UNION ALL

SELECT
  '2026-02' AS report_month,
  s.*
FROM subs_base s
LEFT JOIN google_feb g
  ON TRIM(s.google_original_transaction_id) = g.google_original_transaction_id
WHERE DATE(s.created_at) BETWEEN DATE '2026-02-01' AND DATE '2026-02-28'
  AND g.google_original_transaction_id IS NULL

ORDER BY report_month, created_at DESC;