-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Name: BC_PAYMENT_PROVIDER_KPIS_01
--
-- Provider-only finance scorecards. Backoffice/subs_payment is not used.
--
-- Five KPI fields:
--   1. previous_month_gross_collections_tl
--   2. previous_month_net_collections_tl
--   3. previous_month_transaction_count
--   4. selected_period_net_collections_tl
--   5. selected_period_transaction_count
--
-- Important:
--   Raw provider transactions cannot produce a true subscription MRR snapshot.
--   The first KPI is therefore last completed month's GROSS COLLECTIONS, not MRR.
--
-- Included sources:
--   Apple: reported customer price and developer proceeds
--   Google: charged amount; 15% fallback commission
--   Iyzico: paid amount and merchant payout; cancel/refund reversals included
--   Payguru: status=3 and amount>1.01; 15% commission fallback
--
-- Payguru status 4/5/8/9 are failures. Status 6 is excluded from revenue and
-- transaction count; current data indicates a 0.01 lifecycle/reversal record,
-- not a monetary refund to subtract. Nkolay and Param are not currently in scope.

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    LEAST(
      PARSE_DATE('%Y%m%d', @DS_END_DATE),
      DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
    ) AS ds_end,
    DATE_TRUNC(
      DATE_SUB(
        LEAST(
          PARSE_DATE('%Y%m%d', @DS_END_DATE),
          DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
        ),
        INTERVAL 1 MONTH
      ),
      MONTH
    ) AS previous_month_start,
    LAST_DAY(
      DATE_SUB(
        LEAST(
          PARSE_DATE('%Y%m%d', @DS_END_DATE),
          DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
        ),
        INTERVAL 1 MONTH
      )
    ) AS previous_month_end
),

tcmb_rates AS (
  SELECT
    DATE(rate_date) AS rate_date,
    UPPER(currency_code) AS currency_code,
    SAFE_DIVIDE(
      CAST(forex_buying AS FLOAT64),
      NULLIF(CAST(unit AS FLOAT64), 0.0)
    ) AS rate_to_try
  FROM `microgain-9f959.bc_t.tcmb_exchange_rates_raw`
  WHERE currency_code IS NOT NULL
    AND forex_buying IS NOT NULL
    AND unit IS NOT NULL
),

google_dedup AS (
  SELECT * EXCEPT(rn)
  FROM (
    SELECT
      g.*,
      ROW_NUMBER() OVER (
        PARTITION BY
          order_number,
          order_charged_date,
          financial_status,
          currency_of_sale,
          charged_amount
        ORDER BY export_loaded_at_utc DESC
      ) AS rn
    FROM `microgain-9f959.bc_t.googleplay_transactions_raw` g
    CROSS JOIN params p
    WHERE order_charged_date BETWEEN
      LEAST(p.ds_start, p.previous_month_start) AND p.ds_end
  )
  WHERE rn = 1
),

google_rate_candidates AS (
  SELECT
    g.order_number,
    g.order_charged_date AS transaction_date,
    UPPER(g.financial_status) AS transaction_type,
    UPPER(g.currency_of_sale) AS currency_code,
    CAST(g.charged_amount AS FLOAT64) AS amount_original,
    r.rate_to_try,
    ROW_NUMBER() OVER (
      PARTITION BY
        g.order_number,
        g.order_charged_date,
        g.financial_status,
        g.currency_of_sale,
        g.charged_amount
      ORDER BY r.rate_date DESC
    ) AS rate_rn
  FROM google_dedup g
  LEFT JOIN tcmb_rates r
    ON UPPER(g.currency_of_sale) != 'TRY'
   AND r.currency_code = UPPER(g.currency_of_sale)
   AND r.rate_date <= g.order_charged_date
),

google_events AS (
  SELECT
    transaction_date,
    payment_provider,
    transaction_type = 'CHARGED' AND gross_tl > 1.01 AS is_positive_payment,
    gross_tl,
    net_tl
  FROM (
    SELECT
      transaction_date,
      'Google Play' AS payment_provider,
      transaction_type,
      CASE
        WHEN currency_code = 'TRY' THEN amount_original
        ELSE amount_original * rate_to_try
      END AS gross_tl,
      CASE
        WHEN currency_code = 'TRY' THEN amount_original * 0.85
        ELSE amount_original * rate_to_try * 0.85
      END AS net_tl
    FROM google_rate_candidates
    WHERE currency_code = 'TRY' OR rate_rn = 1
  )
),

apple_dedup AS (
  SELECT
    * EXCEPT(rn)
  FROM (
    SELECT
      a.*,
      ROW_NUMBER() OVER (
        PARTITION BY
          source_report_date,
          event_date,
          subscription_apple_id,
          subscriber_id,
          refund,
          purchase_date,
          customer_price,
          customer_currency,
          developer_proceeds,
          proceeds_currency,
          units
        ORDER BY export_loaded_at_utc DESC
      ) AS rn
    FROM `microgain-9f959.bc_t.apple_transactions_raw` a
    CROSS JOIN params p
    WHERE event_date BETWEEN
      LEAST(p.ds_start, p.previous_month_start) AND p.ds_end
  )
  WHERE rn = 1
),

apple_rate_candidates AS (
  SELECT
    a.event_date AS transaction_date,
    COALESCE(a.refund, '') AS refund,
    CAST(a.customer_price AS FLOAT64) * CAST(a.units AS FLOAT64)
      AS gross_original,
    UPPER(a.customer_currency) AS gross_currency,
    CAST(a.developer_proceeds AS FLOAT64) * ABS(CAST(a.units AS FLOAT64))
      AS proceeds_original_abs,
    UPPER(a.proceeds_currency) AS proceeds_currency,
    gross_rate.rate_to_try AS gross_rate_to_try,
    proceeds_rate.rate_to_try AS proceeds_rate_to_try,
    ROW_NUMBER() OVER (
      PARTITION BY
        a.source_report_date,
        a.event_date,
        a.subscription_apple_id,
        a.subscriber_id,
        a.refund,
        a.purchase_date,
        a.customer_price,
        a.customer_currency,
        a.developer_proceeds,
        a.proceeds_currency,
        a.units
      ORDER BY gross_rate.rate_date DESC, proceeds_rate.rate_date DESC
    ) AS rate_rn
  FROM apple_dedup a
  LEFT JOIN tcmb_rates gross_rate
    ON UPPER(a.customer_currency) != 'TRY'
   AND gross_rate.currency_code = UPPER(a.customer_currency)
   AND gross_rate.rate_date <= a.event_date
  LEFT JOIN tcmb_rates proceeds_rate
    ON UPPER(a.proceeds_currency) != 'TRY'
   AND proceeds_rate.currency_code = UPPER(a.proceeds_currency)
   AND proceeds_rate.rate_date <= a.event_date
),

apple_events AS (
  SELECT
    transaction_date,
    payment_provider,
    UPPER(refund) != 'YES' AND gross_tl > 1.01 AS is_positive_payment,
    gross_tl,
    net_tl
  FROM (
    SELECT
      transaction_date,
      'Apple / App Store' AS payment_provider,
      refund,
      CASE
        WHEN gross_currency = 'TRY' THEN gross_original
        ELSE gross_original * gross_rate_to_try
      END AS gross_tl,
      (
        CASE WHEN UPPER(refund) = 'YES' THEN -1.0 ELSE 1.0 END
      ) * (
        CASE
          WHEN proceeds_currency = 'TRY' THEN proceeds_original_abs
          ELSE proceeds_original_abs * proceeds_rate_to_try
        END
      ) AS net_tl
    FROM apple_rate_candidates
    WHERE rate_rn = 1
      AND (gross_currency = 'TRY' OR gross_rate_to_try IS NOT NULL)
      AND (proceeds_currency = 'TRY' OR proceeds_rate_to_try IS NOT NULL)
  )
),

iyzico_payment_payout_ratio AS (
  SELECT
    payment_id,
    SAFE_DIVIDE(
      CAST(merchant_payout_amount AS FLOAT64),
      NULLIF(CAST(amount AS FLOAT64), 0)
    ) AS payout_ratio
  FROM `microgain-9f959.bc_t.iyzico_transactions_raw`
  WHERE UPPER(transaction_type) = 'PAYMENT'
    AND payment_id IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY payment_id
    ORDER BY etl_loaded_at DESC
  ) = 1
),

iyzico_dedup AS (
  SELECT * EXCEPT(rn)
  FROM (
    SELECT
      i.*,
      ROW_NUMBER() OVER (
        PARTITION BY transaction_id
        ORDER BY etl_loaded_at DESC
      ) AS rn
    FROM `microgain-9f959.bc_t.iyzico_transactions_raw` i
    CROSS JOIN params p
    WHERE report_date BETWEEN
      LEAST(p.ds_start, p.previous_month_start) AND p.ds_end
  )
  WHERE rn = 1
),

iyzico_events AS (
  SELECT
    i.report_date AS transaction_date,
    'Iyzico' AS payment_provider,
    UPPER(i.transaction_type) = 'PAYMENT'
      AND CAST(i.amount AS FLOAT64) > 1.01 AS is_positive_payment,
    CASE
      WHEN UPPER(i.transaction_type) = 'PAYMENT'
        THEN CAST(i.amount AS FLOAT64)
      WHEN UPPER(i.transaction_type) IN ('CANCEL', 'REFUND')
        THEN -ABS(CAST(i.amount AS FLOAT64))
    END AS gross_tl,
    CASE
      WHEN UPPER(i.transaction_type) = 'PAYMENT'
        THEN COALESCE(
          CAST(i.merchant_payout_amount AS FLOAT64),
          CAST(i.amount AS FLOAT64) * 0.97
        )
      WHEN UPPER(i.transaction_type) IN ('CANCEL', 'REFUND')
        THEN -ABS(CAST(i.amount AS FLOAT64))
          * COALESCE(r.payout_ratio, 0.97)
    END AS net_tl
  FROM iyzico_dedup i
  LEFT JOIN iyzico_payment_payout_ratio r
    ON i.payment_id = r.payment_id
  WHERE UPPER(i.transaction_type) IN ('PAYMENT', 'CANCEL', 'REFUND')
    AND UPPER(COALESCE(i.currency, i.transaction_currency)) = 'TRY'
),

payguru_dedup AS (
  SELECT * EXCEPT(rn)
  FROM (
    SELECT
      pg.*,
      ROW_NUMBER() OVER (
        PARTITION BY transaction_id
        ORDER BY
          COALESCE(modified_date, transaction_date) DESC,
          etl_loaded_at DESC
      ) AS rn
    FROM `microgain-9f959.bc_t.payguru_transactions_raw` pg
    CROSS JOIN params p
    WHERE DATE(transaction_date) BETWEEN
      LEAST(p.ds_start, p.previous_month_start) AND p.ds_end
  )
  WHERE rn = 1
),

payguru_events AS (
  SELECT
    DATE(transaction_date) AS transaction_date,
    'Payguru / Mobil Ödeme' AS payment_provider,
    TRUE AS is_positive_payment,
    CAST(amount AS FLOAT64) AS gross_tl,
    CAST(amount AS FLOAT64) * 0.85 AS net_tl
  FROM payguru_dedup
  WHERE status = '3'
    AND CAST(amount AS FLOAT64) > 1.01
    AND UPPER(currency) = 'TRY'
),

provider_events AS (
  SELECT * FROM google_events
  UNION ALL
  SELECT * FROM apple_events
  UNION ALL
  SELECT * FROM iyzico_events
  UNION ALL
  SELECT * FROM payguru_events
),

valid_events AS (
  SELECT *
  FROM provider_events
  WHERE gross_tl IS NOT NULL
    AND net_tl IS NOT NULL
),

provider_coverage AS (
  SELECT
    COUNT(DISTINCT payment_provider) AS included_provider_count,
    STRING_AGG(DISTINCT payment_provider, ', ' ORDER BY payment_provider)
      AS included_providers
  FROM valid_events
)

SELECT
  p.ds_end AS metric_date,
  p.previous_month_start,
  p.previous_month_end,
  p.ds_start AS selected_period_start,
  p.ds_end AS selected_period_end,
  ANY_VALUE(pc.included_provider_count) AS included_provider_count,
  ANY_VALUE(pc.included_providers) AS included_providers,
  TRUE AS net_contains_estimates,

  SUM(
    IF(
      e.transaction_date BETWEEN p.previous_month_start AND p.previous_month_end,
      e.gross_tl,
      0
    )
  ) AS previous_month_gross_collections_tl,

  SUM(
    IF(
      e.transaction_date BETWEEN p.previous_month_start AND p.previous_month_end
      AND e.gross_tl < 0,
      ABS(e.gross_tl),
      0
    )
  ) AS previous_month_refund_gross_tl,

  SUM(
    IF(
      e.transaction_date BETWEEN p.previous_month_start AND p.previous_month_end,
      e.net_tl,
      0
    )
  ) AS previous_month_net_collections_tl,

  COUNTIF(
    e.transaction_date BETWEEN p.previous_month_start AND p.previous_month_end
    AND e.is_positive_payment
  ) AS previous_month_transaction_count,

  SUM(
    IF(
      e.transaction_date BETWEEN p.ds_start AND p.ds_end,
      e.net_tl,
      0
    )
  ) AS selected_period_net_collections_tl,

  SUM(
    IF(
      e.transaction_date BETWEEN p.ds_start AND p.ds_end
      AND e.gross_tl < 0,
      ABS(e.gross_tl),
      0
    )
  ) AS selected_period_refund_gross_tl,

  COUNTIF(
    e.transaction_date BETWEEN p.ds_start AND p.ds_end
    AND e.is_positive_payment
  ) AS selected_period_transaction_count,

  SAFE_DIVIDE(
    SUM(
      IF(
        e.transaction_date BETWEEN p.ds_start AND p.ds_end,
        e.net_tl,
        0
      )
    ),
    COUNTIF(
      e.transaction_date BETWEEN p.ds_start AND p.ds_end
      AND e.is_positive_payment
    )
  ) AS selected_period_avg_net_per_transaction_tl

FROM params p
LEFT JOIN provider_coverage pc
  ON TRUE
LEFT JOIN valid_events e
  ON e.transaction_date BETWEEN
    LEAST(p.ds_start, p.previous_month_start) AND p.ds_end
GROUP BY
  metric_date,
  previous_month_start,
  previous_month_end,
  selected_period_start,
  selected_period_end;
