WITH
BaseData as 
(
    SELECT * FROM
        (
            SELECT
                *,
                ROW_NUMBER() OVER(PARTITION BY user_id ORDER BY created_at DESC) AS rownum
            FROM "gain-dwh-prod"."int_transaction"."subs_payment" 
        )
            WHERE rownum = 1
)
    SELECT
       user_id,
       status,
       created_at,
       registered_at
    FROM BaseData