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
select distinct user_id from basedata where status = 'ACTIVE'