-- Iyzico PAYMENT ve CANCEL transaction_type eşleşen payment_id kayıtları
-- Kaynak: microgain-9f959.bc_t.iyzico_transactions_raw
-- Tarih: 2026-06-16

WITH filtered_transactions AS (
  SELECT
    *
  FROM `microgain-9f959.bc_t.iyzico_transactions_raw`
  WHERE payment_id IS NOT NULL
    AND report_date = DATE '2026-06-16'
    AND UPPER(transaction_type) IN ('PAYMENT', 'CANCEL')
),

matched_payment_ids AS (
  SELECT
    payment_id,
    COUNTIF(UPPER(transaction_type) = 'PAYMENT') AS payment_row_count,
    COUNTIF(UPPER(transaction_type) = 'CANCEL') AS cancel_row_count,
    COUNT(*) AS matched_row_count
  FROM filtered_transactions
  GROUP BY payment_id
  HAVING payment_row_count > 0
     AND cancel_row_count > 0
)

SELECT
  f.*,
  m.payment_row_count,
  m.cancel_row_count,
  m.matched_row_count
FROM filtered_transactions f
INNER JOIN matched_payment_ids m
  ON f.payment_id = m.payment_id
ORDER BY
  f.payment_id,
  CASE
    WHEN UPPER(f.transaction_type) = 'PAYMENT' THEN 1
    WHEN UPPER(f.transaction_type) = 'CANCEL' THEN 2
    ELSE 3
  END,
  f.transaction_date;
