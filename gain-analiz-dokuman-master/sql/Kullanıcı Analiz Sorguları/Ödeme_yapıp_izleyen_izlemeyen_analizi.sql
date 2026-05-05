
-- Ödeme_yapıp_izleyen/izlemeyen_analizi
WITH 
-- 1️⃣ BaseData: Eski kullanıcı ve abonelik bilgilerini alıyoruz
BaseData AS (
    SELECT
        status,  -- Kullanıcının abonelik durumu
        subscription_plan_id,  -- Abonelik planı
        valid_until,  -- Abonelik geçerlilik tarihi
        user_id,  -- Kullanıcı ID
        email,  -- Kullanıcı e-posta
        registered_at,  -- Kayıt tarihi
        created_at,  -- Hesap oluşturulma tarihi
        grace_until,  -- Ödeme gecikme tolerans tarihi
        free_trial_start_date,  -- Ücretsiz deneme başlangıç tarihi
        free_trial_end_date,  -- Ücretsiz deneme bitiş tarihi
        REPLACE(applied_promotions,'[]',null) AS applied_promotions  -- Uygulanan promosyonlar (boşsa null)
    FROM `test_dataset.elastic_user`
    WHERE DATE(created_at) <= '2025-02-03'
),
-- 2️⃣ UpdateData: Güncel ödeme ve promosyon bilgilerini alıyoruz
UpdateData AS (
    SELECT *
    FROM (
        SELECT
            status,
            subscription_plan_id,
            valid_until,
            user_id,
            email,
            registered_at,
            created_at,
            grace_until,
            free_trial_start_date,
            free_trial_end_date,
            ap.promotionid AS PromotionID,  -- Promosyon ID
            ap.applyDate AS PromotionApplyDate,  -- Promosyon uygulama tarihi
            ap.name AS PromotionName,
            ap.code AS PromotionCode,
            ap.type AS PromotionType,
            benefits.freePremiumByDay AS freePremiumByDay,  -- Günlük premium hakkı
            benefits.freePremiumByMonth AS freePremiumByMonth,  -- Aylık premium hakkı
            benefits.isFreePremium AS isFreePremium,  -- Premium hakkı var mı
            ROW_NUMBER() OVER(PARTITION BY user_id ORDER BY created_at DESC) AS rownum -- En güncel kayıt
        FROM `aws_s3_to_bq_migration.subs_payment`
        LEFT JOIN UNNEST(applied_promotions) ap
        LEFT JOIN UNNEST(ap.benefits) benefits
        WHERE DATE(created_at) >= '2025-02-03'
          AND DATE(created_at) <= CURRENT_DATE("Europe/Istanbul") - 1
    )
),
-- 3️⃣ ReportData: Eski ve güncel verileri birleştirip en güncel bilgiyi seçiyoruz
ReportData AS (
    SELECT
        CASE
            WHEN bd.created_at > ud.created_at THEN bd.status
            WHEN ud.created_at IS NULL THEN bd.status
            ELSE ud.status
        END status,
        IFNULL(bd.subscription_plan_id, ud.subscription_plan_id) AS subscription_plan_id,
        CASE
            WHEN bd.created_at > ud.created_at THEN bd.valid_until
            WHEN ud.created_at IS NULL THEN bd.valid_until
            ELSE ud.valid_until
        END valid_until,
        CASE
            WHEN bd.created_at > ud.created_at THEN bd.user_id
            WHEN ud.created_at IS NULL THEN bd.user_id
            ELSE ud.user_id
        END user_id,
        CASE
            WHEN bd.created_at > ud.created_at THEN bd.email
            WHEN ud.created_at IS NULL THEN bd.email
            ELSE ud.email
        END email,
        CASE
            WHEN bd.created_at > ud.created_at THEN bd.registered_at
            WHEN ud.created_at IS NULL THEN bd.registered_at
            ELSE ud.registered_at
        END registered_at,
        CASE
            WHEN bd.created_at > ud.created_at THEN bd.created_at
            WHEN ud.created_at IS NULL THEN bd.created_at
            ELSE ud.created_at
        END created_at,
        CASE
            WHEN bd.created_at > ud.created_at THEN bd.grace_until
            WHEN ud.created_at IS NULL THEN bd.grace_until
            ELSE ud.grace_until
        END grace_until,
        CASE
            WHEN bd.created_at > ud.created_at THEN bd.free_trial_start_date
            WHEN ud.created_at IS NULL THEN bd.free_trial_start_date
            ELSE ud.free_trial_start_date
        END free_trial_start_date,
        CASE
            WHEN bd.created_at > ud.created_at THEN bd.free_trial_end_date
            WHEN ud.created_at IS NULL THEN bd.free_trial_end_date
            ELSE ud.free_trial_end_date
        END free_trial_end_date,
        CASE
            WHEN bd.created_at > ud.created_at THEN bd.applied_promotions
            WHEN ud.created_at IS NULL THEN bd.applied_promotions
            ELSE ud.PromotionID
        END applied_promotions,
        PromotionApplyDate,
        freePremiumByDay,
        PromotionID
    FROM BaseData bd
    FULL JOIN UpdateData ud ON bd.user_id = ud.user_id
),
-- 4️⃣ allusers: Aktif aboneleri ve ödeme yaptıkları ayı alıyoruz
allusers AS (
    SELECT DISTINCT 
        user_id, 
        DATE_TRUNC(DATE(created_at), MONTH) AS paiddate
    FROM ReportData
    WHERE status = 'ACTIVE'
),
-- 5️⃣ eskipayment: Eski ödeme kayıtlarını alıyoruz
eskipayment AS (
    SELECT 
        useruuid AS user_id,
        DATE_TRUNC(DATE(createdat), MONTH) AS eskipaymentdate
    FROM `datamarts.transaction_v2`
),
-- 6️⃣ allusersv2: Yeni ve eski ödeme kayıtlarını birleştiriyoruz
allusersv2 AS (
    SELECT * FROM allusers
    UNION ALL
    SELECT * FROM eskipayment
),
-- 7️⃣ izleyen: Kullanıcıların izlediği içerik kayıtları
izleyen AS (
    SELECT DISTINCT 
        user_id,
        video_id,
        DATE_TRUNC(event_date, MONTH) AS watchdate
    FROM `looker_report.content_report_streaming_V2`
    WHERE event_date >= '2024-01-01'
),
-- 8️⃣ lasttab: Ödeme yapan kullanıcıların aynı ay içinde içerik izleyip izlemediğini kontrol ediyoruz
lasttab AS (
    SELECT 
        a.user_id AS auser,
        b.user_id AS buser,
        a.paiddate,
        b.watchdate
    FROM allusersv2 a 
    LEFT JOIN izleyen b 
        ON a.user_id = b.user_id AND a.paiddate = b.watchdate
),
-- 9️⃣ odemeyapanizlemeyen: Ödeme yapıp izlemeyen kullanıcı sayısı
odemeyapanizlemeyen AS (
    SELECT 
        paiddate,
        COUNT(DISTINCT auser) AS cnt
    FROM lasttab
    WHERE buser IS NULL
      AND paiddate >= '2024-01-01'
    GROUP BY 1
),
-- 10️⃣ odemeyapanizleyen: Ödeme yapıp izleyen kullanıcı sayısı
odemeyapanizleyen AS (
    SELECT 
        paiddate,
        COUNT(DISTINCT auser) AS cnt
    FROM lasttab
    WHERE buser IS NOT NULL
      AND paiddate >= '2024-01-01'
    GROUP BY 1
),
-- 11️⃣ watchperperson: Kullanıcı başına ortalama izlenen video sayısı
watchperperson AS (
    SELECT
        watchdate,
        ROUND(COUNT(video_id) / COUNT(DISTINCT user_id), 2) AS avgwatchcnt
    FROM izleyen
    GROUP BY 1
)
-- 12️⃣ Ana çıktı: Ay bazında izleyen, izlemeyen ve ortalama izleme sayısı
SELECT 
    a.paiddate AS izleyendate,
    a.cnt AS izleyen,
    b.cnt AS izlemeyen,
    w.avgwatchcnt
FROM odemeyapanizleyen a
FULL JOIN odemeyapanizlemeyen b ON a.paiddate = b.paiddate
FULL JOIN watchperperson w ON a.paiddate = w.watchdate
ORDER BY 1 DESC;
