-- Looker Studio params: @DS_START_DATE, @DS_END_DATE (YYYYMMDD)
-- Suggested output name: BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02
--
-- Granularity:
--   1 row per user per lifetime month
--
--   - blended monthly CAC = ads_daily_spend monthly total spend / monthly acquired users
--
-- Notes:
--   - CAC is blended monthly CAC, same for NORMAL and CAMPAIGN within same cohort_month
--   - churn can be derived in Looker as 1 - AVG(active_flag)

WITH params AS (
  SELECT
    PARSE_DATE('%Y%m%d', @DS_START_DATE) AS ds_start,
    PARSE_DATE('%Y%m%d', @DS_END_DATE)   AS ds_end
),

payment_option_config AS (
  SELECT 'APP_STORE'      AS payment_option, 0.30 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'PLAY_STORE'     AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'MOBILE_PAYMENT' AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'CRAFTGATE'      AS payment_option, 0.00 AS commission_rate, 0.20 AS tax_rate UNION ALL
  SELECT 'IYZICO'         AS payment_option, 0.03 AS commission_rate, 0.20 AS tax_rate
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
    DATE(s.grace_until) AS grace_until_date,
    DATE(s.hold_until) AS hold_until_date,
    DATE(s.free_trial_start_date) AS free_trial_start_date,
    DATE(s.free_trial_end_date) AS free_trial_end_date,

    CASE
      WHEN s.status = 'ON_HOLD'  THEN COALESCE(DATE(s.hold_until),  DATE(s.valid_until))
      WHEN s.status = 'IN_GRACE' THEN COALESCE(DATE(s.grace_until), DATE(s.valid_until))
      ELSE DATE(s.valid_until)
    END AS active_end_date,

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

/* =====================================================
   2) FIRST REAL PAID EVENT
   - first row where actual amount > 0
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
  FROM subs_converted s
  WHERE s.actual_amount_gross_tl > 0
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
promo_before_first_paid AS (
  SELECT
    cu.user_id,
    ap.promotionId AS promotion_id,
    ap.name AS applied_promo_name,
    ap.type AS applied_promo_type,
    ap.isActive AS applied_promo_is_active,
    DATE(ap.applyDate) AS promo_apply_date,
    DATE(ap.leaveDate) AS promo_leave_date,
    ROW_NUMBER() OVER (
      PARTITION BY cu.user_id
      ORDER BY COALESCE(ap.applyDate, sb.created_at) ASC, sb.created_at ASC
    ) AS rn
  FROM cohort_users cu
  JOIN subs_converted sb
    ON cu.user_id = sb.user_id
   AND sb.created_date <= cu.first_paid_date
  CROSS JOIN UNNEST(sb.applied_promotions) ap
  WHERE ap.promotionId IS NOT NULL
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
   6) DAILY ACTIVE REVENUE AFTER FIRST PAID DATE
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

    sb.payment_option,
    sb.created_at,
    sb.inserted_date,

    SAFE_DIVIDE(
      sb.actual_amount_gross_tl
      * ((1.0 - COALESCE(cfg.commission_rate, 0.00)) * (1.0 - COALESCE(cfg.tax_rate, 0.20))),
      EXTRACT(DAY FROM LAST_DAY(d))
    ) AS actual_net_rev_tl_day,

    SAFE_DIVIDE(
      sb.before_promo_amount_gross_tl
      * ((1.0 - COALESCE(cfg.commission_rate, 0.00)) * (1.0 - COALESCE(cfg.tax_rate, 0.20))),
      EXTRACT(DAY FROM LAST_DAY(d))
    ) AS gross_net_rev_before_promo_tl_day
  FROM subs_converted sb
  JOIN cohort_labeled cl
    ON sb.user_id = cl.user_id
   AND sb.actual_amount_gross_tl IS NOT NULL
  LEFT JOIN payment_option_config cfg
    ON sb.payment_option = cfg.payment_option
  CROSS JOIN params p
  CROSS JOIN UNNEST(
    GENERATE_DATE_ARRAY(
      GREATEST(sb.created_date, cl.first_paid_date),
      LEAST(COALESCE(sb.active_end_date, sb.created_date), p.ds_end)
    )
  ) AS d
  WHERE COALESCE(sb.active_end_date, sb.created_date) >= cl.first_paid_date
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
    payment_option,
    actual_net_rev_tl_day,
    gross_net_rev_before_promo_tl_day
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
   7) USER-MONTH ACTIVITY / REVENUE
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
    1 AS active_flag,
    SUM(actual_net_rev_tl_day) AS actual_net_revenue_tl,
    SUM(gross_net_rev_before_promo_tl_day) AS gross_net_revenue_before_promo_tl
  FROM daily_active_dedup
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
    COALESCE(a.actual_net_revenue_tl, 0) AS actual_net_revenue_tl,
    COALESCE(a.gross_net_revenue_before_promo_tl, 0) AS gross_net_revenue_before_promo_tl
  FROM user_month_spine s
  LEFT JOIN user_month_activity a
    ON s.user_id = a.user_id
   AND s.activity_month = a.activity_month
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
)

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
  campaign_end_lifetime_month,

  activity_month,
  lifetime_month,
  active_flag,

  actual_net_revenue_tl,
  gross_net_revenue_before_promo_tl,

  cum_actual_ltv_tl,
  cum_gross_ltv_before_promo_tl,

  total_spend_tl,
  acquired_users,
  cac_tl,

  ltv_cac_ratio_actual,
  ltv_cac_ratio_gross_before_promo
FROM final_joined
ORDER BY cohort_month, cohort_type, promotion_name, user_id, lifetime_month;