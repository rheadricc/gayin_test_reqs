# Agent Log — CAC / LTV BigQuery Standardizasyonu

**Tarih:** 2026-05-22  
**Konu:** Looker Studio üzerinde kullanılan CAC, LTV ve LTV/CAC metriklerini aynı mantıkta çalışacak şekilde inceleme, hata tespiti, SQL revizyonu ve dashboard kullanım notları.  
**Amaç:** Bu dosya, başka bir ChatGPT sohbetine, başka bir AI agent'a veya ekipten bir kişiye verildiğinde, bu konuşmada yapılan işi hiçbir ek bağlam gerektirmeden anlatabilsin.

---

## 1. Kısa Özet

Bu çalışmada GAİN BigQuery / Looker Studio tarafında kullanılan CAC, LTV ve LTV/CAC sorguları incelendi. Ana problem, özellikle Meta harcaması olmasına rağmen Meta için `new_paid_users = 0`, `cac_tl = NULL` veya Looker grafiğinde Meta'nın yok gibi görünmesiydi.

İlk başta bunun basit bir channel mapping problemi olabileceği düşünüldü. Ancak debug sorguları sonrasında asıl problemin birkaç katmandan oluştuğu görüldü:

1. **Attribution channel mismatch:** Spend tarafındaki `channel` ile GA4 attribution tarafındaki `mapped_channel`, `source`, `medium`, `campaign` alanları aynı normalize edilmediği için bazı join'ler kaçabiliyordu.
2. **`ga4_first_non_direct_touch` tablosunun modeli:** Kullanılan attribution tablosu ismi itibarıyla first-touch mantığına yakın duruyor. CAC için istenen şey ise ödeme öncesi son 30 gündeki uygun paid touch üzerinden kullanıcıyı kanala yazmak.
3. **Meta touch ≠ Meta kaynaklı yeni paid user:** Mayıs 2026 debug'ında Meta/IG touch kayıtları vardı ama bunların bazıları ödeme yapmamıştı, bazıları ise ödeme yaptıktan sonra Meta touch almıştı. Bu nedenle acquisition CAC denominator'ına girmemeleri doğruydu.
4. **Looker null davranışı:** Spend var ama attributed user yoksa `cac_tl` bilinçli olarak `NULL` bırakıldı. Looker bar chart `NULL` değerleri çizmediği için Meta yokmuş gibi görünüyordu.
5. **Sorgular arası metodoloji farkları:** Bazı sorgular eski `manual_monthly_spend` tablosunu kullanıyor veya LTV hesaplarını farklı basis'lerde yapıyordu. Bunlar standart hale getirildi ya da header notlarıyla açıklandı.

Sonuç olarak standart CAC mantığı aşağıdaki şekilde belirlendi:

```text
CAC = spend_tl / attributed_first_paid_users
```

Buradaki `attributed_first_paid_users` tanımı:

```text
TRY-only, PREPAID hariç, ilk kez ücretli olmuş kullanıcılar içinden,
ilk ödeme tarihinden önceki son 30 gün içinde uygun paid/non-direct touch alanlar.
Her kullanıcı yalnızca 1 kanala yazılır: ödeme öncesindeki en son uygun touch kanalına.
```

---

## 2. İncelenen / Revize Edilen Dosyalar

Konuşmada aşağıdaki SQL dosyaları incelendi:

1. `BC_CAC_MONTHLY_01(2).sql`
2. `BC_REALIZED_LTV_MONTHLY_01(2).sql`
3. `BC_FORECAST_LTV_MONTHLY_01(2).sql`
4. `BC_LTVCAC_REALIZED_MONTHLY_01(2).sql`
5. `BC_CHANNEL_LTVCAC_REALIZED_01(2).sql`
6. `BC_CATEGORY_LTV_02(2).sql`
7. `BC_WATCHER_LTV_02(2).sql`

Bunlar için revize / reviewed versiyonlar üretildi:

1. `BC_CAC_MONTHLY_01_REVISED.sql`
2. `BC_REALIZED_LTV_MONTHLY_01_REVIEWED.sql`
3. `BC_FORECAST_LTV_MONTHLY_01_REVIEWED.sql`
4. `BC_LTVCAC_REALIZED_MONTHLY_01_REVISED.sql`
5. `BC_CHANNEL_LTVCAC_REALIZED_01_REVISED.sql`
6. `BC_CATEGORY_LTV_02_REVIEWED.sql`
7. `BC_WATCHER_LTV_02_REVIEWED.sql`
8. `CAC_LTV_REVIEW_NOTES.txt`

Ayrıca `BC_CHANNEL_LTVCAC_REALIZED_01_REVISED.sql` içinde sonradan küçük bir alias hatası yakalandı ve manuel patch önerildi. Detayı aşağıda var.

---

## 3. Kullanılan Ana Tablolar

### 3.1 Spend source

Standart spend kaynağı olarak aşağıdaki tablo kullanılmalı:

```sql
`microgain-9f959.bc_marketing_marts.ads_daily_spend`
```

Bu çalışma sonrası CAC / LTV-CAC hesaplarında eski manual spend tablosu kullanılmamalı:

```sql
`microgain-9f959.bc_marketing_raw.manual_monthly_spend`
```

Manual tablo tarihsel sebeplerle kullanılmış olabilir ancak yeni standartta dashboard metriklerinin aynı şeyi göstermesi için `bc_marketing_marts.ads_daily_spend` esas alınmalı.

### 3.2 Payment source

Kullanılan ana ödeme tablosu:

```sql
`microgain-9f959.aws_s3_to_bq_migration.subs_payment`
```

Standart filtreler:

```sql
user_id IS NOT NULL
payment_option IS NOT NULL
UPPER(TRIM(payment_option)) != 'PREPAID'
COALESCE(amount, amount_before_promotions, 0) > 0
UPPER(TRIM(currency)) = 'TRY'
```

İlk paid date:

```sql
MIN(DATE(created_at)) AS first_paid_date
```

Bu alan acquisition cohort için kullanıldı.

### 3.3 Attribution source

Kullanılan attribution tablosu:

```sql
`microgain-9f959.bc_marketing_raw.ga4_first_non_direct_touch`
```

Bu tablo üzerinde `user_id`, `touch_date`, `source`, `medium`, `campaign`, `mapped_channel` alanları kullanıldı.

Önemli sınırlama: Tablo adı `first_non_direct_touch` olduğu için, bu tablo gerçek raw event/touch datası değilse gerçek anlamda last-touch attribution üretmek mümkün olmayabilir. Mevcut implementasyon bu tablo içindeki kayıtlar üzerinden “ödeme öncesi son 30 gündeki en son uygun touch” seçimini yapar. Bu nedenle bu model **available-data best effort** kabul edilmeli.

---

## 4. Ana Problem: Meta Harcaması Var Ama CAC NULL / Kullanıcı 0

Başlangıçta `BC_CAC_MONTHLY_01` çıktısında Mayıs 2026 için şu tarz sonuç görüldü:

```text
channel = google
spend_tl ≈ 94,093
new_paid_users = 1051
cac_tl ≈ 89.5

channel = meta
spend_tl ≈ 67,408
new_paid_users = 0
cac_tl = NULL

all_channels
spend_tl ≈ 161,502
new_paid_users = 1051
cac_tl ≈ 153.5
```

İlk bakışta Meta'dan hiç kullanıcı gelmemiş gibi duruyordu. Ancak GA4 attribution tablosu incelendiğinde Mayıs ayında Meta/IG/Tiktok touch kayıtları olduğu görüldü.

Örnek source dağılımı sorgusu:

```sql
SELECT
  LOWER(TRIM(source)) AS source,
  LOWER(TRIM(medium)) AS medium,
  LOWER(TRIM(COALESCE(campaign, 'null'))) AS campaign,
  COUNT(*) AS row_count,
  COUNT(DISTINCT user_id) AS user_count
FROM `microgain-9f959.bc_marketing_raw.ga4_first_non_direct_touch`
WHERE touch_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-21'
GROUP BY 1, 2, 3
ORDER BY user_count DESC;
```

Bu sorguda Google ağırlıklı olmak üzere az sayıda Meta/IG/Tiktok kaydı olduğu görüldü. Ancak bu touch kayıtları CAC denominator'ına otomatik olarak girmemeli; çünkü CAC denominator'ı touch değil, **ilk ücretli kullanıcı**dır.

Daha sonra touch kayıtları payment ile yan yana getirildiğinde şu durum görüldü:

```text
l.instagram.com / ig kullanıcıları: no_paid_record
meta kullanıcıları: paid_before_touch
bazı tiktok kullanıcıları: paid_in_30_day_window
```

Yani Meta için görünen touch kayıtları ya ödeme yapmamış kullanıcılara aitti ya da kullanıcı zaten daha önce ödeme yapmış, sonrasında Meta touch almıştı. Bu yüzden acquisition CAC mantığında Meta'nın `new_paid_users = 0` kalması doğruydu.

---

## 5. Debug Sorguları ve Çıkarımlar

### 5.1 GA4 source / medium / campaign dağılımı

Amaç: İlgili dönemde GA4 attribution tablosunda hangi source değerleri var görmek.

```sql
SELECT
  LOWER(TRIM(source)) AS source,
  LOWER(TRIM(medium)) AS medium,
  LOWER(TRIM(COALESCE(campaign, 'null'))) AS campaign,
  COUNT(*) AS row_count,
  COUNT(DISTINCT user_id) AS user_count
FROM `microgain-9f959.bc_marketing_raw.ga4_first_non_direct_touch`
WHERE touch_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-21'
GROUP BY 1, 2, 3
ORDER BY user_count DESC;
```

Çıkarım: Mayıs 2026'da Google baskın. Meta/IG/Tiktok kayıtları var ama çok az.

### 5.2 Touch kayıtlarını first paid ile sınıflandırma

Amaç: Meta/IG/Tiktok touch alan kullanıcıların ödeme durumunu görmek.

```sql
WITH touches AS (
  SELECT
    user_id,
    touch_date,
    source,
    medium,
    campaign,
    mapped_channel
  FROM `microgain-9f959.bc_marketing_raw.ga4_first_non_direct_touch`
  WHERE LOWER(source) IN (
    'ig',
    'l.instagram.com',
    'meta',
    'tiktok',
    'facebook',
    'instagram',
    'm.facebook.com',
    'l.facebook.com'
  )
    AND touch_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-21'
),

first_paid AS (
  SELECT
    user_id,
    MIN(DATE(created_at)) AS first_paid_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE user_id IS NOT NULL
    AND payment_option IS NOT NULL
    AND payment_option != 'PREPAID'
    AND amount > 0
    AND UPPER(currency) = 'TRY'
  GROUP BY user_id
)

SELECT
  t.user_id,
  t.touch_date,
  t.source,
  t.medium,
  t.campaign,
  t.mapped_channel,
  fp.first_paid_date,
  DATE_DIFF(fp.first_paid_date, t.touch_date, DAY) AS day_diff,
  CASE
    WHEN fp.user_id IS NULL THEN 'no_paid_record'
    WHEN DATE_DIFF(fp.first_paid_date, t.touch_date, DAY) BETWEEN 0 AND 30 THEN 'paid_in_30_day_window'
    WHEN fp.first_paid_date < t.touch_date THEN 'paid_before_touch'
    ELSE 'paid_after_30_day_window'
  END AS attribution_status
FROM touches t
LEFT JOIN first_paid fp
  ON t.user_id = fp.user_id
ORDER BY t.touch_date, t.source, t.user_id;
```

Çıkarım: Meta/IG tarafında görülen kayıtlar acquisition conversion üretmiyordu. Bu nedenle Meta CAC'in `NULL` kalması veri modeline göre doğru.

### 5.3 `mapped_channel` ile channel normalization farkını görmek

Amaç: `mapped_channel` doğrudan kullanılırsa Meta/IG/Facebook varyasyonlarının kaçıp kaçmadığını görmek.

```sql
WITH params AS (
  SELECT
    DATE '2026-05-01' AS ds_start,
    DATE '2026-05-30' AS ds_end
),

first_paid AS (
  SELECT
    user_id,
    MIN(DATE(created_at)) AS first_paid_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE user_id IS NOT NULL
    AND payment_option IS NOT NULL
    AND payment_option != 'PREPAID'
    AND amount > 0
    AND UPPER(currency) = 'TRY'
  GROUP BY user_id
)

SELECT
  LOWER(TRIM(CAST(g.mapped_channel AS STRING))) AS raw_mapped_channel,
  CASE
    WHEN REGEXP_CONTAINS(LOWER(TRIM(CAST(g.mapped_channel AS STRING))), r'google|adwords|gads') THEN 'google'
    WHEN REGEXP_CONTAINS(LOWER(TRIM(CAST(g.mapped_channel AS STRING))), r'meta|facebook|instagram|fb|ig|paid_social|social') THEN 'meta'
    WHEN REGEXP_CONTAINS(LOWER(TRIM(CAST(g.mapped_channel AS STRING))), r'tiktok|tik_tok') THEN 'tiktok'
    ELSE LOWER(TRIM(CAST(g.mapped_channel AS STRING)))
  END AS normalized_channel,
  COUNT(DISTINCT fp.user_id) AS paid_users_with_touch,
  COUNT(DISTINCT IF(
    DATE_DIFF(fp.first_paid_date, g.touch_date, DAY) BETWEEN 0 AND 30,
    fp.user_id,
    NULL
  )) AS paid_users_in_30_day_window,
  MIN(g.touch_date) AS min_touch_date,
  MAX(g.touch_date) AS max_touch_date,
  MIN(DATE_DIFF(fp.first_paid_date, g.touch_date, DAY)) AS min_day_diff,
  MAX(DATE_DIFF(fp.first_paid_date, g.touch_date, DAY)) AS max_day_diff
FROM first_paid fp
JOIN `microgain-9f959.bc_marketing_raw.ga4_first_non_direct_touch` g
  ON fp.user_id = g.user_id
CROSS JOIN params p
WHERE fp.first_paid_date BETWEEN DATE_TRUNC(p.ds_start, MONTH)
                            AND LAST_DAY(DATE_TRUNC(p.ds_end, MONTH))
GROUP BY 1, 2
ORDER BY paid_users_in_30_day_window DESC;
```

Çıkarım: Google'da 30 günlük attribution user sayısı yüksek çıkarken Meta'da 0 göründü. Meta user'ları ya eski first touch'a sahipti ya da ödeme öncesi 30 gün koşulunu sağlamıyordu.

---

## 6. Standardize Edilen CAC Mantığı

### 6.1 Cohort tanımı

CAC denominator sadece ilk kez ücretli olmuş kullanıcıları sayar.

```sql
first_paid AS (
  SELECT
    CAST(user_id AS STRING) AS user_id,
    MIN(DATE(created_at)) AS first_paid_date
  FROM `microgain-9f959.aws_s3_to_bq_migration.subs_payment`
  WHERE user_id IS NOT NULL
    AND payment_option IS NOT NULL
    AND UPPER(TRIM(payment_option)) != 'PREPAID'
    AND COALESCE(amount, amount_before_promotions, 0) > 0
    AND UPPER(TRIM(currency)) = 'TRY'
  GROUP BY user_id
)
```

Not: `amount` yerine `COALESCE(amount, amount_before_promotions, 0)` kullanıldı. Bunun sebebi bazı ödeme kayıtlarında tutarın `amount_before_promotions` üzerinden yakalanabilme ihtimali.

### 6.2 Channel normalization

Spend ve attribution tarafı aynı channel setine normalize edilmeli.

Paid channel standard mapping:

```text
google / adwords / gads / youtube => google
meta / facebook / instagram / fb / ig / l.instagram / m.facebook / l.facebook / paid_social / social => meta
tiktok / tik_tok => tiktok
```

Bazı channel-level LTV/CAC sorgularında ayrıca şu gruplar da desteklendi:

```text
influencer / creator => influencer
affiliate / partner => affiliate
organic / direct / seo / referral / email / push / sms / crm => organic
else => other
```

### 6.3 Attribution mantığı

Standart attribution:

```text
Ödeme tarihinden önceki son 30 gün içinde kalan touch kayıtları içinden
en son touch seçilir.
Her kullanıcı yalnızca 1 kanala yazılır.
```

Tekilleştirme:

```sql
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY fp.user_id
  ORDER BY
    t.touch_date DESC,
    CASE WHEN t.medium IN ('cpc', 'cpa', 'paid', 'paid_social', 'search_cpc') THEN 1 ELSE 0 END DESC,
    t.channel
) = 1
```

İlk sıralama `touch_date DESC`; yani ödeme öncesi en yakın touch kazanır. Aynı tarihte birden fazla touch varsa paid medium öncelenir.

### 6.4 CAC formülü

```sql
SAFE_DIVIDE(spend_tl, new_paid_users) AS cac_tl
```

Önemli karar:

```text
Spend var ama new_paid_users = 0 ise CAC 0'a çekilmez.
CAC NULL bırakılır.
```

Çünkü spend / 0 matematiksel olarak hesaplanamaz. Bunu 0 göstermek iş tarafında yanıltıcı olur.

### 6.5 `cac_status` eklendi

Dashboard'da “Meta yok mu, veri mi gelmedi, yoksa user mı yok?” ayrımını göstermek için `cac_status` alanı eklendi.

```sql
CASE
  WHEN spend_tl > 0 AND new_paid_users > 0 THEN 'ok'
  WHEN spend_tl > 0 AND new_paid_users = 0 THEN 'spend_var_user_yok'
  WHEN spend_tl = 0 AND new_paid_users > 0 THEN 'spend_yok_user_var'
  ELSE 'spend_yok_user_yok'
END AS cac_status
```

Bu alan özellikle Looker chart yorumlaması için kritik.

---

## 7. Standardize Edilen LTV Mantığı

### 7.1 Realized LTV standardı

Genel realized LTV yaklaşımı:

```text
TRY-only, PREPAID hariç, aktif günlere dağıtılmış net revenue.
```

Net revenue hesap mantığı:

```sql
SAFE_DIVIDE(amount_minor, 100.0)
* (1.0 - commission_rate)
* (1.0 - tax_rate)
```

Ardından günlük aktif abonelik günlerine paylaştırma:

```sql
SAFE_DIVIDE(net_monthly_amount_tl, EXTRACT(DAY FROM LAST_DAY(dt))) AS net_rev_tl
```

Kullanılan commission / tax config:

```sql
SELECT 'APP_STORE'       AS payment_option, 0.30 AS commission_rate, 0.20 AS tax_rate UNION ALL
SELECT 'PLAY_STORE'      AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
SELECT 'MOBILE_PAYMENT'  AS payment_option, 0.15 AS commission_rate, 0.20 AS tax_rate UNION ALL
SELECT 'CRAFTGATE'       AS payment_option, 0.00 AS commission_rate, 0.20 AS tax_rate UNION ALL
SELECT 'IYZICO'          AS payment_option, 0.03 AS commission_rate, 0.20 AS tax_rate
```

Aktif subscription status'leri:

```sql
status IN ('ACTIVE', 'IN_GRACE', 'ON_HOLD')
```

Active end date:

```sql
CASE
  WHEN status = 'ON_HOLD'  THEN COALESCE(DATE(hold_until),  DATE(valid_until))
  WHEN status = 'IN_GRACE' THEN COALESCE(DATE(grace_until), DATE(valid_until))
  ELSE DATE(valid_until)
END AS active_end_date
```

Aynı gün / aynı kullanıcı için birden fazla aktif kayıt varsa son kayıt seçiliyor:

```sql
ROW_NUMBER() OVER (
  PARTITION BY dt, user_id
  ORDER BY created_at DESC, inserted_date DESC
) AS rn
```

### 7.2 LTV metrikleri

Sorgularda kullanılan ana LTV metrikleri:

```text
avg_realized_ltv_tl
median_realized_ltv_tl
total_realized_ltv_tl
```

Median için:

```sql
APPROX_QUANTILES(user_realized_ltv_tl, 100)[OFFSET(50)]
```

### 7.3 Forecast LTV intentionally different

`BC_FORECAST_LTV_MONTHLY_01` realized LTV ile aynı şey değildir. Bu sorgu forecast mantığı içerir.

Temel mantık:

```text
Forecast LTV ≈ ARPU × average lifetime months
```

Bu nedenle realized LTV grafikleriyle birebir aynı beklenmemeli. Header notunda bunun farklı bir metrik olduğu açıklandı.

### 7.4 Category LTV notu

`BC_CATEGORY_LTV_02` şu an first watched category üzerinden raw payment-sum realized LTV tarzına daha yakındır. Monthly realized LTV'de kullanılan active-day prorated basis ile birebir aynı değildir.

Bu nedenle dokümantasyonda şu şekilde not düşülmeli:

```text
Category LTV, kullanıcıların ilk izlediği kategoriye göre user-level realized LTV dağılımı verir.
Monthly realized LTV ile aynı prorated monthly basis değildir. Gerekirse ileride aynı active-day LTV basis'e taşınmalıdır.
```

---

## 8. Dosya Bazlı Değişiklikler

### 8.1 `BC_CAC_MONTHLY_01`

Eski problem:

- Spend tarafında channel normalize ediliyordu ama attribution tarafında `g.mapped_channel` doğrudan kullanılabiliyordu.
- Meta/IG/Facebook varyasyonları kaçabiliyordu.
- Spend olan ama attributed user olmayan channel'larda CAC `NULL` dönüyor, Looker bunu gizliyor gibi görünüyordu.

Yeni yaklaşım:

- Spend kaynağı: `bc_marketing_marts.ads_daily_spend`
- Channel normalization hem spend hem attribution tarafında yapıldı.
- Attribution: first paid kullanıcıların ödeme öncesi son 30 gündeki en son eligible paid touch'ı.
- Her user bir kanala yazılıyor.
- `cac_status` eklendi.
- `all_channels` satırı blended CAC için korunuyor.

Önemli çıktı alanları:

```text
channel_scope
sort_order
month
channel
spend_tl
new_paid_users
cac_tl
total_first_paid_users
attribution_coverage
cac_status
```

### 8.2 `BC_LTVCAC_REALIZED_MONTHLY_01`

Amaç:

```text
Aylık realized LTV, CAC ve LTV/CAC ratio'yu aynı cohort ve attribution mantığıyla hesaplamak.
```

Yapılan standardizasyon:

- CAC tarafı `BC_CAC_MONTHLY_01` ile aynı first paid + 30d last touch mantığına çekildi.
- Spend source `bc_marketing_marts.ads_daily_spend` olarak standardize edildi.
- LTV tarafı active-day prorated TRY net revenue mantığıyla hesaplandı.
- Ratio metrikleri `NULL` durumlarını bozmayacak şekilde `SAFE_DIVIDE` ile bırakıldı.

### 8.3 `BC_CHANNEL_LTVCAC_REALIZED_01`

Amaç:

```text
Channel bazında selected period ve monthly kırılımda LTV/CAC göstermek.
```

Beklenen output iki scope içerir:

```text
channel_scope = selected_period
channel_scope = monthly
```

Bu sorguda şu mantık kullanıldı:

- `first_paid_selected`: seçili tarih aralığında ilk kez ücretli olan kullanıcılar.
- `normalized_touches`: seçili aralıktan 30 gün geriye kadar touch verisi.
- `user_channel_full`: kullanıcıya attribution channel atama. Uygun touch yoksa `other`.
- `user_realized_ltv`: ds_end'e kadar user-level realized LTV.
- `spend_monthly`: spend kanallarının normalize edilmesi.
- `FULL OUTER JOIN`: spend olan ama user olmayan channel'lar kaybolmasın.

Önemli: Bu sorguda sonradan bir alias bug yakalandı.

Hatalı blok:

```sql
selected_channel_user_metrics AS (
  SELECT
    channel,
    COUNT(DISTINCT user_id) AS users,
    AVG(COALESCE(l.user_realized_ltv_tl, 0)) AS avg_realized_ltv_tl,
    APPROX_QUANTILES(COALESCE(l.user_realized_ltv_tl, 0), 100)[OFFSET(50)] AS median_realized_ltv_tl,
    SUM(COALESCE(l.user_realized_ltv_tl, 0)) AS total_realized_ltv_tl
  FROM user_channel_full uc
  LEFT JOIN user_realized_ltv l
    ON uc.user_id = l.user_id
  GROUP BY channel
)
```

BigQuery hatası:

```text
Column name user_id is ambiguous
```

Doğru patch:

```sql
selected_channel_user_metrics AS (
  SELECT
    uc.channel,
    COUNT(DISTINCT uc.user_id) AS users,
    AVG(COALESCE(l.user_realized_ltv_tl, 0)) AS avg_realized_ltv_tl,
    APPROX_QUANTILES(COALESCE(l.user_realized_ltv_tl, 0), 100)[OFFSET(50)] AS median_realized_ltv_tl,
    SUM(COALESCE(l.user_realized_ltv_tl, 0)) AS total_realized_ltv_tl
  FROM user_channel_full uc
  LEFT JOIN user_realized_ltv l
    ON uc.user_id = l.user_id
  GROUP BY uc.channel
)
```

Bu patch uygulanmalıdır.

### 8.4 `BC_REALIZED_LTV_MONTHLY_01`

Amaç:

```text
Aylık realized LTV hesaplamak.
```

Reviewed versiyonda:

- TRY-only
- PREPAID hariç
- aktif günlere dağıtılmış net revenue
- daily active dedup
- cumulative user LTV
- avg / median / total realized LTV outputları korunur.

Bu sorgu realized LTV için referans basis kabul edildi.

### 8.5 `BC_FORECAST_LTV_MONTHLY_01`

Amaç:

```text
Forecast LTV hesaplamak.
```

Not:

- Bu sorgu realized LTV ile aynı değildir.
- Forecast mantığı ARPU ve lifetime estimate içerir.
- Documentation'da “forecast metrik” olarak ayrı tanımlanmalıdır.

### 8.6 `BC_CATEGORY_LTV_02`

Amaç:

```text
Kullanıcıların ilk izlediği kategoriye göre ortalama LTV göstermek.
```

Not:

- First category = kullanıcının ilk meaningful watched content'inin ilk genre değeri.
- LTV raw payment-sum realized LTV mantığına daha yakın.
- Monthly realized active-day prorated LTV ile birebir aynı değildir.
- Eğer tüm dashboardlarda birebir aynı LTV basis istenirse ileride bu sorgu da `user_realized_ltv` active-day basis'e taşınmalıdır.

### 8.7 `BC_WATCHER_LTV_02`

Amaç:

```text
Heavy / Light watcher segmentleri için LTV karşılaştırması.
```

Reviewed notları:

- Cohort window seçili tarih aralığından 90 gün geriye kaydırılır.
- Kullanıcının ilk meaningful watch'ı cohort entry kabul edilir.
- İlk 30 gün watch time üzerinden segment oluşturulur.
- Light = bottom 30%
- Heavy = top 30%
- Middle exclude edilir.
- Günlük 24 saat üstü watch outlier'ları segmentasyondan çıkarılır.
- LTV active-day prorated TRY realized LTV mantığına yakındır.

---

## 9. Looker Studio Konfigürasyon Notları

### 9.1 Channel Bazlı LTV/CAC grafiği

`BC_CHANNEL_LTVCAC_REALIZED_01` source'u iki farklı scope döndürdüğü için chart filtreleri doğru ayarlanmalıdır.

Selected period grafiği için:

```text
Filter: channel_scope = selected_period
```

Monthly trend için:

```text
Filter: channel_scope = monthly
```

LTV/CAC ratio grafiğinde ayrıca önerilen filtre:

```text
cac_status = ok
```

Sebep: `spend_var_user_yok` gibi durumlarda CAC hesaplanamaz ve `ltv_cac_ratio` da `NULL` olur. Looker bunu 0 gibi ya da boş gibi gösterebilir.

### 9.2 Ratio metriklerinde aggregation

Ratio metrikleri Looker'da `SUM` ile kullanılmamalı.

Yanlış:

```text
SUM(LTV/CAC Ratio)
```

Doğru yaklaşım:

```text
AVG(LTV/CAC Ratio)
```

veya chart tek satır/tek scope filtrelenmişse SQL'den gelen değeri aggregation ile bozmayacak şekilde kullanmak.

Özellikle şu metriklerde dikkat:

```text
ltv_cac_ratio
attribution_coverage
cac_tl
avg_realized_ltv_tl
```

`spend_tl`, `new_paid_users`, `users`, `total_realized_ltv_tl` gibi metrikler sumlanabilir; ratio metrikleri sumlanmamalıdır.

### 9.3 Meta'nın görünmemesi nasıl yorumlanmalı?

Eğer Meta için spend var ama user yoksa beklenen satır:

```text
channel = meta
spend_tl > 0
users/new_paid_users = 0
cac_tl = NULL
cac_status = spend_var_user_yok
```

Looker bar chart bu `NULL` CAC'i çizmez. Bu “Meta verisi yok” anlamına gelmez. Anlamı:

```text
Meta harcaması var ama seçili attribution modeline göre ödeme öncesi son 30 günde Meta kaynaklı yeni ücretli kullanıcı yok.
```

Bu nedenle dashboard'da CAC chart yanında debug/diagnostic tablo önerilir:

```text
channel
spend_tl
new_paid_users / users
cac_tl
cac_status
attribution_coverage
```

---

## 10. Mayıs 2026 Meta Debug Sonucu

Bu konuşmada Mayıs 2026 için yapılan analizde şu sonuçlara ulaşıldı:

1. GA4 attribution tablosunda Mayıs ayında Meta/IG/Tiktok touch kayıtları vardı.
2. Ancak Meta/IG kayıtlarının önemli kısmı `no_paid_record` veya `paid_before_touch` durumundaydı.
3. Tiktok tarafında ödeme öncesi 30 gün içinde attribution'a girebilen kullanıcılar vardı.
4. Google tarafında 1000+ attributed user görüldü.
5. Meta için `new_paid_users = 0` olması SQL hatası değil, mevcut attribution ve acquisition tanımına göre doğru sonuçtu.

Önemli ayrım:

```text
Mayıs ayında Meta touch var
≠
Mayıs ayında Meta kaynaklı yeni ücretli kullanıcı var
```

CAC acquisition metriği ikinci ifadeyi ölçer.

---

## 11. Bilinen Sınırlamalar

### 11.1 `ga4_first_non_direct_touch` gerçek last-touch için yeterli olmayabilir

Mevcut attribution tablosu adı gereği kullanıcı başına first non-direct touch mantığı taşıyor olabilir. Eğer tablo kullanıcı başına sadece ilk touch'ı tutuyorsa, bu tablodan gerçek last paid touch attribution üretilemez.

Bu çalışmadaki model:

```text
Bu tabloda mevcut olan touch kayıtları arasından ödeme öncesi son 30 gündeki en son eligible touch'ı seçer.
```

Ancak ideal model:

```text
Raw GA4 event/touch datasından her first paid user için ödeme öncesi son 30 gündeki son eligible paid touch'ı üretmek.
```

### 11.2 Meta / app deep link / user_id eşleşmesi sorunu olabilir

Meta harcaması yüksek olmasına rağmen GA4 touch tarafında çok az Meta user görünüyorsa olası sebepler:

1. Meta UTM tagging eksik ya da tutarsız olabilir.
2. App/deeplink tarafında source/medium/campaign kayboluyor olabilir.
3. GA4 user_id ile backend `subs_payment.user_id` eşleşmesi eksik olabilir.
4. Meta attribution Meta Ads Manager içinde görünüyor ama GA4 tarafına taşınmıyor olabilir.
5. `ga4_first_non_direct_touch` tablo modeli sadece ilk touch'ı sakladığı için sonradan gelen Meta touch'ları görünmüyor olabilir.

Bu nedenle Meta CAC'i yorumlarken GA4 attribution verisinin coverage'ı ayrıca kontrol edilmeli.

### 11.3 Category LTV basis farkı

`BC_CATEGORY_LTV_02` şimdilik monthly realized active-day basis ile birebir aynı değildir. Bu durum dokümantasyona bilinçli fark olarak yazılmalı.

---

## 12. Gelecek İçin Önerilen Data Mart

Uzun vadede aşağıdaki gibi bir attribution mart oluşturulması önerilir:

```text
bc_marketing_marts.ga4_last_paid_touch_30d
```

Önerilen grain:

```text
one row per user_id per first_paid_date
```

Önerilen kolonlar:

```text
user_id
first_paid_date
attributed_touch_date
day_diff
source
medium
campaign
raw_mapped_channel
normalized_channel
attribution_model
created_at
```

Önerilen attribution modeli:

```text
last eligible paid/non-direct touch within 30 days before first paid
```

Bu mart üretildikten sonra tüm CAC ve LTV/CAC sorguları doğrudan bu tabloyu kullanmalı. Böylece dashboard query'leri içinde uzun attribution logic tekrar edilmez.

---

## 13. Başka Bir Agent İçin Net Talimat

Bu dosyayı alan başka bir agent aşağıdaki adımları izlemeli:

1. BigQuery documentation canvas'ında CAC ve LTV tanımlarını bu dosyadaki standartlara göre güncelle.
2. CAC için `bc_marketing_marts.ads_daily_spend` kullanımını primary spend source olarak yaz.
3. Eski `manual_monthly_spend` kullanımını legacy / temporary olarak işaretle.
4. CAC denominator tanımını “first paid users attributed by last eligible touch within 30 days before first payment” olarak yaz.
5. `PREPAID` hariç, `TRY` only, `amount/amount_before_promotions > 0` filtrelerini belirt.
6. Channel normalization mapping'i dokümantasyona ekle.
7. `cac_status` alanını açıklayan bir bölüm ekle.
8. Looker Studio ratio aggregation notunu ekle: ratio metrikler `SUM` ile kullanılmamalı.
9. `BC_CHANNEL_LTVCAC_REALIZED_01` için `channel_scope = selected_period/monthly` filtre kullanımını yaz.
10. Known limitations bölümüne `ga4_first_non_direct_touch` tablosunun gerçek last-touch için sınırlı olabileceğini yaz.
11. Future recommendation olarak `ga4_last_paid_touch_30d` mart önerisini ekle.
12. Category LTV'nin realized monthly LTV ile birebir aynı basis'te olmadığını açıkça belirt.
13. Forecast LTV'nin realized LTV olmadığı; ARPU × lifetime estimate mantığında ayrı bir forecast metrik olduğu notunu ekle.

---

## 14. Dashboard / İş Tarafı İçin Açıklama Cümlesi

Aşağıdaki açıklama iş tarafına sade şekilde kullanılabilir:

> CAC metriğinde kullanıcılar, ilk ücretli ödeme tarihinden önceki son 30 gün içinde temas ettikleri son uygun paid kanala yazılır. Bir kanalda harcama olup attributed yeni ücretli kullanıcı yoksa CAC hesaplanamaz ve değer `NULL` kalır. Bu durum dashboard'da ilgili kanalın kaybolması gibi görünebilir; ancak bu veri yokluğu değil, seçili attribution modeline göre o kanal için acquisition conversion bulunmadığı anlamına gelir.

Meta özelinde:

> Mayıs ayında Meta/IG touch kayıtları görülmüş olsa da bu kullanıcıların bir kısmı hiç ödeme yapmamış, bir kısmı ise Meta touch'tan önce ödeme yapmıştır. Bu nedenle acquisition CAC denominator'ına dahil edilmemeleri doğru kabul edilmiştir.

---

## 15. Teknik Checklist

Yeni veya revize edilmiş CAC / LTV-CAC sorgusu kontrol edilirken şu checklist uygulanmalı:

```text
[ ] Spend source bc_marketing_marts.ads_daily_spend mi?
[ ] Payment source subs_payment mi?
[ ] TRY-only filtresi var mı?
[ ] PREPAID exclude ediliyor mu?
[ ] amount veya amount_before_promotions > 0 kontrolü var mı?
[ ] first_paid_date user bazında MIN(DATE(created_at)) ile mi alınıyor?
[ ] Channel normalization hem spend hem attribution tarafında aynı mı?
[ ] Attribution window ödeme öncesi 0-30 gün mü?
[ ] Kullanıcı başına tek channel seçiliyor mu?
[ ] Spend olan ama user olmayan channel FULL/LEFT join ile korunuyor mu?
[ ] CAC 0'a coalesce edilmiyor, NULL bırakılıyor mu?
[ ] cac_status var mı?
[ ] Ratio metrikler Looker'da SUM yapılmıyor mu?
[ ] channel_scope doğru filtreleniyor mu?
[ ] Category / Forecast LTV gibi bilerek farklı metrikler dokümante edildi mi?
```

---

## 16. Son Durum

Konuşmanın sonunda:

- `BC_CAC_MONTHLY_01` mantığı standardize edildi.
- `BC_LTVCAC_REALIZED_MONTHLY_01` mantığı CAC standardına çekildi.
- `BC_CHANNEL_LTVCAC_REALIZED_01` çalıştırıldı, alias hatası tespit edildi ve patch verildi.
- Looker'daki Channel Bazlı LTV/CAC grafiği için filtre ve aggregation düzeltmeleri yapıldı:

```text
channel_scope = selected_period
cac_status = ok
LTV/CAC Ratio aggregation = AVG / non-SUM
```

- Meta'nın 3 touch kaydı olmasına rağmen CAC denominator'ına girmemesinin sebebi açıklandı:

```text
Touch var ama first paid acquisition yok.
```

Bu dosya, BigQuery documentation çalışmasına aktarılmak üzere hazırlanmıştır.
