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
),
TotalPaidUsers as 
(
    SELECT
        CURRENT_DATE - 1 AS Date,
        user_id TotalPaidUserCount
        --count(DISTINCT user_id) TotalPaidUserCount
    FROM BaseData
    where DATE(valid_until) >= CURRENT_DATE - 1
    and status = 'ACTIVE'
    and subscription_plan_id is not null
),
PvtData as 
(
SELECT 
    date, 
    'Toplam Ücretli Abonelik' AS Title, 
    4 as rownum,
    totalpaidusercount AS useruuid
FROM TotalPaidUsers
)
    SELECT * FROM pvtdata order by rownum  