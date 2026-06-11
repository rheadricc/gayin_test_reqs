-- MASTER QUERY v2 | 2025 | Excel-friendly | corrected logic
WITH params AS (
  SELECT
    DATE '2025-01-01' AS ds_start,
    DATE '2025-12-31' AS ds_end
),

month_spine AS (
  SELECT month_start
  FROM params,
  UNNEST(GENERATE_DATE_ARRAY(ds_start, ds_end, INTERVAL 1 MONTH)) AS month_start
),

/* -------------------------------------------------
   1) REGISTERED
------------------------------------------------- */
registered_base AS (
  SELECT
    user_id,
    DATE(registered_at) AS registered_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE user_id IS NOT NULL
    AND registered_at IS NOT NULL
),

registered_monthly AS (
  SELECT
    DATE_TRUNC(registered_date, MONTH) AS month_start,
    COUNT(DISTINCT user_id) AS monthly_registered_users
  FROM registered_base
  WHERE registered_date BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
  GROUP BY 1
),

registered_final AS (
  SELECT
    m.month_start,
    COALESCE(r.monthly_registered_users, 0) AS monthly_registered_users,
    SUM(COALESCE(r.monthly_registered_users, 0)) OVER (ORDER BY m.month_start) AS cumulative_registered_users
  FROM month_spine m
  LEFT JOIN registered_monthly r
    ON m.month_start = r.month_start
),

/* -------------------------------------------------
   2) PAID EVENTS
   real payment date = valid_until - 30 days
------------------------------------------------- */
paid_events AS (
  SELECT
    user_id,
    DATE_SUB(DATE(valid_until), INTERVAL 30 DAY) AS payment_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE user_id IS NOT NULL
    AND amount > 101
    AND payment_option IS NOT NULL
    AND payment_option != 'PREPAID'
    AND valid_until IS NOT NULL
),

paid_monthly AS (
  SELECT
    DATE_TRUNC(payment_date, MONTH) AS month_start,
    COUNT(DISTINCT user_id) AS monthly_paid_users
  FROM paid_events
  WHERE payment_date BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
  GROUP BY 1
),

first_paid_event AS (
  SELECT
    user_id,
    payment_date AS first_payment_date
  FROM (
    SELECT
      user_id,
      payment_date,
      ROW_NUMBER() OVER (
        PARTITION BY user_id
        ORDER BY payment_date ASC
      ) AS rn
    FROM paid_events
  )
  WHERE rn = 1
),

first_paid_monthly AS (
  SELECT
    DATE_TRUNC(first_payment_date, MONTH) AS month_start,
    COUNT(DISTINCT user_id) AS monthly_first_time_paid_users
  FROM first_paid_event
  WHERE first_payment_date BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
  GROUP BY 1
),

paid_final AS (
  SELECT
    m.month_start,
    COALESCE(p.monthly_paid_users, 0) AS monthly_paid_users,
    COALESCE(f.monthly_first_time_paid_users, 0) AS monthly_first_time_paid_users,
    SUM(COALESCE(f.monthly_first_time_paid_users, 0)) OVER (ORDER BY m.month_start) AS cumulative_first_time_paid_users
  FROM month_spine m
  LEFT JOIN paid_monthly p
    ON m.month_start = p.month_start
  LEFT JOIN first_paid_monthly f
    ON m.month_start = f.month_start
),

/* -------------------------------------------------
   3) STREAMING BASE
   two layers:
   - raw rows for watch time
   - consumption rows for viewer/view logic
------------------------------------------------- */
stream_raw AS (
  SELECT
    event_date,
    user_id,
    video_id,
    ga_session_id,
    COALESCE(watch_time_second, 0) AS watch_time_second
  FROM `microgain-9f959.looker_report.content_report_streaming_V2`
  WHERE event_date BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
    AND user_id IS NOT NULL
),

stream_consumption AS (
  SELECT *
  FROM stream_raw
  WHERE watch_time_second > 0
),

/* -------------------------------------------------
   4) MONTHLY VIEWS
   use positive-consumption rows only
------------------------------------------------- */
views_monthly AS (
  SELECT
    DATE_TRUNC(event_date, MONTH) AS month_start,
    COUNT(DISTINCT user_id) AS monthly_unique_viewers,
    COUNT(DISTINCT CONCAT(
      CAST(user_id AS STRING), '-',
      CAST(video_id AS STRING), '-',
      CAST(ga_session_id AS STRING)
    )) AS monthly_total_views
  FROM stream_consumption
  GROUP BY 1
),

/* -------------------------------------------------
   5) WATCH TIME
------------------------------------------------- */
watch_daily AS (
  SELECT
    event_date,
    COUNT(DISTINCT user_id) AS daily_unique_viewers,
    SUM(watch_time_second) / 60.0 AS daily_total_watch_time_minutes
  FROM stream_consumption
  GROUP BY 1
),

watch_monthly AS (
  SELECT
    DATE_TRUNC(event_date, MONTH) AS month_start,
    SUM(daily_total_watch_time_minutes) AS monthly_total_watch_time_minutes,
    AVG(daily_unique_viewers) AS avg_daily_unique_viewers,
    AVG(SAFE_DIVIDE(daily_total_watch_time_minutes, daily_unique_viewers)) AS avg_daily_watch_time_per_viewer_minutes
  FROM watch_daily
  GROUP BY 1
),

/* -------------------------------------------------
   6) DAILY ACTIVE VIEWERS
   active = same day watch time >= 300 sec
------------------------------------------------- */
user_day_watch AS (
  SELECT
    event_date,
    user_id,
    SUM(watch_time_second) AS user_day_watch_time_second
  FROM stream_consumption
  GROUP BY 1,2
),

daily_active_viewers AS (
  SELECT
    event_date,
    user_id
  FROM user_day_watch
  WHERE user_day_watch_time_second >= 300
),

active_monthly_all AS (
  SELECT
    DATE_TRUNC(event_date, MONTH) AS month_start,
    COUNT(DISTINCT user_id) AS total_active_viewers_all
  FROM daily_active_viewers
  GROUP BY 1
),

/* -------------------------------------------------
   7) SUBSCRIPTION WINDOWS
   build daily subscriber windows more carefully
------------------------------------------------- */
subs_base AS (
  SELECT
    s.user_id,
    s.status,
    s.payment_option,
    DATE(s.created_at) AS created_date,
    DATE(s.valid_until) AS valid_until_date,
    DATE(s.grace_until) AS grace_until_date,
    DATE(s.hold_until) AS hold_until_date,
    DATE(s.free_trial_start_date) AS trial_start_date,
    DATE(s.free_trial_end_date) AS trial_end_date,
    CAST(COALESCE(s.amount, s.amount_before_promotions, 0) AS FLOAT64) AS amount_minor,
    DATE_SUB(DATE(s.valid_until), INTERVAL 30 DAY) AS derived_payment_date,
    CASE
      WHEN s.status = 'ON_HOLD'  THEN COALESCE(DATE(s.hold_until), DATE(s.valid_until))
      WHEN s.status = 'IN_GRACE' THEN COALESCE(DATE(s.grace_until), DATE(s.valid_until))
      ELSE DATE(s.valid_until)
    END AS active_end_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  WHERE s.user_id IS NOT NULL
    AND s.valid_until IS NOT NULL
    AND s.status IN ('ACTIVE', 'CANCELED', 'IN_GRACE', 'ON_HOLD', 'EXPIRED')
),

trial_user_days AS (
  SELECT DISTINCT
    d AS event_date,
    s.user_id
  FROM subs_base s,
  UNNEST(GENERATE_DATE_ARRAY(s.trial_start_date, s.trial_end_date)) AS d
  WHERE s.trial_start_date IS NOT NULL
    AND s.trial_end_date IS NOT NULL
    AND d BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
),

paid_user_days AS (
  SELECT DISTINCT
    d AS event_date,
    s.user_id
  FROM subs_base s,
  UNNEST(GENERATE_DATE_ARRAY(s.derived_payment_date, s.active_end_date)) AS d
  WHERE s.payment_option IS NOT NULL
    AND s.payment_option != 'PREPAID'
    AND s.amount_minor > 101
    AND s.derived_payment_date IS NOT NULL
    AND s.active_end_date IS NOT NULL
    AND s.derived_payment_date <= s.active_end_date
    AND d BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
),

paid_user_days_net AS (
  SELECT p.event_date, p.user_id
  FROM paid_user_days p
  LEFT JOIN trial_user_days t
    ON p.event_date = t.event_date
   AND p.user_id = t.user_id
  WHERE t.user_id IS NULL
),

/* -------------------------------------------------
   8) ACTIVE SUBSCRIBER CLASSIFICATION
------------------------------------------------- */
trial_active_user_days AS (
  SELECT DISTINCT
    a.event_date,
    a.user_id
  FROM daily_active_viewers a
  JOIN trial_user_days t
    ON a.event_date = t.event_date
   AND a.user_id = t.user_id
),

paid_active_user_days AS (
  SELECT DISTINCT
    a.event_date,
    a.user_id
  FROM daily_active_viewers a
  JOIN paid_user_days_net p
    ON a.event_date = p.event_date
   AND a.user_id = p.user_id
),

subscriber_active_user_days AS (
  SELECT event_date, user_id FROM trial_active_user_days
  UNION DISTINCT
  SELECT event_date, user_id FROM paid_active_user_days
),

active_monthly_subscribers AS (
  SELECT
    DATE_TRUNC(event_date, MONTH) AS month_start,
    COUNT(DISTINCT user_id) AS total_active_subscriber_viewers
  FROM subscriber_active_user_days
  GROUP BY 1
),

active_monthly_paid AS (
  SELECT
    DATE_TRUNC(event_date, MONTH) AS month_start,
    COUNT(DISTINCT user_id) AS paid_active_viewers
  FROM paid_active_user_days
  GROUP BY 1
),

active_monthly_trial AS (
  SELECT
    DATE_TRUNC(event_date, MONTH) AS month_start,
    COUNT(DISTINCT user_id) AS trial_active_viewers
  FROM trial_active_user_days
  GROUP BY 1
),

/* -------------------------------------------------
   9) FINAL
------------------------------------------------- */
final AS (
  SELECT
    m.month_start AS month,

    COALESCE(r.monthly_registered_users, 0) AS monthly_registered_users,
    COALESCE(r.cumulative_registered_users, 0) AS cumulative_registered_users,

    COALESCE(p.monthly_paid_users, 0) AS monthly_paid_users,
    COALESCE(p.monthly_first_time_paid_users, 0) AS monthly_first_time_paid_users,
    COALESCE(p.cumulative_first_time_paid_users, 0) AS cumulative_first_time_paid_users,

    COALESCE(a_all.total_active_viewers_all, 0) AS total_active_viewers_all,
    COALESCE(a_sub.total_active_subscriber_viewers, 0) AS total_active_subscriber_viewers,
    COALESCE(a_paid.paid_active_viewers, 0) AS paid_active_viewers,
    COALESCE(a_trial.trial_active_viewers, 0) AS trial_active_viewers,

    COALESCE(v.monthly_unique_viewers, 0) AS monthly_unique_viewers,
    COALESCE(v.monthly_total_views, 0) AS monthly_total_views,
    SAFE_DIVIDE(
      COALESCE(v.monthly_total_views, 0),
      NULLIF(COALESCE(v.monthly_unique_viewers, 0), 0)
    ) AS views_per_unique_viewer,

    COALESCE(w.monthly_total_watch_time_minutes, 0) AS monthly_total_watch_time_minutes,
    COALESCE(w.avg_daily_unique_viewers, 0) AS avg_daily_unique_viewers,
    COALESCE(w.avg_daily_watch_time_per_viewer_minutes, 0) AS avg_daily_watch_time_per_viewer_minutes

  FROM month_spine m
  LEFT JOIN registered_final r
    ON m.month_start = r.month_start
  LEFT JOIN paid_final p
    ON m.month_start = p.month_start
  LEFT JOIN active_monthly_all a_all
    ON m.month_start = a_all.month_start
  LEFT JOIN active_monthly_subscribers a_sub
    ON m.month_start = a_sub.month_start
  LEFT JOIN active_monthly_paid a_paid
    ON m.month_start = a_paid.month_start
  LEFT JOIN active_monthly_trial a_trial
    ON m.month_start = a_trial.month_start
  LEFT JOIN views_monthly v
    ON m.month_start = v.month_start
  LEFT JOIN watch_monthly w
    ON m.month_start = w.month_start
)

SELECT *
FROM final
ORDER BY month;