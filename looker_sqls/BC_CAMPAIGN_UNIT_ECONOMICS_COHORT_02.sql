-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Suggested output name: BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02
--
-- Granularity:
--   1 row per user per lifetime month
--
-- Revenue:
--   - realized cash revenue is counted once, in the payment month
--   - subscription validity is used only for active/retention calculations
--
-- CAC:
--   - blended monthly CAC = ads_daily_spend monthly total spend / all monthly
--     acquired paid users
--   - ad spend cannot be attributed reliably to NORMAL vs CAMPAIGN with the
--     available source fields; CAC is therefore a blended acquisition metric
--
-- Notes:
--   - use cohort_type_key = normal/campaign in Looker filters
--   - use *_anchor fields for scorecards to avoid user-month reweighting
--   - cumulative_inactive_flag is cumulative loss; churn_event_flag /
--     churn_risk_flag produce true month-over-month churn

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    LEAST(
      PARSE_DATE('%Y%m%d', @DS_END_DATE),
      DATE_SUB(CURRENT_DATE('Europe/Istanbul'), INTERVAL 1 DAY)
    ) AS ds_end
),

payment_option_config AS (
  SELECT 'APP_STORE'      AS payment_option, 0.30 AS commission_rate UNION ALL
  SELECT 'PLAY_STORE'     AS payment_option, 0.15 AS commission_rate UNION ALL
  SELECT 'MOBILE_PAYMENT' AS payment_option, 0.15 AS commission_rate UNION ALL
  SELECT 'CRAFTGATE'      AS payment_option, 0.00 AS commission_rate UNION ALL
  SELECT 'IYZICO'         AS payment_option, 0.03 AS commission_rate
),

tcmb_rates AS (
  SELECT
    DATE(rate_date) AS rate_date,
    UPPER(currency_code) AS currency_code,
    SAFE_DIVIDE(CAST(forex_buying AS FLOAT64), NULLIF(CAST(unit AS FLOAT64), 0.0)) AS rate_to_try
  FROM `microgain-9f959.bc_t.tcmb_exchange_rates_raw`
  WHERE currency_code IS NOT NULL
    AND forex_buying IS NOT NULL
    AND unit IS NOT NULL
),

/* =====================================================
   1) BASE SUBS DATA
   ===================================================== */
subs_base AS (
  SELECT
    s.user_id,
    s.status,
    s.payment_option,
    UPPER(TRIM(s.currency)) AS currency_code,
    s.created_at,
    s.inserted_date,
    DATE(s.created_at) AS created_date,
    DATE(s.valid_until) AS valid_until_date,
    s.apple_original_transaction_id,
    s.google_original_transaction_id,
    DATE(s.grace_until) AS grace_until_date,
    DATE(s.hold_until) AS hold_until_date,
    DATE(s.free_trial_start_date) AS free_trial_start_date,
    DATE(s.free_trial_end_date) AS free_trial_end_date,

    DATE(s.valid_until) AS paid_end_date,

    CAST(COALESCE(s.amount, 0) AS INT64) AS actual_amount_minor,
    SAFE_DIVIDE(CAST(COALESCE(s.amount, 0) AS FLOAT64), 100.0) AS actual_amount_original,
    SAFE_DIVIDE(CAST(COALESCE(s.amount_before_promotions, s.amount, 0) AS FLOAT64), 100.0) AS before_promo_amount_original,

    s.applied_promotions
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN params p
  WHERE s.user_id IS NOT NULL
    AND s.payment_option IS NOT NULL
    AND s.payment_option != 'PREPAID'
    AND DATE(s.created_at) <= p.ds_end
),

subs_with_rate_candidates AS (
  SELECT
    s.*,
    r.rate_date AS matched_rate_date,
    r.rate_to_try,
    ROW_NUMBER() OVER (
      PARTITION BY
        CAST(s.user_id AS STRING),
        s.payment_option,
        s.currency_code,
        s.created_at,
        s.inserted_date,
        s.valid_until_date,
        CAST(s.actual_amount_original AS STRING),
        CAST(s.before_promo_amount_original AS STRING)
      ORDER BY r.rate_date DESC
    ) AS rate_rn
  FROM subs_base s
  LEFT JOIN tcmb_rates r
    ON s.currency_code != 'TRY'
   AND r.currency_code = s.currency_code
   AND r.rate_date <= s.created_date
),

subs_converted AS (
  SELECT
    * EXCEPT(rate_rn),
    CASE
      WHEN currency_code = 'TRY' THEN actual_amount_original
      ELSE actual_amount_original * rate_to_try
    END AS actual_amount_gross_tl,
    GREATEST(
      CASE
        WHEN currency_code = 'TRY' THEN before_promo_amount_original
        WHEN UPPER(TRIM(payment_option)) IN ('APP_STORE', 'PLAY_STORE') THEN before_promo_amount_original
        ELSE before_promo_amount_original * rate_to_try
      END,
      CASE
        WHEN currency_code = 'TRY' THEN actual_amount_original
        ELSE actual_amount_original * rate_to_try
      END
    ) AS before_promo_amount_gross_tl
  FROM subs_with_rate_candidates
  WHERE currency_code = 'TRY'
     OR rate_rn = 1
),

/* Keep the latest warehouse snapshot of the same payment event. */
subs_transactions AS (
  SELECT *
  FROM subs_converted
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY
      CAST(user_id AS STRING),
      created_at,
      valid_until_date,
      UPPER(TRIM(payment_option)),
      currency_code,
      apple_original_transaction_id,
      google_original_transaction_id,
      actual_amount_minor
    ORDER BY inserted_date DESC
  ) = 1
),

/* =====================================================
   2) FIRST REAL PAID EVENT
   - first row where raw actual amount is > 101 minor units
   ===================================================== */
first_paid_raw AS (
  SELECT
    s.user_id,
    s.payment_option AS first_paid_payment_option,
    s.created_at AS first_paid_at,
    DATE(s.created_at) AS first_paid_date,
    s.inserted_date,
    ROW_NUMBER() OVER (
      PARTITION BY s.user_id
      ORDER BY s.created_at ASC, s.inserted_date ASC
    ) AS rn
  FROM subs_transactions s
  WHERE s.actual_amount_minor > 101
    AND s.actual_amount_gross_tl IS NOT NULL
),

first_paid AS (
  SELECT
    user_id,
    first_paid_payment_option,
    first_paid_at,
    first_paid_date
  FROM first_paid_raw
  WHERE rn = 1
),

/* =====================================================
   3) COHORT USERS
   ===================================================== */
cohort_users AS (
  SELECT
    fp.user_id,
    fp.first_paid_payment_option,
    fp.first_paid_at,
    fp.first_paid_date,
    DATE_TRUNC(fp.first_paid_date, MONTH) AS cohort_month
  FROM first_paid fp
  CROSS JOIN params p
  WHERE fp.first_paid_date BETWEEN p.ds_start AND p.ds_end
),

/* =====================================================
   4) PROMOTION ATTRIBUTION
   - any promo attached on/before first paid date
   ===================================================== */
promo_before_first_paid_raw AS (
  SELECT
    cu.user_id,
    CAST(ap.promotionId AS STRING) AS promotion_id,
    ARRAY_AGG(ap.name IGNORE NULLS ORDER BY ap.applyDate DESC LIMIT 1)[SAFE_OFFSET(0)] AS applied_promo_name,
    ARRAY_AGG(ap.type IGNORE NULLS ORDER BY ap.applyDate DESC LIMIT 1)[SAFE_OFFSET(0)] AS applied_promo_type,
    ARRAY_AGG(ap.isActive IGNORE NULLS ORDER BY ap.applyDate DESC LIMIT 1)[SAFE_OFFSET(0)] AS applied_promo_is_active,
    DATE(ap.applyDate) AS promo_apply_date,
    MAX(DATE(ap.leaveDate)) AS promo_leave_date
  FROM cohort_users cu
  JOIN subs_transactions sb
    ON cu.user_id = sb.user_id
   AND sb.created_at <= cu.first_paid_at
  CROSS JOIN UNNEST(sb.applied_promotions) ap
  WHERE ap.promotionId IS NOT NULL
    AND COALESCE(DATE(ap.applyDate), sb.created_date) <= cu.first_paid_date
  GROUP BY cu.user_id, promotion_id, promo_apply_date
),

promo_before_first_paid AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY user_id
      ORDER BY promo_apply_date DESC, promotion_id
    ) AS rn
  FROM promo_before_first_paid_raw
),

acquisition_promo AS (
  SELECT
    user_id,
    promotion_id,
    applied_promo_name,
    applied_promo_type,
    applied_promo_is_active,
    promo_apply_date,
    promo_leave_date
  FROM promo_before_first_paid
  WHERE rn = 1
),

promotion_dim AS (
  SELECT
    CAST(promotionId AS STRING) AS promotion_id,
    COALESCE(name, promotionDescription) AS promotion_name,
    type AS promotion_type,
    isActive AS promotion_is_active
  FROM `microgain-9f959.Backoffice_metadata.bo_promotions`
),

/* =====================================================
   5) COHORT LABELS
   ===================================================== */
cohort_labeled AS (
  SELECT
    cu.user_id,
    cu.first_paid_payment_option,
    cu.first_paid_at,
    cu.first_paid_date,
    cu.cohort_month,

    CASE
      WHEN ap.promotion_id IS NOT NULL THEN 'CAMPAIGN'
      ELSE 'NORMAL'
    END AS cohort_type,

    ap.promotion_id,
    COALESCE(pd.promotion_name, ap.applied_promo_name) AS promotion_name,
    COALESCE(pd.promotion_type, ap.applied_promo_type) AS promotion_type,
    COALESCE(pd.promotion_is_active, ap.applied_promo_is_active) AS promotion_is_active,

    ap.promo_apply_date,
    ap.promo_leave_date,

    CASE
      WHEN ap.promotion_id IS NOT NULL THEN ap.promo_leave_date
      ELSE NULL
    END AS campaign_end_date
  FROM cohort_users cu
  LEFT JOIN acquisition_promo ap
    ON cu.user_id = ap.user_id
  LEFT JOIN promotion_dim pd
    ON ap.promotion_id = pd.promotion_id
),

/* =====================================================
   6) DAILY PAID ACTIVITY AFTER FIRST PAID DATE
   ===================================================== */
daily_active_raw AS (
  SELECT
    d AS dt,
    sb.user_id,
    cl.cohort_type,
    cl.promotion_id,
    cl.promotion_name,
    cl.promotion_type,
    cl.promotion_is_active,
    cl.first_paid_date,
    cl.cohort_month,
    cl.first_paid_payment_option,
    cl.campaign_end_date,

    sb.created_at,
    sb.inserted_date
  FROM subs_transactions sb
  JOIN cohort_labeled cl
    ON sb.user_id = cl.user_id
   AND sb.actual_amount_minor > 101
   AND sb.actual_amount_gross_tl IS NOT NULL
  CROSS JOIN params p
  CROSS JOIN UNNEST(
    GENERATE_DATE_ARRAY(
      GREATEST(sb.created_date, cl.first_paid_date),
      LEAST(COALESCE(sb.paid_end_date, sb.created_date), p.ds_end)
    )
  ) AS d
  WHERE COALESCE(sb.paid_end_date, sb.created_date) >= cl.first_paid_date
),

daily_active_dedup AS (
  SELECT
    dt,
    user_id,
    cohort_type,
    promotion_id,
    promotion_name,
    promotion_type,
    promotion_is_active,
    first_paid_date,
    cohort_month,
    first_paid_payment_option,
    campaign_end_date,
    1 AS active_flag
  FROM (
    SELECT
      r.*,
      ROW_NUMBER() OVER (
        PARTITION BY r.dt, r.user_id
        ORDER BY r.created_at DESC, r.inserted_date DESC
      ) AS rn
    FROM daily_active_raw r
  )
  WHERE rn = 1
),

/* =====================================================
   7) USER-MONTH ACTIVITY + REALIZED PAYMENT REVENUE
   ===================================================== */
user_month_activity AS (
  SELECT
    user_id,
    cohort_type,
    promotion_id,
    promotion_name,
    promotion_type,
    promotion_is_active,
    first_paid_date,
    cohort_month,
    first_paid_payment_option,
    campaign_end_date,
    DATE_TRUNC(dt, MONTH) AS activity_month,
    DATE_DIFF(DATE_TRUNC(dt, MONTH), cohort_month, MONTH) AS lifetime_month,
    MAX(
      IF(
        dt = LEAST(
          LAST_DAY(dt),
          p.ds_end
        ),
        1,
        0
      )
    ) AS active_flag
  FROM daily_active_dedup
  CROSS JOIN params p
  GROUP BY
    user_id,
    cohort_type,
    promotion_id,
    promotion_name,
    promotion_type,
    promotion_is_active,
    first_paid_date,
    cohort_month,
    first_paid_payment_option,
    campaign_end_date,
    activity_month,
    lifetime_month
),

transaction_revenue AS (
  SELECT
    sb.user_id,
    DATE_TRUNC(sb.created_date, MONTH) AS activity_month,
    SUM(
      sb.actual_amount_gross_tl
        * (1.0 - COALESCE(cfg.commission_rate, 0.00))
    ) AS actual_net_revenue_tl,
    SUM(
      sb.before_promo_amount_gross_tl
        * (1.0 - COALESCE(cfg.commission_rate, 0.00))
    ) AS gross_net_revenue_before_promo_tl
  FROM subs_transactions sb
  JOIN cohort_labeled cl
    ON sb.user_id = cl.user_id
   AND sb.created_at >= cl.first_paid_at
  CROSS JOIN params p
  LEFT JOIN payment_option_config cfg
    ON UPPER(TRIM(sb.payment_option)) = cfg.payment_option
  WHERE sb.actual_amount_minor > 101
    AND sb.actual_amount_gross_tl IS NOT NULL
    AND sb.created_date <= p.ds_end
  GROUP BY sb.user_id, activity_month
),

/* =====================================================
   8) USER-MONTH SPINE
   ===================================================== */
user_month_spine AS (
  SELECT
    cl.user_id,
    cl.cohort_type,
    cl.promotion_id,
    cl.promotion_name,
    cl.promotion_type,
    cl.promotion_is_active,
    cl.first_paid_date,
    cl.cohort_month,
    cl.first_paid_payment_option,
    cl.campaign_end_date,
    month_dt AS activity_month,
    DATE_DIFF(month_dt, cl.cohort_month, MONTH) AS lifetime_month
  FROM cohort_labeled cl
  CROSS JOIN params p
  CROSS JOIN UNNEST(
    GENERATE_DATE_ARRAY(
      cl.cohort_month,
      DATE_TRUNC(p.ds_end, MONTH),
      INTERVAL 1 MONTH
    )
  ) AS month_dt
),

user_month_final AS (
  SELECT
    s.user_id,
    s.cohort_type,
    s.promotion_id,
    s.promotion_name,
    s.promotion_type,
    s.promotion_is_active,
    s.first_paid_date,
    s.cohort_month,
    s.first_paid_payment_option,
    s.campaign_end_date,
    s.activity_month,
    s.lifetime_month,

    COALESCE(a.active_flag, 0) AS active_flag,
    COALESCE(r.actual_net_revenue_tl, 0) AS actual_net_revenue_tl,
    COALESCE(r.gross_net_revenue_before_promo_tl, 0) AS gross_net_revenue_before_promo_tl
  FROM user_month_spine s
  LEFT JOIN user_month_activity a
    ON s.user_id = a.user_id
   AND s.activity_month = a.activity_month
  LEFT JOIN transaction_revenue r
    ON s.user_id = r.user_id
   AND s.activity_month = r.activity_month
),

/* =====================================================
   9) MONTHLY CAC
   - blended CAC for each cohort month
   ===================================================== */
monthly_spend AS (
  SELECT
    DATE_TRUNC(DATE(day), MONTH) AS cohort_month,
    SUM(spend_tl) AS total_spend_tl
  FROM `microgain-9f959.bc_marketing_marts.ads_daily_spend`
  CROSS JOIN params p
  WHERE DATE(day) BETWEEN DATE_TRUNC(p.ds_start, MONTH) AND p.ds_end
  GROUP BY cohort_month
),

monthly_acquired_users AS (
  SELECT
    cohort_month,
    COUNT(DISTINCT user_id) AS acquired_users
  FROM cohort_labeled
  GROUP BY cohort_month
),

monthly_cac AS (
  SELECT
    a.cohort_month,
    a.acquired_users,
    s.total_spend_tl,
    SAFE_DIVIDE(s.total_spend_tl, a.acquired_users) AS cac_tl
  FROM monthly_acquired_users a
  LEFT JOIN monthly_spend s
    ON a.cohort_month = s.cohort_month
),

/* =====================================================
   10) CUMULATIVE LTV + CAC JOIN
   ===================================================== */
final_with_ltv AS (
  SELECT
    f.*,

    SUM(f.actual_net_revenue_tl) OVER (
      PARTITION BY f.user_id
      ORDER BY f.activity_month
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cum_actual_ltv_tl,

    SUM(f.gross_net_revenue_before_promo_tl) OVER (
      PARTITION BY f.user_id
      ORDER BY f.activity_month
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cum_gross_ltv_before_promo_tl,

    CASE
      WHEN f.campaign_end_date IS NOT NULL THEN DATE_DIFF(
        DATE_TRUNC(f.campaign_end_date, MONTH),
        f.cohort_month,
        MONTH
      )
      ELSE NULL
    END AS campaign_end_lifetime_month
  FROM user_month_final f
),

final_joined AS (
  SELECT
    l.*,
    c.total_spend_tl,
    c.acquired_users,
    c.cac_tl,
    SAFE_DIVIDE(l.cum_actual_ltv_tl, c.cac_tl) AS ltv_cac_ratio_actual,
    SAFE_DIVIDE(l.cum_gross_ltv_before_promo_tl, c.cac_tl) AS ltv_cac_ratio_gross_before_promo
  FROM final_with_ltv l
  LEFT JOIN monthly_cac c
    ON l.cohort_month = c.cohort_month
),

final_with_helper_fields AS (
  SELECT
    f.*,
    LOWER(f.cohort_type) AS cohort_type_key,
    IF(f.lifetime_month = 0, f.cac_tl, NULL) AS cac_user_anchor_tl,
    IF(
      f.activity_month = DATE_TRUNC(p.ds_end, MONTH),
      f.cum_actual_ltv_tl,
      NULL
    ) AS terminal_realized_ltv_anchor_tl,
    IF(
      f.activity_month = DATE_TRUNC(p.ds_end, MONTH),
      SAFE_DIVIDE(f.cum_actual_ltv_tl, f.cac_tl),
      NULL
    ) AS terminal_user_ltv_cac_anchor,
    LAST_DAY(f.cohort_month) <= p.ds_end AS is_completed_cohort_month,
    LAST_DAY(f.activity_month) <= p.ds_end AS is_completed_activity_month,
    CASE
      WHEN f.total_spend_tl IS NULL THEN 'missing_spend'
      WHEN f.acquired_users IS NULL OR f.acquired_users = 0 THEN 'missing_acquired_users'
      ELSE 'ok'
    END AS cac_status,
    1 - f.active_flag AS cumulative_inactive_flag,
    LAG(f.active_flag) OVER (
      PARTITION BY f.user_id
      ORDER BY f.activity_month
    ) AS previous_active_flag
  FROM final_joined f
  CROSS JOIN params p
),

final_output AS (
  SELECT
    f.*,
    IF(f.previous_active_flag = 1, 1, 0) AS churn_risk_flag,
    IF(f.previous_active_flag = 1 AND f.active_flag = 0, 1, 0) AS churn_event_flag,
    MIN(
      IF(f.cum_actual_ltv_tl >= f.cac_tl, f.lifetime_month, NULL)
    ) OVER (PARTITION BY f.user_id) AS realized_payback_lifetime_month
  FROM final_with_helper_fields f
)

SELECT
  user_id,
  cohort_type,
  cohort_type_key,
  promotion_id,
  promotion_name,
  promotion_type,
  promotion_is_active,

  first_paid_date,
  cohort_month,
  first_paid_payment_option,

  campaign_end_date,
  campaign_end_lifetime_month,

  activity_month,
  lifetime_month,
  active_flag,
  cumulative_inactive_flag,
  previous_active_flag,
  churn_risk_flag,
  churn_event_flag,

  actual_net_revenue_tl,
  gross_net_revenue_before_promo_tl,

  cum_actual_ltv_tl,
  cum_gross_ltv_before_promo_tl,

  total_spend_tl,
  acquired_users,
  cac_tl,
  cac_user_anchor_tl,

  ltv_cac_ratio_actual,
  ltv_cac_ratio_gross_before_promo,
  terminal_realized_ltv_anchor_tl,
  terminal_user_ltv_cac_anchor,
  is_completed_cohort_month,
  is_completed_activity_month,
  cac_status,
  realized_payback_lifetime_month
FROM final_output
ORDER BY cohort_month, cohort_type, promotion_name, user_id, lifetime_month;
