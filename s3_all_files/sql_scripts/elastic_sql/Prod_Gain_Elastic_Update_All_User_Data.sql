UPDATE `microgain-9f959.gain_model_prod.prod_dim_user_partial_scd`
SET is_current = FALSE,
    effective_end = CURRENT_TIMESTAMP()
WHERE is_current = TRUE
  AND userId IN (
    SELECT DISTINCT userId
    FROM `microgain-9f959.gain_model_prod.prod_user_dim_scd2_stage`
  );
