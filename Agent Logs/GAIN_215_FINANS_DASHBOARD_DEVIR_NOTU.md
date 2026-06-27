# GAIN 215 - Finans Dashboard Devir Notu

Son güncelleme: 26 Haziran 2026, Europe/Istanbul

Bu belge, Google/Apple ödeme verilerinin Airflow ve BigQuery'ye alınmasıyla
başlayan; finans dashboard SQL'leri, reklam CAC/LTV analizleri ve kampanya
ekonomisi ekranlarına uzanan çalışmanın kapsamlı devir kaydıdır.

Amaç, sohbet bağlamı veya token bütçesi kaybolduğunda aşağıdaki bilgilerin
korunmasıdır:

- Alınan iş kararları
- Kullanılan finans tanımları
- Tamamlanan kod ve SQL değişiklikleri
- Testlerde görülen sonuçlar
- Bilinen veri kalitesi sorunları
- Güncel kalan işler ve önerilen çalışma sırası

Bu belge ham mesaj transkripti değildir; konuşmadaki teknik kararların,
sonuçların ve açık işlerin eksiksiz, kullanılabilir biçimde derlenmiş halidir.

---

## 1. İşe Başlangıç Noktası

İlk hedef, finans dashboard için Google Play ve Apple App Store üzerinden ödeme
yapan kullanıcıların ve finansal işlemlerin alınmasıydı.

İstenen çalışma biçimi:

- Lokal manuel testte CSV üretmek
- Airflow ortamında CSV oluşturmadan doğrudan BigQuery'ye yazmak
- Lokal credential bilgilerini `.env` üzerinden okuyabilmek
- Airflow'da `.env` ve `python-dotenv` kullanmamak
- Airflow Variable değerlerini script'e environment variable olarak geçirmek
- Günlük çalışmada T-1 verisini almak
- Yeniden çalıştırmalarda aynı günü çoğaltmamak
- Başarı ve hata durumlarında Slack bildirimi göndermek
- İleride ödeme kuruluşlarından iki yıllık backfill almak

Oluşturulan BigQuery raw tabloları:

- `microgain-9f959.bc_t.googleplay_transactions_raw`
- `microgain-9f959.bc_t.apple_transactions_raw`

Tablo oluşturma SQL'leri:

- `google_random/create_google_play_transactions_raw.sql`
- `apple_api_files/create_apple_subscriber_transactions_raw.sql`

---

## 2. Google ve Apple Script Kararları

### 2.1 Lokal çalışma

Lokal kopyalarda `python-dotenv` kullanılabilir:

- `google_random/google_transaction_combo.py`
- `apple_api_files/apple_monthly_reports.py`

Beklenen lokal davranış:

- `WRITE_CSV=1`
- `BQ_ENABLED=0`
- CSV dosyası oluşturulur.
- BigQuery yüklemesi yapılmaz.

### 2.2 Airflow/S3 çalışma

S3'e gönderilecek kopyalarda `dotenv` importu yoktur:

- `S3'e atılacaklar/python_scripts/google_transaction_combo.py`
- `S3'e atılacaklar/python_scripts/apple_monthly_reports.py`

Airflow davranışı:

- `WRITE_CSV=0`
- `BQ_ENABLED=1`
- CSV yazılmaz.
- BigQuery staging tablo + hedef tarih silme/yükleme mantığı kullanılır.
- Aynı tarih yeniden çalıştırıldığında hedef tarih replace edilir; satır
  çoğalması engellenir.

Tarih davranışı:

- Google günlük mod: T-1
- Apple günlük mod: T-1
- Backfill bitiş tarihi belirtilmezse T-1

Airflow DAG'leri:

- `S3'e atılacaklar/airflow-dags/google_reports_airflow_dag.py`
- `S3'e atılacaklar/airflow-dags/apple_reports_airflow_dag.py`

### 2.3 Airflow Variable alanları

Google:

- `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`
- `GOOGLE_PLAY_BUCKET_NAME`
- `FINANCE_BQ_PROJECT_ID`
- `FINANCE_BQ_DATASET`
- `GOOGLE_PLAY_BQ_TABLE`

Apple:

- `APPLE_CONNECT_ISSUER_ID`
- `APPLE_CONNECT_KEY_ID`
- `APPLE_CONNECT_PRIVATE_KEY`
- `APPLE_VENDOR_NUMBER`
- `FINANCE_BQ_PROJECT_ID`
- `FINANCE_BQ_DATASET`
- `APPLE_SUBSCRIBER_BQ_TABLE`

Credential değerleri kaynak koda gömülmemelidir.

---

## 3. Slack Bildirimleri

Airflow connection:

- Connection ID: `slack_default`
- Connection type: Slack Incoming Webhook
- Webhook endpoint: `https://hooks.slack.com/services`
- Webhook token alanına URL'nin `/services/` sonrasındaki gizli bölümü yazılır.
- Hedef kanal: `#airflow_notify`

Callback dosyası:

- `S3'e atılacaklar/airflow-dags/slack_callbacks.py`

Bu dosya DAG dosyalarıyla aynı Airflow DAG klasörüne/S3 DAG konumuna
gönderilmelidir.

Bildirim davranışı:

- Başarı: DAG, task, run, satır sayısı, hedef tablo, süre ve log bağlantısı
- Hata: `<!channel>`, hata özeti, son deneme sayısı ve log bağlantısı
- Slack hatası ana Airflow task'ını başarısız yapmaz; loglanır.

Slack callback uygulanan S3 DAG'leri:

- Google
- Apple
- TCMB
- Kids identifier
- Param
- Iyzico
- Nkolay
- Payguru
- BO profile count

Airflow requirements dosyası sistemdeki mevcut yanlış yazımla:

- `S3'e atılacaklar/requeriments.txt`

İçinde gerekli başlıca paketler:

- `apache-airflow-providers-slack`
- `apache-airflow-providers-google`
- `google-cloud-bigquery`
- `google-auth`
- `PyJWT[crypto]`
- Diğer mevcut provider ve yardımcı paketler

---

## 4. Finans Tarafında Kabul Edilen Temel Tanımlar

### 4.1 Tutar birimi

Backoffice `amount` alanı kuruş bazlıdır.

Test çekimini dışlamak için doğru sabit filtre:

```sql
COALESCE(amount, amount_before_promotions, 0) > 101
```

`> 1.01` kullanılması yanlıştır.

### 4.2 Vergi

Finans Looker SQL'lerinde vergi düşülmeyecektir.

Net tanımı:

```text
Net = Brüt tutar - ödeme kuruluşu komisyonu
```

Vergi/KDV düşümü net hesabına dahil değildir.

### 4.3 Komisyon oranları

- App Store: `%30`
- Play Store: `%15`
- Mobile Payment / Payguru: `%15`
- Iyzico: `%3`
- Craftgate: `%0`, yalnız legacy görünüm için

Param güncelde kullanılmıyor.

Craftgate ayrı bir ödeme kuruluşu gibi değerlendirilmemeli; geçmişte Iyzico ve
Param'ı tek panelden gösteren legacy yapıydı.

Nkolay konusunda finans tarafının netleştirmesi gereken noktalar olabilir.

### 4.4 Ücretli abone

Bir kullanıcı, ilgili gün:

```text
created_at <= gün <= valid_until
```

koşulunu sağlıyorsa ücretli abone kabul edilir.

Statü yorumu:

- `ACTIVE`: ücretli
- `CANCELED`: yenilemeyi kapatmış ama `valid_until` gelmemişse ücretli
- `IN_GRACE`: ödeme alınamamış, kayıp eşiğinde
- `ON_HOLD`: ödeme alınamamış, kayıp eşiğinde
- `EXPIRED`: kaybedilmiş

Finans kayıp tanımı:

- `EXPIRED`
- `IN_GRACE`
- `ON_HOLD`

Dashboard terminolojisi “Aktif Abone” yerine “Ücretli Abone” olarak
kullanılmalıdır.

### 4.5 MRR ve tahsilat

MRR:

- Bir tarih snapshot'ındaki ücretli abonelerin aylık tekrar eden gelir kapasitesi
- Ödeme günü bazlı nakit akışı değildir.

Tahsilat:

- Gerçek ödeme event'lerinin ödeme tarihinde oluşan nakit akışı

Bu iki rakam aynı olmak zorunda değildir.

Ayrıntılı alan eşleştirmesi:

- `looker_sqls/FINANCE_METRIC_GUIDE.md`

---

## 5. Birinci Dashboard Sayfası

Ana veri kaynakları:

- `BC_UNIT_ECONOMICS_DAILY_01`
- `BC_FORECAST_LTV_MONTHLY_01`
- `BC_REALIZED_LTV_MONTHLY_01`
- `BC_CAC_MONTHLY_01`
- `BC_LTVCAC_REALIZED_MONTHLY_01`
- `BC_WATCHER_LTV_02`
- `BC_PAYMENT_METHOD_DISTRIBUTION_01`
- `BC_HEAVY_PAYMENT_DISTRIBUTION_01`

### 5.1 Unit economics

Dosya:

- `looker_sqls/BC_UNIT_ECONOMICS_DAILY_01.sql`

Önemli metrikler:

- `net_mrr_previous_month_end_tl`
- `net_mrr_selected_end_tl`
- `previous_month_net_collections_tl`
- `trailing_30d_net_collections_tl`
- `selected_period_net_collections_tl`
- `selected_period_transaction_count`
- `paid_subscribers`
- `monthly_net_arpu_tl`
- `selected_period_net_arpu_tl`

ARPU evreni:

- Tüm ücretli abone portföyü
- Komisyon sonrası tahakkuk gelirinin ortalama ücretli aboneye bölümü

Bu ARPU, reklam cohort ARPU'suyla aynı evren değildir.

25 Haziran 2026 testinde, 28 Mayıs–24 Haziran aralığı için:

- `selected_period_net_arpu_tl`: yaklaşık `₺193,08`
- Looker ekranında tarih seçimine göre yaklaşık `₺206` görülebilir.

### 5.2 Forecast LTV

Dosya:

- `looker_sqls/BC_FORECAST_LTV_MONTHLY_01.sql`

Formül:

```text
Tamamlanmış ay net ARPU / önceki 3 tamamlanmış ay ortalama kayıp oranı
```

### 5.3 Realized LTV

Dosya:

- `looker_sqls/BC_REALIZED_LTV_MONTHLY_01.sql`

Gerçekleşmiş, komisyon sonrası ödeme event'leri kullanılır.

### 5.4 Watcher Heavy/Light LTV

Dosyalar:

- `looker_sqls/BC_WATCHER_LTV_02.sql`
- `looker_sqls/BC_HEAVY_PAYMENT_DISTRIBUTION_01.sql`

Kabul edilen son mantık:

- İlk 30 günlük izleme davranışıyla Heavy/Light ayrımı
- En az 3 aylık gözlem süresi
- İlk 3 aylık realized LTV
- Churn eden kullanıcılar LTV analizine dahildir.
- Heavy ödeme aracı dağılımı current-state ücretli Heavy kullanıcıları gösterir.

Grafik adı:

```text
İlk 3 Aylık Realized LTV - Heavy vs Light
```

---

## 6. CAC, LTV/CAC ve Payback Ayrımı

Bu bölüm kritik; aynı isimle farklı evrenlerin karıştırılması engellenmelidir.

### 6.1 Genel portföy ARPU

Kaynak:

- `BC_UNIT_ECONOMICS_DAILY_01`

Evren:

- Tüm ücretli aboneler

Önerilen alan:

- `selected_period_net_arpu_tl`

### 6.2 Reklam cohort CAC

Kaynaklar:

- `BC_CAC_MONTHLY_01`
- `BC_LTVCAC_REALIZED_MONTHLY_01`

Evren:

- İlk ücretli ödemesinden önceki 30 günde uygun paid touch bulunan kullanıcılar
- Aynı acquisition ayı
- Google, Meta ve TikTok ücretli kanal attribution'ı
- Üç aylık analizlerde gözlem süresini tamamlayan cohort

### 6.3 Payback için kullanılan aylık gelir

`BC_LTVCAC_REALIZED_MONTHLY_01` içindeki eski `arpu_tl` alanı gerçek genel ARPU
değildir.

Gerçek anlamı:

```text
İlk 3 aylık realized LTV / 3
```

Yeni açıklayıcı alan:

- `cohort_monthly_realized_revenue_tl`

Eski Looker uyumluluğu için `arpu_tl` alias'ı korunmuştur.

### 6.4 Son doğrulanan rakamlar

Son olgun cohort: Şubat 2026

- Reklama atfedilmiş yeni ücretli kullanıcı: `1.568`
- Toplam reklam harcaması: `₺207.587,43`
- Cohort CAC: `₺132,39`
- İlk 3 aylık realized LTV: `₺850,11`
- Cohort aylıklaştırılmış gelir: `₺283,37`
- LTV/CAC: `6,42`
- CAC payback: `0,47 ay`

Formüller:

```text
CAC = 207.587,43 / 1.568 = 132,39
LTV/CAC = 850,11 / 132,39 = 6,42
Payback = 132,39 / 283,37 = 0,47 ay
```

`₺206` civarındaki genel portföy ARPU, bu payback formülünde
kullanılmamalıdır.

### 6.5 Attribution veri kalitesi riski

Şubat 2026:

- Toplam ilk ücretli kullanıcı: `8.515`
- Paid kanala bağlanabilen kullanıcı: `1.568`
- Attribution coverage: yaklaşık `%18,4`

Meta:

- Harcama yaklaşık `₺63.615`
- Attributed paid user yalnız `2`

Google:

- Attributed paid user `1.566`

Bu nedenle blended `₺132,39` matematiksel olarak doğrudur; fakat Meta
attribution verisi eksik olduğu için finansal yorumda veri kalite uyarısıyla
kullanılmalıdır.

Looker CAC payback kartı:

- Veri kaynağı: `BC_LTVCAC_REALIZED_MONTHLY_01`
- Metrik: `MAX(cac_payback_period)`
- Filtre: `is_latest_mature_month = true`

LTV/CAC kartı:

- Metrik: `MAX(ltv_cac_ratio)`
- Filtre: `is_latest_mature_month = true`

---

## 7. İkinci Dashboard Sayfası - Reklamlı Finansal Performans

Kesin kaynak eşleştirmesi:

- Geriye Dönük Analiz:
  `BC_LTVCAC_REALIZED_MONTHLY_01`
- Reklam Kanalı LTV:
  `BC_CHANNEL_LTVCAC_REALIZED_01`
- Reklam Kanalı Aylık CAC:
  `BC_CAC_MONTHLY_01`
- Reklam Kanalı CAC:
  `BC_CAC_MONTHLY_01`
- Reklam Kanalı LTV/CAC:
  `BC_CAC_MONTHLY_01`

Detaylı Looker kurulumu:

- `looker_sqls/SECOND_PAGE_LOOKER_SETUP.md`

İkinci sayfa kullanıcı tarafından tamamlandı olarak işaretlendi.

Ancak reklam backfill tamamlandıktan sonra yeniden doğrulanması gerekenler:

- En az 6 olgun cohort ayının görünmesi
- Meta ve Google harcama kapsaması
- Kanal bazında attributed user sayıları
- Meta CAC'ın aşırı yükselip yükselmediği
- TikTok satırının gerçekten veri olup olmadığı
- `all_channels`/blended değerlerin kanal değerleriyle tutarlılığı

---

## 8. Reklam Harcaması Backfill

Hedef dönem:

```text
1 Temmuz 2025 - 23 Haziran 2026
```

Kaynaklar:

- Google Ads BigQuery Data Transfer
- Meta Ads BigQuery Data Transfer

Hedef tablo:

- `microgain-9f959.bc_marketing_marts.ads_daily_spend`

Üretim SQL:

- `looker_sqls/BC_ADS_DAILY_SPEND_UNIFIED_01.sql`

Idempotent backfill MERGE:

- `looker_sqls/BC_ADS_DAILY_SPEND_UNIFIED_BACKFILL.sql`

Lokal runner:

- `Random_Test_Scripts/run_ads_backfill_local.sh`

Yardımcı scriptler:

- `Random_Test_Scripts/accelerate_ads_backfill.sh`
- `Random_Test_Scripts/queue_ads_backfill_remaining.sh`

Runner davranışı:

- `start` mevcut terminalde foreground çalışır.
- Terminal kapanırsa veya `Ctrl+C` yapılırsa durur.
- Gizli/background worker başlatmaması hedeflenmiştir.

### 8.1 25 Haziran 2026, yaklaşık 15:09 durumu

Çalışan süreçler:

- `run_ads_backfill_local.sh start`
- Meta accelerator
- Google accelerator

Accelerator logundaki son yaklaşık durum:

- Meta: `172/358` civarı
- Google: `186/358` civarı

`ads_daily_spend` hedef tablosundaki mevcut durum:

- Google yüklü gün: `141`
- Meta yüklü gün: `175`
- Duplicate key group: `0`
- Excess row: `0`

Hedef tablo henüz backfill açısından tamamlanmış değildir.

Önemli:

- Worker kullanıcı terminalinde çalışmaktadır.
- Bu devir notu hazırlanırken worker başlatılmamış veya durdurulmamıştır.
- Transferler tamamlanınca güvenli MERGE ve final doğrulama yapılmalıdır.

---

## 9. Üçüncü Dashboard Sayfası - Kampanya Ekonomisi

Ana kaynak:

- `looker_sqls/BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02.sql`

Organik/kampanya ayrımı:

- `cohort_type_key = normal`
- `cohort_type_key = campaign`

Eski `cohort_type` alanı uyumluluk için korunmuştur.

Doğru scorecard mantıkları:

- Realized LTV:
  `AVG(terminal_realized_ltv_anchor_tl)`
- Aylık ARPU:
  `SUM(actual_net_revenue_tl) / SUM(active_flag)`
- CAC:
  `AVG(cac_user_anchor_tl)`
- Payback:
  `CAC / aylık ARPU`
- LTV/CAC:
  `Realized LTV / CAC`

Grafikler:

- Aylık Net Tahsilat:
  `SUM(actual_net_revenue_tl)`
- Kümülatif kullanıcı başı LTV:
  `AVG(cum_actual_ltv_tl)`
- Aylık müşteri kayıp oranı:
  `SUM(churn_event_flag) / SUM(churn_risk_flag)`
- Kümülatif kaybedilmiş payı:
  `AVG(cumulative_inactive_flag)`

`0,32` aylık churn değeri:

```text
O lifetime ayında churn riskinde olan kullanıcıların %32'si kaybedilmiş.
```

Bu değer kümülatif churn değildir.

Üçüncü sayfa genel kampanya ekonomisi ekranı entegre edildi; görsel kontrol
yapıldı. Son özel çalışma `BC_3MONTH_CAMPAING` ekranına kaydı.

---

## 10. BC_3MONTH_CAMPAING Son Durumu

Dosya:

- `looker_sqls/BC_3MONTH_CAMPAING.sql`

Bulunan ve düzeltilen sorunlar:

- Kullanıcının gerçek kampanya başlangıcında `applyDate` yerine yanlışlıkla
  subscription `created_at` kullanılması
- Bir kullanıcının birden fazla promosyon geçmişinin tek kayda düşmesi
- Birden fazla kampanyaya katılan kullanıcının izleme verisinin yanlış
  kampanyaya çoğalabilmesi
- İzlemeyen kullanıcıların platform dağılımında `Unknown` olarak ağırlığı
  bozması
- Platform bazlı ortalamaların Looker'da toplanması
- Streaming kaynağı olmayan günlerin gerçek sıfır gibi gösterilmesi
- T-1 üst sınırının eksik olması

Eklenen alanlar:

- `selected_period_platform_users`
- `daily_unique_watchers_anchor`
- `daily_measured_watchers_anchor`
- `daily_total_watch_time_anchor`
- `daily_avg_user_watch_time_anchor`
- `streaming_data_available`
- `streaming_source_event_rows`
- `streaming_source_measured_rows`

Looker platform simidi:

- Boyut: `platform`
- Metrik: `SUM(selected_period_platform_users)`
- Grafik özel “Dün” filtresi kullanmamalı; sayfa tarih filtresini devralmalı.

Tekil izleyici:

- `SUM(daily_unique_watchers_anchor)`

Ortalama izleme:

- `MAX(daily_avg_user_watch_time_anchor)`
- Etiket:
  “Ölçülebilen İzleyici Başına Ortalama İzleme Süresi”

### 10.1 Doğrulanan platform dağılımı

Seçili geniş dönem GAIN3AY:

- Web: `4.625`
- iOS: `982`
- TV: `945`
- Android: `706`

### 10.2 Bilinen upstream streaming sorunları

Streaming kaynağında tamamen eksik görülen bazı günler:

- 24 Haziran 2026
- 23 Haziran 2026
- 19 Haziran 2026
- 17 Haziran 2026
- 2 Haziran 2026
- 1 Haziran 2026
- 15 Mayıs 2026
- 10 Nisan 2026

Android ve iOS event'leri bulunmasına rağmen `watch_time_second` çoğunlukla
boştur. Bu nedenle:

- Tekil izleyici event üzerinden hesaplanabilir.
- Gerçek platformlar arası ortalama izleme süresi hesaplanamaz.
- SQL eksik süreyi uydurmaz.

---

## 11. Ödeme Kuruluşu Finans Ekranı

İlk hedeflerden biri, BO verisini kullanmadan yalnız ödeme kuruluşlarının raw
verilerinden ayrı finans ekranı oluşturmaktı.

Bu kapsamda ilk 5 KPI için ödeme kuruluşu bazlı scorecard SQL'i yazıldı.

Dosya:

- `looker_sqls/BC_PAYMENT_PROVIDER_KPIS_01.sql`

Bu SQL Backoffice/subs_payment kullanmaz; yalnız provider raw tablolarından
hesap yapar.

Looker'da kullanılacak KPI alanları:

- Brüt Tahsilat Tutarı - Geçen Ay:
  `previous_month_gross_collections_tl`
- Net Tahsilat Tutarı - Geçen Ay:
  `previous_month_net_collections_tl`
- İşlem Adedi - Geçen Ay:
  `previous_month_transaction_count`
- Seçilen Aralıktaki Net Tahsilat:
  `selected_period_net_collections_tl`
- Seçilen Aralıktaki İşlem Adedi:
  `selected_period_transaction_count`
- Opsiyonel işlem başına ortalama net gelir:
  `selected_period_avg_net_per_transaction_tl`

Looker scorecard aggregation:

- Hepsi için `MAX`

Önemli isimlendirme:

- İlk KPI “MRR” olarak adlandırılmamalı.
- Provider raw işlemleri gerçek abonelik MRR snapshot'ı üretmez.
- Doğru isim:
  “Brüt Tahsilat Tutarı - Geçen Ay”

### 11.1 Provider KPI kapsamındaki kaynaklar

KPI SQL'ine dahil edilen kaynaklar:

- Apple / App Store
- Google Play
- Iyzico
- Payguru / Mobil Ödeme

Kapsam dışı:

- Param
- Nkolay
- Craftgate

Craftgate legacy panel olduğu için provider KPI evrenine ayrıca eklenmedi.

### 11.2 Provider KPI kuralları

Apple:

- Brüt: `customer_price * units`
- Net: `developer_proceeds * abs(units)`
- Döviz varsa TCMB kuru
- Refund satırları negatif net/gross etkiyle hesaba alınır.

Google:

- Brüt: `charged_amount`
- Net: `charged_amount * 0.85`
- `charged_amount` vergi dahil kabul edildi.
- Eğer finans eski rapordaki vergi hariç Google tutarını isterse
  `item_price` kullanılmalı; fakat bu daha önce alınan “vergi düşülmeyecek”
  kararına ters düşer.

Iyzico:

- Payment:
  brüt `amount`, net `merchant_payout_amount`
- Cancel/refund:
  eşleşen payment satırının gerçek payout oranıyla negatif net etki
- Payout yoksa fallback `%3` komisyon

Payguru:

- Success:
  `status = 3 AND amount > 1.01 AND currency = TRY`
- Failure:
  `status IN (4, 5, 8, 9)`
- `status = 6`:
  gelir/işlem hesabına dahil edilmez; eldeki örnekte `0.01` lifecycle/reversal
  benzeri kayıt gibi duruyor.
- Brüt: `amount`
- Net: `amount * 0.85`

Payguru için önemli not:

- Eski finans dosyasındaki “hesaba yatan tutar” Mayıs 2026'da yaklaşık
  `₺612.991` iken provider KPI neti yaklaşık `₺1.130.634`.
- Bu fark `%15` komisyonla açıklanamaz.
- Gerçek banka yatışını eşleştirmek için Payguru settlement/banka tablosu veya
  operatör/servis bazlı payout oranları gerekir.
- Şimdilik KPI SQL'i “komisyon düşülmüş tahmini net” üretir; “bankaya yatan
  kesin tutar” olarak sunulmamalıdır.

### 11.3 Son doğrulanan provider KPI testi

Test aralığı:

```text
26 Mayıs 2026 - 24 Haziran 2026
```

Dry-run ve full query başarılıdır.

Seçili dönem sonuçları:

- Dahil provider sayısı: `4`
- Provider listesi:
  `Apple / App Store, Google Play, Iyzico, Payguru / Mobil Ödeme`
- Geçen ay brüt tahsilat:
  yaklaşık `₺32,10 Mn`
- Geçen ay net tahsilat:
  yaklaşık `₺25,32 Mn`
- Geçen ay işlem adedi:
  `128.667`
- Seçili dönem net tahsilat:
  yaklaşık `₺22,09 Mn`
- Seçili dönem işlem adedi:
  `112.186`
- Seçili dönem işlem başına ortalama net gelir:
  yaklaşık `₺196,95`

Mayıs 2026 provider kırılımı:

| Provider | İşlem | Brüt | Net |
|---|---:|---:|---:|
| Apple / App Store | 58.126 | ₺14.932.611,71 | ₺9.216.978,93 |
| Google Play | 13.624 | ₺3.363.572,14 | ₺2.859.036,32 |
| Iyzico | 51.575 | ₺12.478.386,75 | ₺12.116.310,03 |
| Payguru / Mobil Ödeme | 5.342 | ₺1.330.158,00 | ₺1.130.634,30 |

Eski aylık finans raporuyla fark yorumları:

- Payguru brüt ve işlem adedi birebir tutuyor; net banka yatışı tutmuyor.
- Iyzico eski rapordaki “ödeme paneli toplam ücret” gross değil, net/payout
  mantığına çok yakın görünüyor.
- Google eski rapor muhtemelen `item_price` yani vergi hariç tutara bakıyordu.
- Apple eski rapor güncel raw snapshot ile birebir aynı evrende değil; geç
  gelen adjustment, FX ve refund etkileri olabilir.

İstenen günlük tablo:

- Tarih
- Ödeme kuruluşu
- İşlem adedi
- Brüt gelir
- Komisyon düşülmüş/net gelir
- İşlem başına ortalama net gelir
- Seçili tarih aralığında kümülatif işlem adedi
- Seçili tarih aralığında kümülatif net tutar

Ayrıca:

- Her ödeme kuruluşunu ayrı listeleyen indirme sayfası
- Bu ayrı listede kümülatif alan gerekmiyor.
- Apple, Google, Iyzico, Payguru ve kullanılabilir diğer kuruluşlar
- Başarılı ödeme, başarısız ödeme ve refund durumlarının normalize edilmesi
- Tüm kaynaklarda `> 101` test ödeme filtresi
- Dövizli işlemlerde TCMB kuru
- Dedupe
- Son iki yıllık backfill

Bu ödeme kuruluşu birleşik finans martı ve Looker sayfası henüz tamamlanmadı.
İlk 5 KPI SQL'i tamamlandı; günlük detay/pivot martı ayrıca yapılacak.

---

## 12. Güncel Kalan İş Listesi

Aşağıdaki sıra önerilen çalışma sırasıdır.

### P0 - Devam eden işi güvenli biçimde bitir

- [ ] Meta ve Google Ads backfill'in tamamlanmasını bekle.
- [ ] Her kanal için `358/358` transfer günü başarı kontrolü yap.
- [ ] `BC_ADS_DAILY_SPEND_UNIFIED_BACKFILL.sql` MERGE çalıştır.
- [ ] `ads_daily_spend` içinde:
  - eksik gün
  - duplicate key
  - raw/target tutar farkı
  kontrollerini yap.
- [ ] Final doğrulama JSON/log sonucunu kaydet.

### P1 - CAC ve attribution hesaplarını backfill sonrası yeniden doğrula

- [ ] `BC_CAC_MONTHLY_01` sonuçlarını Temmuz 2025'ten itibaren yeniden çalıştır.
- [ ] `BC_CHANNEL_LTVCAC_REALIZED_01` sonuçlarını yeniden çalıştır.
- [ ] `BC_LTVCAC_REALIZED_MONTHLY_01` sonuçlarını yeniden çalıştır.
- [ ] Son 6 olgun cohort ayının görünmesini doğrula.
- [ ] Meta attributed user sayısının neden aşırı düşük olduğunu araştır.
- [ ] GA4 paid touch attribution kapsamını aylık ve kanal bazında raporla.
- [ ] TikTok attribution'ın gerçek reklam aktivitesinden mi, eski touch
  kayıtlarından mı geldiğini doğrula.
- [ ] CAC kartında görülen yaklaşık `₺154` değerin Looker filtre/scope kaynağını
  tespit et.
- [ ] Genel portföy ARPU ile cohort aylıklaştırılmış gelirin dashboard
  etiketlerini birbirinden ayır.

Önerilen adlar:

- Genel ARPU:
  “Ücretli Abone Başına Aylık Net Gelir”
- Cohort payback paydası:
  “İlk 3 Ay Aylıklaştırılmış Cohort Geliri”

### P2 - Birinci ve ikinci sayfa son Looker kontrolü

- [ ] Looker veri kaynaklarında “Alanları yenile” çalıştır.
- [ ] CAC Payback:
  `MAX(cac_payback_period)` +
  `is_latest_mature_month = true`
- [ ] LTV/CAC:
  `MAX(ltv_cac_ratio)` +
  `is_latest_mature_month = true`
- [ ] Geriye Dönük Analiz tablosunda birden fazla olgun ayın görünmesini kontrol et.
- [ ] İkinci sayfa kartlarını backfill sonrası ekran görüntüsüyle tekrar kıyasla.
- [ ] `SECOND_PAGE_LOOKER_SETUP.md` içindeki tarih filtresi açıklamasını son SQL
  davranışıyla eşitle.

### P3 - BC_3MONTH_CAMPAING Looker entegrasyonu

- [ ] SQL'i Looker veri kaynağına yeniden yapıştır.
- [ ] Alanları yenile.
- [ ] Platform simidini `selected_period_platform_users` alanına geçir.
- [ ] Simitteki özel “Dün” filtresini kaldır.
- [ ] Tekil izleyici kart ve tablosunu anchor alana geçir.
- [ ] Ortalama izleme süresini measured anchor alana geçir.
- [ ] Eksik streaming günlerini `0` değil veri eksikliği olarak göster.
- [ ] Upstream ekibe mobil/TV `watch_time_second` eksikliğini ilet.

### P4 - Üçüncü sayfa son kontrolleri

- [ ] Kampanya ekonomisi sayfasındaki filtrelerin organik baseline'ı yanlışlıkla
  dışlamadığını kontrol et.
- [ ] `BC_3MONTH_CAMPAING` sonrası kampanya performans sayfasını tekrar görsel
  olarak doğrula.
- [ ] Günlük kampanya detayındaki eksik streaming günlerini kullanıcıya
  açıklayan gösterim ekle.

### P5 - Ödeme kuruluşu finans martı ve Looker sayfası

- [x] Provider-only ilk 5 KPI SQL'ini yaz.
- [x] Apple, Google, Iyzico ve Payguru'yu KPI SQL'ine dahil et.
- [x] Payguru success/failure/status 6 kararını KPI SQL'ine işle.
- [x] Iyzico refund/cancel net etkisini gerçek payout oranıyla hesapla.
- [x] Google için vergi dahil `charged_amount` kararını uygula.
- [x] Apple ve Google döviz dönüşümünü TCMB kuru ile uygula.
- [x] KPI SQL'i için dry-run ve örnek full query testi çalıştır.
- [ ] Provider KPI alanlarını Looker'daki 5 scorecard'a işle.
- [ ] Payguru için gerçek banka yatışını verecek settlement/payout kaynağını
  finanstan netleştir.
- [ ] Net alanında tahmin içeren provider'ları dashboard'da not olarak belirt.
- [ ] Unified payment transaction mart SQL'i yaz.
- [ ] Günlük ödeme kuruluşu pivot tablosunu oluştur.
- [ ] Seçili dönem kümülatif işlem/net tutar alanlarını ekle.
- [ ] Kuruluş bazlı indirilebilir detay sayfasını oluştur.
- [ ] Provider mart için dedupe testlerini çalıştır.

### P6 - İki yıllık ödeme verisi backfill

- [ ] Google Play iki yıllık backfill
- [ ] Apple iki yıllık backfill
- [ ] Iyzico iki yıllık backfill
- [ ] Payguru iki yıllık backfill
- [ ] Kullanılacaksa Nkolay kurallarını finanstan netleştirip backfill
- [ ] Günlük kapsama, duplicate ve tutar reconciliation kontrolü

### P7 - Airflow production son kontrolü

- [ ] Google ve Apple T-1 DAG'lerini Airflow'da manuel tetikle.
- [ ] BigQuery'de aynı tarih için duplicate oluşmadığını doğrula.
- [ ] Slack success mesajını doğrula.
- [ ] Kontrollü hata testiyle `<!channel>` failure mesajını doğrula.
- [ ] Tüm S3 DAG'leriyle birlikte `slack_callbacks.py` yüklendiğini kontrol et.
- [ ] Airflow Variable ve connection isimlerini production ortamıyla karşılaştır.

### P8 - Repo temizliği ve dokümantasyon

- [ ] Dirty worktree içindeki 19 değiştirilmiş SQL'i konu bazında review et.
- [ ] Geçici/test SQL ve scriptlerini production dosyalarından ayır.
- [ ] `requeriments.txt` yanlış adı sistem bağımlılığı değilse ileride düzelt.
- [ ] `variables.json` ve `token_store.json` gibi credential içerebilecek
  dosyaların Git'e girmediğini doğrula.
- [ ] SQL rehberlerini mevcut SQL alanlarıyla senkronize et.
- [ ] Kontrollü commit'ler oluştur.

---

## 13. Tamamlandı Kabul Edilen İşler

- [x] Google ve Apple raw BigQuery tablo SQL'leri
- [x] Lokal CSV / Airflow BigQuery çalışma ayrımı
- [x] S3 scriptlerinden `dotenv` kaldırılması
- [x] Google ve Apple T-1 çalışma mantığı
- [x] Airflow Variable tabanlı credential aktarımı
- [x] Slack Incoming Webhook bağlantı tasarımı
- [x] Ortak Slack callback dosyası
- [x] S3 DAG'lerine success/failure callback eklenmesi
- [x] Vergi düşümünün finans SQL'lerinden kaldırılması
- [x] Kuruş bazlı `> 101` test işlem filtresi
- [x] Ücretli abone tanımı
- [x] MRR/tahsilat ayrımı
- [x] Unit economics temel metrik düzeni
- [x] Forecast LTV mantığı
- [x] Realized LTV mantığı
- [x] Heavy/Light ilk 3 aylık LTV düzeni
- [x] Heavy ödeme aracı dağılımı
- [x] İkinci sayfa SQL/veri kaynağı eşleştirmesi
- [x] Üçüncü sayfa kampanya ekonomisi temel formülleri
- [x] Aylık churn grafiği tanımı
- [x] BC_3MONTH_CAMPAING ana SQL düzeltmeleri
- [x] Reklam harcaması idempotent MERGE backfill scripti
- [x] CAC payback'in son 28 gün filtre çatışmasının giderilmesi
- [x] Genel ARPU ile cohort aylıklaştırılmış gelirin ayrıştırılması
- [x] Provider-only ilk 5 KPI SQL'i
- [x] Provider KPI'lara Payguru dahil edilmesi
- [x] Payguru status kararları:
  success `3`, failure `4/5/8/9`, exclude `6`
- [x] Provider KPI'larda Apple/Google/Iyzico/Payguru normalization
- [x] Provider KPI test ve Mayıs 2026 reconciliation analizi

---

## 14. Bilinen Kritik Riskler

### Reklam attribution

Attribution coverage düşüktür. Özellikle Meta kullanıcı eşleşmesi harcamaya göre
çok azdır. CAC ve LTV/CAC rakamları attribution düzelmeden “kesin finans
gerçeği” olarak sunulmamalıdır.

### Streaming

Bazı günler kaynakta hiç streaming verisi yoktur. Mobil ve TV
`watch_time_second` alanları da eksiktir. SQL bu eksikliği tamir edemez.

### Dirty worktree

Repo içinde kullanıcıya ait çok sayıda değişiklik vardır. Toplu revert/reset
yapılmamalıdır.

### Looker cache ve eski calculated field'lar

SQL değişse bile Looker eski alanı veya calculated field'ı kullanıyor olabilir.
Her değişiklik sonrası veri kaynağında alan yenilemek ve grafik metriklerini
tek tek kontrol etmek gerekir.

---

## 15. Sonraki Oturum İçin Hazır Başlangıç Mesajı

Aşağıdaki metin yeni Codex oturumuna doğrudan verilebilir:

```text
GAIN 215 Finans Dashboard çalışmasına devam ediyoruz.

Önce şu dosyayı tamamen oku:
Agent Logs/GAIN_215_FINANS_DASHBOARD_DEVIR_NOTU.md

Repo dirty; mevcut değişiklikleri silme veya resetleme.

Öncelik:
1. Devam eden Meta/Google Ads backfill durumunu sadece kontrol et.
2. Tamamlandıysa idempotent MERGE ve eksik gün/duplicate doğrulamasını yap.
3. Sonra BC_CAC_MONTHLY_01, BC_CHANNEL_LTVCAC_REALIZED_01 ve
   BC_LTVCAC_REALIZED_MONTHLY_01 sonuçlarını yeniden test et.
4. Genel portföy ARPU ile cohort aylıklaştırılmış geliri karıştırma.
5. Açık iş listesindeki sırayı koru.
```

---

## 16. İlgili Ana Dosyalar

Finans rehberi:

- `looker_sqls/FINANCE_METRIC_GUIDE.md`

İkinci sayfa Looker rehberi:

- `looker_sqls/SECOND_PAGE_LOOKER_SETUP.md`

Birinci sayfa:

- `looker_sqls/BC_UNIT_ECONOMICS_DAILY_01.sql`
- `looker_sqls/BC_FORECAST_LTV_MONTHLY_01.sql`
- `looker_sqls/BC_REALIZED_LTV_MONTHLY_01.sql`
- `looker_sqls/BC_CAC_MONTHLY_01.sql`
- `looker_sqls/BC_LTVCAC_REALIZED_MONTHLY_01.sql`
- `looker_sqls/BC_WATCHER_LTV_02.sql`
- `looker_sqls/BC_PAYMENT_METHOD_DISTRIBUTION_01.sql`
- `looker_sqls/BC_HEAVY_PAYMENT_DISTRIBUTION_01.sql`

İkinci sayfa:

- `looker_sqls/BC_CHANNEL_LTVCAC_REALIZED_01.sql`
- `looker_sqls/BC_CAC_MONTHLY_01.sql`
- `looker_sqls/BC_LTVCAC_REALIZED_MONTHLY_01.sql`

Üçüncü sayfa:

- `looker_sqls/BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02.sql`
- `looker_sqls/BC_3MONTH_CAMPAING.sql`

Reklam harcaması:

- `looker_sqls/BC_ADS_DAILY_SPEND_UNIFIED_01.sql`
- `looker_sqls/BC_ADS_DAILY_SPEND_UNIFIED_BACKFILL.sql`
- `Random_Test_Scripts/run_ads_backfill_local.sh`
- `Random_Test_Scripts/accelerate_ads_backfill.sh`

Google/Apple:

- `google_random/google_transaction_combo.py`
- `apple_api_files/apple_monthly_reports.py`
- `S3'e atılacaklar/python_scripts/google_transaction_combo.py`
- `S3'e atılacaklar/python_scripts/apple_monthly_reports.py`
- `S3'e atılacaklar/airflow-dags/google_reports_airflow_dag.py`
- `S3'e atılacaklar/airflow-dags/apple_reports_airflow_dag.py`
- `S3'e atılacaklar/airflow-dags/slack_callbacks.py`
