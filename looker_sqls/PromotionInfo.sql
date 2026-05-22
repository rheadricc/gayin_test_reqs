WITH paid_by_option AS (
  SELECT
    ap.promotionId AS promotionId,
    s.payment_option AS payment_option,
    COUNT(DISTINCT s.user_id) AS users_paid_1_month
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment` s
  CROSS JOIN UNNEST(s.applied_promotions) ap
  WHERE ap.promotionId IS NOT NULL
    AND s.free_trial_end_date IS NOT NULL
    AND s.amount > 101
    AND s.valid_until >= TIMESTAMP_ADD(s.free_trial_end_date, INTERVAL 30 DAY)
    AND s.payment_option IS NOT NULL
  GROUP BY ap.promotionId, s.payment_option
)

SELECT
  p.promotionId AS promotionId,
  COALESCE(p.name, p.promotionDescription) AS promotion_name,
  p.type AS promotionType,

  CASE WHEN p.isActive = TRUE THEN 'Aktif' ELSE 'Pasif' END AS isActive,

  p.codeCount  AS uretilen_kod_sayisi,
  p.usageCount AS kullanilan_kod_sayisi,

  po.payment_option AS payment_option,
  COALESCE(po.users_paid_1_month, 0) AS min_1_ay_odeme_yapan

FROM `microgain-9f959.Backoffice_metadata.bo_promotions` p
LEFT JOIN paid_by_option po
  ON p.promotionId = po.promotionId

WHERE UPPER(p.type) IN ('MASS','UNIQUE','USER_GROUP','PREPAID')

-- payment_option NULL olan satırlar (yani hiç ödeme yok) kalsın istemiyorsan:
-- AND po.payment_option IS NOT NULL

ORDER BY min_1_ay_odeme_yapan DESC, kullanilan_kod_sayisi DESC;