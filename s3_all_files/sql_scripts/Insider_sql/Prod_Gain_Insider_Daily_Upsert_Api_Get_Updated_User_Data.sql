SELECT
    uuid,
    email_address,
    subscription,
    cancel_request_date,
    free_trial,
    churn_date,
    signup_date,
    isEmailPermitted
FROM `microgain-9f959.insider.insider_upsert_api_daily`
WHERE DATE(etl_date) = DATE('{{ ds }}')
