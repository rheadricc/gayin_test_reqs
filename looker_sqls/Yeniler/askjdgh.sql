-- Payguru PAYMENT ve CANCEL/REFUND benzeri kayıtları aynı reference_code üzerinden eşleştirme
-- Kaynak: microgain-9f959.bc_t.payguru_transactions_raw
-- Tarih: 2026-06-16
-- Not: Payguru tablosunda transaction_type olmadığı için kayıt tipi status/status_text/error/error_detail/raw_json alanlarından türetilir.

WITH filtered_transactions AS (
  SELECT
    *,
    CASE
      WHEN REGEXP_CONTAINS(
        UPPER(CONCAT(
          COALESCE(status, ''), ' ',
          COALESCE(status_text, ''), ' ',
          COALESCE(error, ''), ' ',
          COALESCE(error_detail, ''), ' ',
          COALESCE(raw_json, '')
        )),
        r'(CANCEL|CANCELLED|CANCELED|REFUND|REFUNDED|VOID|IPTAL|İPTAL|IADE|İADE)'
      ) THEN 'CANCEL'
      WHEN amount > 0 THEN 'PAYMENT'
      ELSE 'OTHER'
    END AS derived_transaction_type
  FROM `microgain-9f959.bc_t.payguru_transactions_raw`
  WHERE reference_code IS NOT NULL
    AND source_date = DATE '2026-06-16'
),

payment_cancel_candidates AS (
  SELECT
    *
  FROM filtered_transactions
  WHERE derived_transaction_type IN ('PAYMENT', 'CANCEL')
),

matched_reference_codes AS (
  SELECT
    reference_code,
    COUNTIF(derived_transaction_type = 'PAYMENT') AS payment_row_count,
    COUNTIF(derived_transaction_type = 'CANCEL') AS cancel_row_count,
    COUNT(*) AS matched_row_count
  FROM payment_cancel_candidates
  GROUP BY reference_code
  HAVING payment_row_count > 0
     AND cancel_row_count > 0
)

SELECT
  f.*,
  m.payment_row_count,
  m.cancel_row_count,
  m.matched_row_count
FROM payment_cancel_candidates f
INNER JOIN matched_reference_codes m
  ON f.reference_code = m.reference_code
ORDER BY
  f.reference_code,
  CASE
    WHEN f.derived_transaction_type = 'PAYMENT' THEN 1
    WHEN f.derived_transaction_type = 'CANCEL' THEN 2
    ELSE 3
  END,
  f.transaction_date;