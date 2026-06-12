

# GAIN-208 Agent Log — TCMB FX Standardizasyonu ve Ödeme Aracı Dağılımı

**Tarih:** 11.06.2026  
**Hazırlayan:** Batuhan ÇAKIR  
**Kapsam:** Looker finansal KPI SQL revizyonları, TCMB kur dönüşümü, ödeme aracı dağılımı datasource hazırlığı

---

## 1. İşin Amacı

Bu çalışmada GAİN Looker dashboard’larında kullanılan finansal KPI’ların TRY-only yapıdan çıkarılarak dövizli ödemeleri de kapsayacak şekilde standartlaştırılması hedeflendi.

İşin iki ana parçası vardı:

1. **Döviz bazlı finansal metrik standardizasyonu**
   - Gelir, ARPU, LTV, CAC/LTV, payment amount, tahsilat ve benzeri parasal KPI’ların dövizli ödemeleri de kapsaması.
   - Dövizli ödemelerin TCMB referans kuru ile TL’ye normalize edilmesi.
   - Tarih bazlı kur eşleştirmesinin yapılması.
   - Kullanılan kur kaynağı ve hesaplama mantığının dokümante edilmesi.

2. **Ödeme aracı dağılımı geliştirmesi**
   - Dashboard’da ödeme aracı bazında kaç adet ödeme alındığının gösterilmesi.
   - Ödeme aracı bazında yüzde payların hesaplanması.
   - Donut chart için ödeme adedi ve oran alanlarının hazırlanması.
   - Yeni Airflow payment provider raw tablolarının gerçek tahsilat kaynağı olarak kullanılması.

---

## 2. Kullanılan Ana Kaynaklar

### 2.1 TCMB Kur Kaynağı

Döviz dönüşümlerinde kullanılan tablo:

```sql
`microgain-9f959.bc_t.tcmb_exchange_rates_raw`
```

Kullanılan alanlar:

| Alan | Açıklama |
| --- | --- |
| `rate_date` | Kur tarihi |
| `currency_code` | Döviz kodu |
| `unit` | TCMB kurunun kaç birim döviz için verildiği |
| `forex_buying` | TCMB döviz alış kuru |

Kur standardı:

```sql
rate_to_try = forex_buying / unit
```

Bu yapı özellikle `JPY`, `KRW`, `KZT` gibi `unit` değeri 1’den farklı para birimlerinde kurun şişmesini engeller.

Kur eşleşme mantığı:

```sql
r.currency_code = payment.currency_code
AND r.rate_date <= payment_date
ORDER BY r.rate_date DESC
LIMIT 1
```

BigQuery correlated subquery hatasına takılmamak için bu mantık SQL’lerde `LEFT JOIN + ROW_NUMBER()` yapısına çevrildi.

---

### 2.2 Ana Subscription / Payment Kaynağı

```sql
`microgain-9f959.aws_s3_to_bq_migration.subs_payment`
```

Kullanıldığı alanlar:

- APP_STORE / PLAY_STORE / CRAFTGATE ödemeleri
- Active subscriber hesapları
- Revenue allocation
- LTV ve ARPU hesapları
- First paid user hesapları
- Campaign cohort hesapları
- Store payment fallback

Önemli business kararları:

- `PREPAID` çoğu unit economics ve LTV/CAC hesabından hariç tutulmaya devam eder.
- `CANCELED` kullanıcılar `valid_until` tarihine kadar aktif kabul edilir.
- `ACTIVE`, `CANCELED`, `IN_GRACE`, `ON_HOLD` aktiflik bazlı modellerde dikkate alınır.
- `IN_GRACE` için `grace_until`, `ON_HOLD` için `hold_until`, aksi durumda `valid_until` active end date olarak kullanılır.

---

### 2.3 Reklam Spend Kaynağı

Manual spend bağımlılığı kaldırıldı.

Legacy / kullanılmaması gereken kaynak:

```sql
`microgain-9f959.bc_marketing_raw.manual_monthly_spend`
```

Güncel standart kaynak:

```sql
`microgain-9f959.bc_marketing_marts.ads_daily_spend`
```

Bu kaynak Google Ads ve Meta Ads raw transferlarından beslenen unified spend mart tablosudur. Campaign Unit Economics Cohort sorgusunda da CAC artık bu tablo üzerinden hesaplanacak şekilde güncellendi.

---

### 2.4 Yeni Airflow Payment Provider Raw Tabloları

Ödeme aracı dağılımı için kullanılan yeni provider tabloları:

```sql
`microgain-9f959.bc_t.iyzico_transactions_raw`
`microgain-9f959.bc_t.param_transactions_raw`
`microgain-9f959.bc_t.payguru_transactions_raw`
`microgain-9f959.bc_t.nkolay_transactions_raw`
```

Bu tabloların ortak özelliği: Provider bazlı gerçek transaction kayıtlarını taşırlar. Ancak bu tablolarda `user_id` bulunmaz. Bu nedenle provider raw kaynaklarından gelen ödeme araçları için `payment_count` güvenilir şekilde hesaplanır, fakat `user_count` hesaplanamaz.

---

## 3. TCMB Döviz Standardizasyonu

### 3.1 Genel Dönüşüm Mantığı

TRY ödemeler doğrudan TL kabul edildi:

```sql
amount_tl = amount / 100
```

Dövizli ödemelerde:

```sql
amount_tl = (amount / 100) * rate_to_try
rate_to_try = forex_buying / unit
```

Provider raw tablolarında tutarlar zaten major unit formatında geldiği için payment method distribution sorgusunda tekrar `/100` uygulanmadı.

---

### 3.2 Kur Bulunamayan Günler

TCMB hafta sonu / tatil gibi günlerde kur yayınlamayabileceği için birebir ödeme günü kuru bulunamadığında ödeme tarihinden önceki en güncel kur kullanıldı.

Bu yaklaşım tüm finansal SQL’lerde ortak standart olarak uygulandı.

---

### 3.3 BigQuery Teknik Notu

İlk denemede `SELECT` içinde correlated subquery ile son kur seçilmeye çalışıldı. BigQuery şu hatayı verdi:

```text
Correlated subqueries that reference other tables are not supported unless they can be de-correlated.
```

Bu nedenle tüm sorgular şu yapıya geçirildi:

```sql
LEFT JOIN tcmb_rates r
  ON currency_code != 'TRY'
 AND r.currency_code = currency_code
 AND r.rate_date <= payment_date

ROW_NUMBER() OVER (
  PARTITION BY transaction/user/payment keys
  ORDER BY r.rate_date DESC
) AS rate_rn
```

Sonrasında `currency_code = 'TRY' OR rate_rn = 1` filtresiyle ödeme başına en güncel kur seçildi.

---

## 4. Güncellenen SQL Dosyaları

Aşağıdaki SQL’ler TCMB döviz dönüşümü ve yeni aktiflik standardına göre güncellendi:

| SQL | Yapılan Değişiklik |
| --- | --- |
| `BC_UNIT_ECONOMICS_DAILY_01.sql` | TRY-only kaldırıldı, dövizli ödemeler TCMB kuru ile TL’ye çevrildi, CANCELED valid_until’a kadar aktif sayıldı. |
| `BC_CAC_MONTHLY_01.sql` | First paid user havuzu TRY-only olmaktan çıkarıldı, dövizli first paid kullanıcılar kur bulunuyorsa dahil edildi. |
| `BC_LTVCAC_REALIZED_MONTHLY_01.sql` | CAC first paid havuzu ve realized revenue tarafı döviz standardına çekildi, CANCELED dahil edildi. |
| `BC_FORECAST_LTV_MONTHLY_01.sql` | Forecast LTV revenue ve lifetime başlangıç hesabı TRY + döviz standardına çekildi, CANCELED dahil edildi. |
| `BC_REALIZED_LTV_MONTHLY_01.sql` | Realized cumulative LTV hesapları TRY + döviz standardına çekildi, CANCELED dahil edildi. |
| `BC_CHANNEL_LTVCAC_REALIZED_01.sql` | Channel attribution cohort ve channel realized LTV tarafı döviz standardına çekildi. |
| `BC_WATCHER_LTV_02.sql` | Heavy / Light watcher LTV tarafında TRY-only kaldırıldı, dövizli ödemeler dahil edildi, CANCELED dahil edildi. |
| `BC_CATEGORY_LTV_02.sql` | Category LTV ödeme toplamı bazlı realized LTV hesabı TRY + döviz standardına çekildi. |
| `BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02.sql` | Actual revenue ve no-promo comparable revenue döviz standardına çekildi, manual spend kaldırıldı, CAC `ads_daily_spend` üzerinden hesaplandı. |
| `BC_PAYMENT_METHOD_DISTRIBUTION_01.sql` | Ödeme aracı dağılımı için yeni SQL oluşturuldu. |

---

## 5. Metrik Tanımları ve Grain Notları

### 5.1 `active_user_count`

Seçili ay içinde en az bir gün aktif olan tekil kullanıcı sayısıdır.

Teknik olarak:

```sql
COUNT(DISTINCT user_id)
```

aylık aktif kullanıcı havuzu üzerinden hesaplanır.

Bir kullanıcı ay içinde sadece 1 gün aktif olsa da, ayın tamamında aktif olsa da `active_user_count` içinde 1 kullanıcı olarak sayılır.

---

### 5.2 `avg_daily_active_users`

Seçili ay içindeki günlük aktif kullanıcı sayılarının ortalamasıdır.

Teknik olarak:

```sql
AVG(daily_active_users)
```

Bu nedenle `active_user_count` ile aynı sayı olması beklenmez. `active_user_count` monthly unique reach, `avg_daily_active_users` ise ortalama günlük aktif subscriber base olarak okunmalıdır.

---

### 5.3 `net_revenue_tl` ve `total_revenue_tl`

`net_revenue_tl` günlük net revenue metriğidir.

`total_revenue_tl` ise seçili ay veya dönemdeki günlük net revenue toplamıdır.

Bu nedenle günlük unit economics sorgusundaki `net_revenue_tl` ile monthly LTV/CAC sorgusundaki `total_revenue_tl` arasında büyüklük farkı olması normaldir.

Örnek:

```text
Günlük net_revenue_tl ≈ 650K - 700K TL
Mayıs total_revenue_tl ≈ günlük revenue toplamı ≈ 20M+ TL
```

---

## 6. Test ve Validasyon Bulguları

### 6.1 Unit Economics Mayıs Kontrolü

Mayıs 2026 testinde döviz dahil yeni sorguların etkisi tutarlı görüldü.

Örnek gözlem:

- Active subscriber / active user sayısı yaklaşık 2.1K - 2.8K bandında arttı.
- Revenue tarafında yaklaşık %2.7 - %2.8 artış görüldü.
- ARPU artışı kontrollü kaldı.
- TCMB kur dönüşümü sonrası JPY, KRW, KZT gibi para birimlerinde unit kaynaklı şişme görülmedi.
- `missing_rate_rows = 0` kontrolü temiz geldi.

---

### 6.2 CAC Kontrolü

Mayıs 2026 testinde:

- `spend_tl` değişmedi.
- `total_first_paid_users` dövizli kullanıcılar dahil edildiği için arttı.
- `new_paid_users` çok sınırlı arttı.
- CAC küçük ölçekte düştü.
- Dövizli kullanıcıların büyük kısmı paid attribution alamadığı için `other` veya unattributed havuzda kaldı.

Meta tarafında spend olmasına rağmen attributed user 0 gelmesi döviz çalışmasından bağımsız ayrı bir attribution/mapping konusu olarak not edildi.

---

### 6.3 LTV Kontrolleri

Realized LTV, Forecast LTV ve LTV/CAC sorgularında sonuçlar tutarlı görüldü.

Genel gözlem:

- `total_revenue_tl` arttı.
- `avg_daily_active_users` arttı.
- `arpu_tl` kontrollü arttı.
- `realized_ltv_tl` bazı modellerde hafif düşebildi. Bunun sebebi dövizli/CANCELED kullanıcılarla kullanıcı havuzunun genişlemesi ve yeni eklenen kullanıcıların ortalama geçmiş LTV profilinin daha düşük olmasıdır.
- `total_realized_ltv_tl` arttı.

Bu nedenle ortalama LTV düşerken toplam LTV’nin artması business olarak tutarlı kabul edildi.

---

### 6.4 Category LTV Kontrolü

`BC_CATEGORY_LTV_02.sql` active-day prorated LTV değil, raw payment-sum realized LTV kullanır.

Bu sorguda döviz standardizasyonu sonrası:

- Kategori kullanıcı sayıları değişmedi.
- Bazı kategorilerde `avg_ltv_tl` ve `total_ltv_tl` arttı.
- `amount > 0` filtresi patch sırasında düşmüştü, tekrar eklendi.
- 0 tutarlı payment satırlarının LTV/payment_count hesabını kirletmesi engellendi.

---

### 6.5 Campaign Unit Economics Cohort Kontrolü

Bu modelde iki ayrı revenue alanı olduğu için özel ele alındı:

- `actual revenue = amount`
- `no-promo comparable revenue = amount_before_promotions`

Başlangıçta `amount_before_promotions` store ödemelerinde de kurla çarpıldığı için gross-before-promo tarafı şişti.

Raw kontrol sonrası şu karar alındı:

- `APP_STORE` ve `PLAY_STORE` için `amount_before_promotions` TL/list-price bazlı kabul edilir.
- Bu alan store ödemelerinde tekrar TCMB kuru ile çarpılmaz.
- Promosuz karşılaştırılabilir gelir actual revenue’dan düşük kalmaması için `GREATEST(before_promo, actual)` uygulanır.

Manual spend kaynağı kaldırıldı ve CAC şu kaynağa bağlandı:

```sql
`microgain-9f959.bc_marketing_marts.ads_daily_spend`
```

---

## 7. Ödeme Aracı Dağılımı SQL’i

Yeni SQL:

```text
BC_PAYMENT_METHOD_DISTRIBUTION_01.sql
```

Amaç:

Seçili tarih aralığında ödeme aracı bazında kaç adet gerçek tahsilat alındığını ve bu ödemelerin toplam içindeki yüzde payını göstermek.

---

### 7.1 Kaynak Mantığı

Hibrit kaynak kullanıldı.

| Ödeme Aracı | Kaynak |
| --- | --- |
| Apple / App Store | `subs_payment.payment_option = 'APP_STORE'` |
| Google / Play Store | `subs_payment.payment_option = 'PLAY_STORE'` |
| Craftgate | `subs_payment.payment_option = 'CRAFTGATE'` |
| Iyzico | `bc_t.iyzico_transactions_raw` |
| Param | `bc_t.param_transactions_raw` |
| Payguru / Mobil | `bc_t.payguru_transactions_raw` |
| N Kolay | `bc_t.nkolay_transactions_raw` |

Apple, Google ve Craftgate tarafında `subs_payment` kullanıldı çünkü bu ödeme araçları yeni provider raw tablolarında yer almıyor.

Iyzico, Param, Payguru ve N Kolay tarafında yeni Airflow raw tabloları kullanıldı.

---

### 7.2 Provider Kolon Mapping’i

| Provider | Transaction Key | Tarih | Tutar | Currency |
| --- | --- | --- | --- | --- |
| Iyzico | `transaction_id`, `payment_tx_id`, `payment_id`, `conversation_id`, `basket_id` | `transaction_date`, fallback `report_date` | `COALESCE(paid_price, amount, price)` | `COALESCE(currency, transaction_currency, settlement_currency)` |
| Param | `transaction_id`, `order_id` | `transaction_date` | `gross_amount` | `currency` |
| Payguru | `transaction_id`, `reference_code`, `subscription_id` | `transaction_date` | `amount` | `currency` |
| N Kolay | `transaction_id`, `reference_code`, `client_reference_code`, `auth_code` | `transaction_date` | `transaction_amount` | `currency` |

---

### 7.3 Gerçek Tahsilat Filtresi

İlk testte `amount > 0` filtresi kullanıldığında toplam ödeme adedi yaklaşık 201K geldi. Bu sayı önceki abonelik/payment kontrollerine göre yüksek kabul edildi.

Sebep olarak trial/provizyon/test benzeri düşük tutarlı ödemeler ve refund/cancel/reversal satırları değerlendirildi.

Bu nedenle filtre standardı güncellendi:

```sql
amount_original >= 101.0
```

Ayrıca provider raw tablolarında text alanları üzerinden şu tip kayıtlar dışarı alındı:

```text
REFUND
CANCEL
CANCELLATION
REVERSAL
IADE / İADE
IPTAL / İPTAL
FAILED
ERROR
```

Bu temizlik sonrası Mayıs 2026 testinde toplam ödeme adedi yaklaşık 173K seviyesine düştü ve önceki ödeme/abonelik kontrolleriyle uyumlu kabul edildi.

---

### 7.4 User Count Notu

Provider raw tablolarında `user_id` yoktur.

Bu nedenle:

- Iyzico
- Param
- Payguru
- N Kolay

için `user_count` hesaplanamaz ve `NULL` bırakılır.

Apple, Google ve Craftgate `subs_payment` üzerinden geldiği için `user_count` hesaplanabilir.

Dashboard tarafında ana donut metriği kesinlikle `user_count` değil, `payment_count` olmalıdır.

---

### 7.5 Looker Donut Kurulumu

Önerilen donut chart setup:

```text
Dimension: payment_method_label
Metric: payment_count
Filter: payment_count > 0
```

Label / tooltip için:

```text
donut_label
```

Örnek label formatı:

```text
Iyzico 51575 ödeme (29.8%)
Apple / App Store 57490 ödeme (33.2%)
Craftgate 40602 ödeme (23.5%)
```

---

## 8. Mayıs 2026 Payment Method Distribution Testi

101 TL minimum gerçek tahsilat eşiği ve refund/cancel filtreleri sonrası Mayıs 2026 test çıktısı yaklaşık şu yapıya oturdu:

| Payment Provider | Payment Count | Yaklaşık Pay |
| --- | ---: | ---: |
| Apple / App Store | 57,490 | %33.2 |
| Iyzico | 51,575 | %29.8 |
| Craftgate | 40,602 | %23.5 |
| Google / Play Store | 16,585 | %9.6 |
| Payguru / Mobil | 6,763 | %3.9 |
| Param | 0 | %0 |
| N Kolay | 0 | %0 |

Toplam ödeme adedi:

```text
173,015
```

Bu değer, önceki 201K şişkin sonuca göre daha tutarlı bulundu ve 170K civarı ödeme/adet beklentisiyle uyumlu kabul edildi.

---

## 9. Production Notları

### 9.1 TCMB FX Standardizasyonu

- SQL’ler production’a alınmadan önce Looker datasource tarih parametreleri `@DS_START_DATE` ve `@DS_END_DATE` ile çalışacak şekilde bırakılmalıdır.
- Test amaçlı lokal `DATE 'YYYY-MM-DD'` parametreleri prod SQL’e taşınmamalıdır.
- Dövizli kayıtlarda kur bulunamayan satırlar `amount_gross_tl IS NOT NULL` filtresiyle dışarıda kalır.
- `missing_rate_rows` kontrolleri düzenli aralıklarla yapılmalıdır.

---

### 9.2 Ödeme Aracı Dağılımı

- Donut grafikte 0 payment_count değerleri gösterilmemelidir.
- Table debug görünümünde 0 provider satırları tutulabilir.
- Provider raw kaynaklarında `user_id` olmadığı için user bazlı dağılım bu SQL’den beklenmemelidir.
- Eğer ileride provider raw tabloları `user_id` veya güvenilir subscription transaction mapping içerecek şekilde genişletilirse, user_count tüm ödeme araçları için yeniden hesaplanabilir.
- 101 TL minimum eşik, trial/provizyon/test ödemelerini dışarı almak için kullanılır. Business tarafı farklı bir paid threshold belirlerse bu değer merkezi olarak güncellenmelidir.

---

## 10. Dokümantasyona İşlenen Notlar

v1.1 teknik dokümantasyonuna aşağıdaki başlıklar işlendi:

- TCMB kur kaynağı ve `forex_buying / unit` standardı.
- TRY-only finansal KPI yaklaşımının terk edildiği.
- CANCELED kullanıcıların `valid_until` tarihine kadar aktif kabul edildiği.
- `active_user_count` ve `avg_daily_active_users` farkı.
- `net_revenue_tl` ve `total_revenue_tl` grain farkı.
- `manual_monthly_spend` kullanımının kaldırılıp `ads_daily_spend` standardının sabitlendiği.
- Campaign Unit Economics Cohort için store `amount_before_promotions` özel durumu.
- Ödeme aracı dağılımında `payment_count` metriğinin ana donut metriği olduğu.

---

## 11. Açık Noktalar / Gelecek İyileştirmeler

- Meta attribution hâlâ 0 kullanıcı üretebiliyor. Bu döviz çalışmasından bağımsızdır ve GA4 attribution mapping tarafında ayrıca incelenmelidir.
- Provider raw tablolarına `user_id` veya güvenilir subscription transaction mapping eklenirse ödeme aracı bazında unique user dağılımı tüm provider’lar için hesaplanabilir.
- `BC_PAYMENT_METHOD_DISTRIBUTION_01.sql` içindeki 101 TL threshold ileride business config / parameter yapısına taşınabilir.
- TCMB kur tablosunda eksik gün veya currency kontrolleri için ayrı bir QA scheduled query hazırlanabilir.
- Category LTV hâlâ payment-sum realized LTV mantığındadır; active-day prorated LTV ile birebir aynı basis’te değildir.

---

## 12. Kısa Özet

Bu çalışmayla GAİN Looker finansal KPI SQL’leri TCMB döviz kuru standardına taşındı. Dövizli ödemeler TL’ye normalize edildi, CANCELED kullanıcıların aktiflik mantığı düzeltildi, manual spend bağımlılığı kaldırıldı ve ödeme aracı bazında gerçek tahsilat adedi dağılımı için yeni SQL hazırlandı.

Ödeme aracı dağılımında 1 TL trial/provizyon ve refund/cancel kayıtları dışarı alınarak Mayıs 2026 için toplam ödeme adedi yaklaşık 173K seviyesine indirildi. Bu değer önceki abonelik ve ödeme kontrolleriyle tutarlı kabul edildi.