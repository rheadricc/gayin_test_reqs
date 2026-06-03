# GAİN BigQuery & Analytics Technical Documentation v0.4

## 1. Doküman Amacı

Bu doküman GAİN Big Data / Analytics altyapısında BigQuery, Looker Studio, Scheduled Query, Data Transfer ve Airflow üzerinden çalışan güncel veri yapısını teknik ekipler için açıklamak amacıyla hazırlanmıştır.

Ana hedefler:

- BigQuery üzerinde aktif kullanılan dataset ve tabloların ne işe yaradığını açıklamak.
- Ödeme, abonelik, içerik izleme, kampanya, pazarlama ve unit economics analizlerinin hangi kaynaklardan beslendiğini göstermek.
- Looker Studio dashboard'larında görünen KPI, grafik ve tabloların hangi SQL / datasource üzerinden geldiğini belgelemek.
- Yeni bir analyst veya developer ekibe katıldığında, hangi verinin nereden geldiğini ve hangi join / mapping mantığıyla kullanıldığını anlayabilmesini sağlamak.
- Kritik business logic, edge case ve tribal knowledge bilgisini merkezi hale getirmek.

Bu doküman teknik ekipleri hedefler. Bu nedenle metrikler, tablo isimleri, SQL kaynakları, join mantıkları ve veri pipeline detayları teknik seviyede açıklanır.

---

## v0.2 Değişiklik Özeti

Bu versiyonda CAC / LTV BigQuery standardizasyon çalışmasından gelen kararlar dokümana işlendi.

Öne çıkan değişiklikler:

- CAC spend source standardı aktif veri akışı olan `bc_marketing_marts.ads_daily_spend` olarak güncellendi.
- `bc_marketing_raw.manual_monthly_spend` legacy / historical source olarak işaretlendi; güncel reklam spend akışının Google/Meta raw transferlarından `ads_daily_spend` tablosuna aktığı netleştirildi.
- CAC denominator tanımı netleştirildi: ilk kez ücretli olan kullanıcılar içinden, ilk ödeme tarihinden önceki son 30 günde eligible paid/non-direct touch alan kullanıcılar.
- Attribution modeli `last eligible touch within 30 days before first payment` olarak dokümante edildi.
- Channel normalization mapping'i eklendi.
- `cac_status` alanının anlamı eklendi.
- Looker Studio ratio aggregation notları eklendi.
- `BC_CHANNEL_LTVCAC_REALIZED_01` için `channel_scope` filtre kullanımı eklendi.
- `ga4_first_non_direct_touch` tablosunun gerçek last-touch attribution için sınırlı olabileceği belirtildi.
- Gelecekte oluşturulması önerilen `bc_marketing_marts.ga4_last_paid_touch_30d` mart'ı eklendi.
- Category LTV ve Forecast LTV'nin realized monthly LTV ile birebir aynı basis'te olmadığı daha açık anlatıldı.

---

## v0.3 Değişiklik Özeti

Bu versiyonda High Level Data Architecture bölümü metin bazlı `mermaid` akışından çıkarılarak güncel hibrit sistem/veri mimarisi görseliyle değiştirildi.

Öne çıkan değişiklikler:

- Client / uygulama katmanından hem REST/Core tarafına hem de 3rd Party platformlara giden iki ayrı veri çıkışı netleştirildi.
- REST/Core kaynaklı operational stream ile 3rd Party kaynaklı analytics stream ayrı Kinesis kolları olarak gösterildi.
- REST/Core → Kinesis → Lambda → AWS S3 akışı ile 3rd Party → Kinesis → AWS S3 akışı ayrıştırıldı.
- AWS S3 sonrası Airflow, Python Jobs, BigQuery Scheduled Queries ve BigQuery katmanı üzerinden dataset/table modeline geçiş açıklandı.
- BigQuery güncel primary data warehouse olarak, Redshift ise legacy/secondary bileşen olarak konumlandırıldı.
- Katman açıklamaları yeni mimari akış metodolojisine göre yeniden yazıldı.

---

## v0.4 Değişiklik Özeti

Bu versiyonda dokümanın export/PDF-DOCX çıktısında görünmeyen Looker Mapping bölümü yeniden yapılandırıldı ve eski tekrar eden kalıntılar temizlendi.

Öne çıkan değişiklikler:

- `## 9. Looker Studio Dashboard Mapping` bölümü sayfa sayfa tek blok halinde yeniden düzenlendi.
- Sayfa 1–9 mapping akışı export çıktılarında görünecek şekilde ana doküman gövdesine taşındı.
- En altta kalan eski `Sayfa 1` ve `Sayfa 2` tekrarları temizlendi.
- Doküman versiyonu `v0.4` olarak güncellendi.

---

## 2. Kapsam

### Kapsam Dahilinde

- BigQuery dataset envanteri
- Kritik tablo katalogları
- Scheduled Query envanteri
- BigQuery Data Transfer job'ları
- Airflow DAG envanteri
- Looker Studio dashboard / KPI / SQL mapping
- Ödeme, abonelik, içerik izleme, kampanya ve unit economics metrikleri
- Data mapping ve join mantıkları
- Access / ownership modeli
- Known caveats ve veri kullanım notları

### Kapsam Dışında

- Tüm BigQuery dataset'lerinin tüm tablolarının tek tek açıklanması
- Airflow DAG dosyalarının çalıştırdığı Python script içeriklerinin detaylı kod analizi
- BigQuery IAM policy export'u
- Looker Studio calculated field'larının birebir UI export'u
- Backoffice / API servis kodlarının iç implementasyonu

---

## 3. High Level Data Architecture

![GAİN BigQuery & Analytics Hybrid High Level System & Data Architecture](/mnt/data/gai_n_bigquery_veri_mimarisi_diyagramı.png)

Bu görsel, GAİN veri mimarisini yalnızca BigQuery odaklı bir akış olarak değil; client uygulamaları, core sistemler, 3rd party platformlar, streaming/processing katmanı, DWH katmanı ve tüketim araçlarını birlikte gösteren hibrit bir sistem/veri mimarisi olarak ele alır.

### Mimari Akış Özeti

Client / uygulama katmanında kullanıcılar Web, iOS, Android ve TV uygulamalarıyla çift yönlü etkileşime girer. Bu uygulamalar hem kendi ödeme erişim noktalarıyla hem de platform SDK/event mekanizmalarıyla veri üretir.

Client tarafında oluşan veri iki ana akışa ayrılır:

1. **Operational / raw stream:** Uygulama istekleri, ödeme akışları, backend eventleri ve operasyonel kayıtlar REST/Core katmanına gider.
2. **Analytics / engagement stream:** Client SDK/event datası GA4, Firebase, Mux, Insider, Adjust gibi 3rd party platformlara gider. Google Ads ve Meta Ads ise marketing/ads data tarafında ayrı kaynak olarak konumlanır.

REST/Core tarafına gelen operational veri Elastic, DynamoDB, AWS S3, Backoffice/API ve Payment Systems gibi operasyonel sistemlerde oluşur veya tutulur. Bu katmandan çıkan operational stream Kinesis üzerinden Lambda'ya, Lambda üzerinden AWS S3 Data Lake / Staging katmanına aktarılır.

3rd Party platformlarda işlenen analytics, video analytics, engagement, attribution ve ads datası ise ayrı bir Kinesis kolu üzerinden doğrudan AWS S3 Data Lake / Staging katmanına aktarılır. Böylece REST/Core kaynaklı operational stream ile 3rd Party kaynaklı analytics stream aynı staging alanında normalize edilebilir ve downstream processing için hizalanabilir.

AWS S3 üzerinde staging edilen veri Airflow tarafından orkestre edilir. Airflow ve ilgili Python job'ları, dosya bazlı ingestion, dönüşüm, validasyon ve BigQuery yükleme süreçlerinde kullanılır. BigQuery Scheduled Queries ise BigQuery içinde SQL/ELT mantığıyla raw/source datasetlerden reporting/mart datasetlerine modelleme yapılmasını sağlar.

BigQuery, güncel veri toplama, modelleme ve raporlama omurgasının merkezindedir. Veriler önce raw/source datasetlerde tutulur; ardından reporting/mart datasetlerinde dashboard, analiz ve operasyonel kullanım için modellenir. Redshift, sistemde temsil edilmekle birlikte legacy/secondary veri ambarı olarak ele alınır.

Son tüketim katmanında Looker Studio ana dashboard ve raporlama aracı olarak kullanılır. Bunun yanında BI/Product/Marketing/Finance analizleri, ad-hoc analizler, internal staff/teams kullanımı, Insider operational outputs ve legacy/ad-hoc Superset kullanımları bu katmanın parçasıdır.

### Katmanlar

| Katman | Açıklama |
| --- | --- |
| Client / Uygulama Katmanı | Kullanıcıların Web, iOS, Android ve TV uygulamalarıyla etkileşime girdiği katmandır. Uygulamalar hem REST/Core'a operational request/event üretir hem de SDK/event mekanizmalarıyla 3rd party platformlara analytics/engagement datası gönderir. |
| Payment Touchpoints | Web Payments, Apple Pay, Google Pay ve Card Payments gibi ödeme erişim noktalarıdır. Cihaz/uygulama katmanıyla çift yönlü çalışır ve ödeme akışları Core/Payment Systems tarafına yansır. |
| REST / Core | Elastic, DynamoDB, AWS S3, Backoffice/API ve Payment Systems gibi operasyonel sistemleri içerir. Bu katman raw operational stream üretir ve bu akış Kinesis → Lambda → AWS S3 hattına gider. |
| 3rd Party / Dış Platformlar | Firebase, GA4, Mux, Insider, Adjust, Google Ads ve Meta Ads gibi analytics, engagement, attribution ve ads kaynaklarını içerir. Client/SDK eventleri bu platformlara akar; işlenen analytics stream ayrı Kinesis kolu üzerinden doğrudan AWS S3'e gider. |
| Processing / Veri İşleme Katmanı | REST/Core ve 3rd Party akışlarından gelen verilerin Kinesis, Lambda, AWS S3, Airflow, Python Jobs ve BigQuery Scheduled Queries üzerinden işlendiği katmandır. Operational stream Lambda'dan geçerken 3rd Party stream doğrudan S3 staging alanına bağlanır. |
| Storage / DWH Katmanı | BigQuery primary data warehouse olarak konumlanır. Raw/Source datasetler ham ve kaynak sistemlerden gelen verileri; Reporting/Mart datasetler ise dönüştürülmüş, modellenmiş ve raporlamaya hazır verileri tutar. Redshift legacy/secondary olarak gösterilir. |
| Visualization / Tüketim Katmanı | Looker Studio dashboard'ları, BI/Product/Marketing/Finance reporting, ad-hoc analysis, internal teams, Insider operational outputs ve Superset gibi tüketim noktalarını içerir. |

---

## 4. BigQuery Dataset Inventory

Projede tespit edilen dataset'ler aşağıdaki gibidir. Bu dokümanda tüm dataset'ler listelenir; ancak detaylı açıklama yalnızca aktif analiz / dashboard / pipeline bağı olan kritik dataset'ler için yapılır.

| Dataset                                      | Rol                                                                                      | Doküman Detay Seviyesi                                   |
| -------------------------------------------- | ---------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| `aws_s3_to_bq_migration`                     | S3 üzerinden BigQuery'ye taşınan subscription/payment, user action ve IYS kaynakları     | Detaylı                                                  |
| `looker_report`                              | Looker Studio ve reporting için hazırlanmış ana raporlama tabloları                      | Detaylı                                                  |
| `Backoffice_metadata`                        | Backoffice içerik ve promosyon metadata kaynakları                                       | Detaylı                                                  |
| `datamarts`                                  | Transaction, access, audience ve tarih bazlı legacy video/user tabloları                 | Kısmi; aktif kullanılan tablolar                         |
| `bc_marketing_raw`                           | Legacy manual spend, GA4 attribution helper, kur ve payment raw yardımcı tabloları             | Detaylı                                                  |
| `bc_marketing_marts`                         | Google Ads ve Meta Ads raw transferlarından beslenen unified marketing spend mart katmanı; aktif CAC spend standardı | Detaylı                                                  |
| `bc_googleads_spend_raw`                     | BigQuery Data Transfer ile gelen Google Ads raw tabloları; aktif veri akışı vardır              | Kısmi                                                    |
| `bc_meta_spend_raw`                          | BigQuery Data Transfer ile gelen Meta/Facebook Ads raw tabloları; aktif veri akışı vardır       | Kısmi                                                    |
| `bc_t`                                       | Test / staging / özel operasyonel analiz tabloları; kids profile pipeline dahil          | Kısmi                                                    |
| `analytics_236816681`, `analytics_271525484` | GA4 export event tabloları                                                               | Kısmi; içerik event pipeline'ında kullanılıyor           |
| `test_dataset`                               | Legacy Elastic user ve geçici yardımcı tablolar                                          | Kısmi; migration farkları nedeniyle bazı SQL'lerde aktif |
| Diğer dataset'ler                            | Reco, archive, migration, jobs, integrations vb.                                         | Bu dokümanda sadece envanter seviyesinde                 |

### Tespit Edilen Tüm Dataset Listesi

```text
Backoffice_metadata
Billing
Reco_QC_Check
adjust_migration_to_bq
adjust_v2
ads
analytics_236816681
analytics_256694785
analytics_271525484
analytics_468688820
archive
aws_s3_to_bq_migration
b2m_iq_analytics
bc_googleads_spend_raw
bc_marketing_marts
bc_marketing_raw
bc_meta_spend_raw
bc_t
data_catalogue
datamarts
datamarts_idle
gain_model_prod
insider
integrations
jobs
kardelen_temp
looker_report
microreports
migration_elastic
migration_test
mux
reco_preprod
reco_prod
reco_temp
test_b2m_iq_analytics__analytics_236816681
test_dataset
```

---

## 5. Critical Table Catalog

## 5.1 `aws_s3_to_bq_migration.subs_payment`

**Rol:** Ödeme ve abonelik tarafının ana transactional kaynağıdır.

**Ana kullanım alanları:**

- Active subscriber hesapları
- Paid subscriber hesapları
- MRR / ARPU / revenue / LTV hesapları
- Campaign / promotion usage ve conversion analizleri
- Payment option kırılımları
- App Store / Play Store / Craftgate / Iyzico / Mobile Payment / Prepaid ayrımları
- Trial, grace, hold, valid\_until ve cancellation senaryoları

**Önemli alanlar:**

| Alan                                                              | Tip       | Açıklama                                                                                                 |
| ----------------------------------------------------------------- | --------- | -------------------------------------------------------------------------------------------------------- |
| `user_id`                                                         | STRING    | Kullanıcı anahtarı; çoğu join için temel alan.                                                           |
| `status`                                                          | STRING    | Subscription status. Sık kullanılan değerler: `ACTIVE`, `CANCELED`, `EXPIRED`, `IN_GRACE`, `ON_HOLD`.    |
| `payment_option`                                                  | STRING    | Ödeme kanalı: `APP_STORE`, `PLAY_STORE`, `MOBILE_PAYMENT`, `CRAFTGATE`, `IYZICO`, `PREPAID`.             |
| `amount`                                                          | INT64     | Minor unit / kuruş formatında ödeme tutarı. 24900 = 249.00 TL.                                           |
| `amount_before_promotions`                                        | INT64     | Promosyon öncesi tutar. Full-price conversion tespiti için kritik.                                       |
| `currency`                                                        | STRING    | Finansal KPI'larda çoğunlukla `TRY` filtre                                                               |
| `valid_until`                                                     | TIMESTAMP | Subscription cycle ve aktiflik hesabında en güvenilir alanlardan biri.                                   |
| `grace_until`                                                     | TIMESTAMP | Grace period aktiflik hesabı için kullanılır.                                                            |
| `hold_until`                                                      | TIMESTAMP | On hold aktiflik hesabı için kullanılır.                                                                 |
| `applied_promotions`                                              | ARRAY     | PromotionId, campaign, benefit ve applyDate gibi kampanya detaylarını içerir.                            |
| `free_trial_start_date`, `free_trial_end_date`                    | TIMESTAMP | Trial dönemi hesapları.                                                                                  |
| `created_at`                                                      | TIMESTAMP | Ödeme/kayıt timestamp'i olarak kullanılır ancak her analizde tek başına güvenilir cycle anchor değildir. |
| `registered_at`                                                   | TIMESTAMP | Kullanıcı kayıt tarihi.                                                                                  |
| `apple_original_transaction_id`, `google_original_transaction_id` | STRING    | Store transaction mapping için kullanılır.                                                               |

**Business notes:**

- `amount` ve `amount_before_promotions` kuruş/minor unit formatındadır.
- Finansal KPI'larda çoğunlukla `currency = 'TRY'` kullanılır.
- PREPAID çoğu unit economics ve LTV/CAC hesaplarından hariç tutulur.
- `created_at` bazı senaryolarda cancellation / update gibi olaylardan etkilenebileceği için subscription cycle hesabında tek başına kullanılmamalıdır.
- `valid_until` aktiflik ve billing cycle mantığı için daha güvenilir bir anchor olarak kullanılır.
- Kampanya conversion hesaplarında full-price ödeme kontrolü için `amount = amount_before_promotions` ve aynı `promotionId` taşımama şartı kullanılır.

---

## 5.2 `looker_report.Daily_Report_Metrics`

**Rol:** Günlük abonelik KPI'larının Looker tarafında okunması için hazırlanmış ana raporlama tablosudur.

**Schema:**

| Alan     | Tip    | Açıklama                                                     |
| -------- | ------ | ------------------------------------------------------------ |
| `date`   | DATE   | KPI tarihi. Genelde T-1 mantığıyla kullanılır.               |
| `metric` | STRING | Metrik adı.                                                  |
| `rownum` | INT64  | Looker içinde filtrelemeyi kolaylaştıran metrik sırası / ID. |
| `value`  | INT64  | Metrik değeri.                                               |

**Önemli metric / rownum mantığı:**

| rownum | Metric                                 |
| ------ | -------------------------------------- |
| 1      | Toplam Ücretli Abonelik                |
| 2      | Promosyon Kullanmış Ücretli Abone      |
| 3      | Yeni Abonelik Satın Alan               |
| 4      | İptal Edilen Abonelik                  |
| 5      | Grace Period Sürecindeki Kullanıcılar  |
| 6      | 7 Günlük Ücretsiz Deneme Kullanımı     |
| 7      | 7 Günlük Promosyon Kullanımı           |
| 8      | 7 Günlük Ücretsiz Deneme Devam Edenler |
| 9      | 7 Günlük Promosyon Devam Eden          |
| 10     | Son 1 Haftada Abonelik Satın Alan      |

**Looker kullanımı:**

- `Daily_Report_Metrics_Single_Data`: `Daily_Report_Metrics` tablosunda T-1 tarihine ait row'ları çeker. Looker içinde `rownum` / `metric` filtreleriyle KPI kartlarına ayrılır.
- `Daily_Report_Metrics`, `Daily_Report_Metrics_Ucretli`, `Daily_Report_Metrics_Iptal`, `Daily_Report_Metrics_Yeni_Abonelik`: aynı tablodan farklı metric filtreleriyle trend ve karşılaştırma çıktıları üretir.

---

## 5.3 `looker_report.elastic_active_user`

**Rol:** Elastic kaynaklı legacy active user datasıdır. Migration sonrası eksik kalabilen kullanıcı kayıtları için destek kaynak olarak kullanılır.

**Önemli alanlar:**

| Alan                                           | Tip    | Açıklama                       |
| ---------------------------------------------- | ------ | ------------------------------ |
| `user_id`                                      | STRING | Kullanıcı anahtarı.            |
| `status`                                       | STRING | Kullanıcı/subscription status. |
| `subscription_plan_id`                         | STRING | Abonelik planı.                |
| `valid_until`                                  | STRING | Legacy aktiflik tarih alanı.   |
| `grace_until`                                  | STRING | Legacy grace bilgisi.          |
| `free_trial_start_date`, `free_trial_end_date` | STRING | Trial bilgisi.                 |
| `applied_promotions`                           | STRING | Legacy promotion bilgisi.      |

**Business note:**

`subs_payment` migration sonrası ana kaynak olsa da bazı kullanıcılar Elastic tarafında bulunup `subs_payment` tarafında eksik olabildiği için belirli KPI ve kampanya analizlerinde Elastic destekleyici kaynak olarak tutulur.

---

## 5.4 `looker_report.content_report_streaming_V2`

**Rol:** İzlenme davranışının ana reporting kaynağıdır.

**Ana kullanım alanları:**

- Content performance
- Unique watcher / view count
- Watch time
- First watch analysis
- Last watched before expiry
- Content category retention
- Watcher LTV
- Heavy vs light watcher segmentasyonu
- Campaign watcher ve platform usage analizleri

**Önemli alanlar:**

| Alan                | Tip      | Açıklama                                                                                 |
| ------------------- | -------- | ---------------------------------------------------------------------------------------- |
| `user_id`           | STRING   | İzleyen kullanıcı.                                                                       |
| `event_date`        | DATE     | İzleme tarihi.                                                                           |
| `Datetime_Ist`      | DATETIME | İstanbul zamanına normalize edilmiş event zamanı. İlk/son izleme sıralaması için kritik. |
| `video_id`          | STRING   | İçerik metadata join anahtarı.                                                           |
| `ga_session_id`     | INT64    | GA session bilgisi.                                                                      |
| `watch_time_second` | FLOAT64  | İzleme süresi.                                                                           |
| `device_category`   | STRING   | Cihaz kategorisi.                                                                        |
| `device_platform`   | STRING   | Platform kırılımı.                                                                       |
| `user_pseudo_id`    | STRING   | GA kaynaklı pseudo user fallback / analiz alanı.                                         |

**Join mantığı:**

- `video_id` → `Backoffice_metadata.ContentMetaData.video_id`
- `user_id` → `subs_payment.user_id` veya `elastic_active_user.user_id`

---

## 5.5 `Backoffice_metadata.ContentMetaData`

**Rol:** İçerik metadata enrichment kaynağıdır.

**Önemli alanlar:**

| Alan              | Tip    | Açıklama                                  |
| ----------------- | ------ | ----------------------------------------- |
| `video_id`        | STRING | İzlenme tablolarıyla ana join alanı.      |
| `titleid`         | STRING | Title ID.                                 |
| `displayname`     | STRING | İçerik adı.                               |
| `video_name`      | STRING | Bölüm/video adı.                          |
| `season_info`     | STRING | Sezon bilgisi.                            |
| `EpisodeNumber`   | INT64  | Bölüm numarası.                           |
| `contenttype_id`  | STRING | İçerik türü.                              |
| `genres`          | STRING | Virgülle ayrılmış genre/kategori listesi. |
| `IsGainOriginals` | BOOL   | GAİN Orijinal bilgisi.                    |

**Business note:**

İzlenme datası tek başına içerik adı, tür, sezon ve kategori üretmek için yeterli değildir. Bu nedenle `content_report_streaming_V2` çoğu içerik SQL'inde `ContentMetaData` ile enrich edilir.

---

## 5.6 `Backoffice_metadata.bo_promotions`

**Rol:** Promosyon ve kampanya metadata kaynağıdır.

**Önemli alanlar:**

| Alan                                   | Tip    | Açıklama                                                         |
| -------------------------------------- | ------ | ---------------------------------------------------------------- |
| `promotionId`                          | STRING | `subs_payment.applied_promotions.promotionId` ile join anahtarı. |
| `name`                                 | STRING | Promosyon adı.                                                   |
| `promotionDescription`                 | STRING | Açıklama / alternatif isim.                                      |
| `type`                                 | STRING | MASS, UNIQUE, USER\_GROUP, PREPAID vb.                           |
| `isActive`                             | BOOL   | Aktif/pasif bilgisi.                                             |
| `campaignStartDate`, `campaignEndDate` | STRING | Kampanya tarih aralığı.                                          |
| `codeCount`, `usageCount`              | INT64  | Üretilen ve kullanılan kod sayıları.                             |
| `paymentOptions`                       | STRING | Geçerli ödeme seçenekleri.                                       |
| `benefits`                             | STRING | Kampanya benefit detayları.                                      |

**Join mantığı:**

`bo_promotions.promotionId = subs_payment.applied_promotions.promotionId`

---

## 5.7 `datamarts.transaction_v2`

**Rol:** Normalize transaction / payment data source. Özellikle payment reconciliation, mobile payment kontrolleri ve eski transaction akışlarının debug'ı için kullanılır.

**Önemli alanlar:**

| Alan            | Tip       | Açıklama                           |
| --------------- | --------- | ---------------------------------- |
| `transactionId` | STRING    | Transaction ID.                    |
| `paymentType`   | STRING    | Payment channel/type.              |
| `createdAt`     | TIMESTAMP | Transaction oluşum zamanı.         |
| `userId`        | INT64     | Kullanıcı ID.                      |
| `userUUID`      | STRING    | User UUID.                         |
| `price`         | FLOAT64   | Tutar.                             |
| `currency`      | STRING    | Para birimi.                       |
| `promotion`     | STRING    | Promotion bilgisi.                 |
| `expiresAt`     | TIMESTAMP | Access/subscription expire zamanı. |

---

## 5.8 `bc_marketing_raw.manual_monthly_spend`

**Rol:** Geçmişte CAC hesapları için oluşturulmuş manuel aylık marketing spend kaynağıdır.

**Schema:**

| Alan          | Tip       | Açıklama                        |
| ------------- | --------- | ------------------------------- |
| `month`       | DATE      | Spend ayı.                      |
| `channel`     | STRING    | Kanal: meta, google, tiktok vb. |
| `spend_tl`    | FLOAT64   | TRY spend.                      |
| `currency`    | STRING    | Para birimi.                    |
| `source_type` | STRING    | Manuel kaynak tipi.             |
| `note`        | STRING    | Not.                            |
| `inserted_at` | TIMESTAMP | Insert zamanı.                  |

**Historical / legacy state:**

Bu tablo, otomasyon altyapısı tamamlanmadan önce CAC metriklerini hızlıca çalıştırmak için kullanılmıştır. Eski Looker SQL'lerinde veya geçmiş dashboard versiyonlarında aktif kaynak olarak görülebilir.

**Current standard:**

CAC / LTV-CAC standardizasyonu sonrası yeni ve revize edilen SQL'lerde primary spend source olarak bu tablo kullanılmamalıdır. Standart kaynak `bc_marketing_marts.ads_daily_spend` olmalıdır.

**Dokümantasyon notu:**

Yakın zamanda eski bir SQL veya dashboard incelenirse `manual_monthly_spend` kullanımı görülebilir. Bu durum veri modelinin hedef standardı değil, geçmiş/legacy kullanımın izidir. Güncel reklam harcaması akışı Google Ads ve Meta Ads raw transfer tabloları üzerinden `bc_marketing_marts.ads_daily_spend` tablosuna akmaktadır.

---

## 5.9 `bc_marketing_marts.ads_daily_spend`

**Rol:** Google Ads ve Meta Ads raw transfer tablolarından beslenen, normalize edilmiş günlük reklam harcaması mart tablosudur.

**Aktif veri akışı:**

Bu tablo aktif olarak veri almaktadır. Güncel akışta Google Ads ve Meta Ads tarafındaki raw transfer tabloları `BC_ADS_DAILY_SPEND_UNIFIED_01` scheduled query'si ile normalize edilerek `bc_marketing_marts.ads_daily_spend` tablosuna yazılır.

Örnek akış:

```text
Google Ads Data Transfer → bc_googleads_spend_raw → BC_ADS_DAILY_SPEND_UNIFIED_01 → bc_marketing_marts.ads_daily_spend
Meta Ads Data Transfer   → bc_meta_spend_raw      → BC_ADS_DAILY_SPEND_UNIFIED_01 → bc_marketing_marts.ads_daily_spend
```

**Schema:**

| Alan | Tip | Açıklama |
| --- | --- | --- |
| `day` | DATE | Spend günü. |
| `month` | DATE | Ay başlangıcı. |
| `channel` | STRING | Normalize kanal. Örn. `google`, `meta`. |
| `source_platform` | STRING | Kaynak platform. Örn. `google_ads`, `meta_ads`. |
| `account_id`, `account_name` | STRING | Reklam hesabı bilgileri. |
| `campaign_id`, `campaign_name` | STRING | Kampanya bilgileri. Google tarafında campaign ID dolu gelebilir; Meta tarafında account-level AdInsights akışında campaign alanları boş olabilir. |
| `currency` | STRING | Para birimi. Güncel CAC kullanımı için `TRY`. |
| `spend_tl` | FLOAT64 | TRY normalize spend. |
| `source_table` | STRING | Kaynak raw tablo. Örn. `p_ads_CampaignBasicStats_6861382209`, `AdInsights`. |
| `loaded_at` | TIMESTAMP | Mart tablosuna yükleme zamanı. |

**Örnek kayıt davranışı:**

- Google Ads kayıtlarında `source_platform = 'google_ads'`, `channel = 'google'`, `account_id = 6861382209`, `source_table = 'p_ads_CampaignBasicStats_6861382209'` şeklinde veri görülebilir.
- Meta kayıtlarında `source_platform = 'meta_ads'`, `channel = 'meta'`, `account_id = 1326208638940273`, `account_name = 'GAİN'`, `source_table = 'AdInsights'` şeklinde veri görülebilir.
- Aynı gün ve ay içinde farklı kampanya/account kırılımlarında birden fazla satır bulunabilir.

**Kullanım standardı:**

Yeni CAC, channel CAC, LTV/CAC ve payback sorgularında spend tarafı bu tablodan okunmalıdır. `manual_monthly_spend` sadece legacy/historical fallback olarak değerlendirilmelidir.

**Business note:**

Bu tablo artık yalnızca target/future state olarak değil, aktif veri akışı olan güncel unified spend mart olarak konumlanır. Dokümantasyonda CAC tarafında primary spend source olarak bu tablo referans alınmalıdır.

---

## 5.10 `bc_t.active_subscribers_snapshot`

**Rol:** Kids profile pipeline kapsamında aktif abone / kids profile snapshot çıktısı.

| Alan           | Tip       | Açıklama                             |
| -------------- | --------- | ------------------------------------ |
| `snapshot_ts`  | TIMESTAMP | Snapshot zamanı.                     |
| `active_total` | INT64     | Aktif abone toplamı.                 |
| `kids_total`   | INT64     | Kids profile sahip kullanıcı sayısı. |
| `source`       | STRING    | Kaynak bilgisi.                      |
| `run_id`       | STRING    | Pipeline run ID.                     |

---

## 5.11 `bc_t.user_kids_profile_state`

**Rol:** Kullanıcı bazlı kids profile state final tablosu.

| Alan                                 | Tip       | Açıklama                            |
| ------------------------------------ | --------- | ----------------------------------- |
| `user_id`                            | STRING    | Kullanıcı.                          |
| `subscription_status`                | STRING    | Kullanıcının subscription status'ü. |
| `has_kid_profile`                    | BOOL      | Kids profile var/yok.               |
| `total_profiles`                     | INT64     | Toplam profil sayısı.               |
| `kid_profile_count`                  | INT64     | Kids profile sayısı.                |
| `user_created_at`, `user_updated_at` | TIMESTAMP | Kullanıcı tarihleri.                |
| `checked_at`                         | TIMESTAMP | Kontrol zamanı.                     |
| `run_id`                             | STRING    | Pipeline run ID.                    |

---

## 5.12 `bc_marketing_raw.ga4_first_non_direct_touch`

**Rol:** CAC attribution tarafında kullanılan GA4 attribution helper tablosudur.

**Kullanılan alanlar:**

| Alan             | Açıklama                                                                         |
| ---------------- | -------------------------------------------------------------------------------- |
| `user_id`        | Backend ödeme datasındaki `subs_payment.user_id` ile eşleşen kullanıcı anahtarı. |
| `touch_date`     | Attribution touch tarihi.                                                        |
| `source`         | Raw traffic source.                                                              |
| `medium`         | Raw medium.                                                                      |
| `campaign`       | Raw campaign.                                                                    |
| `mapped_channel` | Önceden map'lenmiş kanal alanı.                                                  |

**Önemli sınırlama:**

Tablo adı `first_non_direct_touch` olduğu için, bu tablo gerçek raw touch/event datası değilse gerçek anlamda last-touch attribution üretmek mümkün olmayabilir. v0.2 standardındaki model, bu tabloda mevcut olan kayıtlar arasından ödeme öncesi son 30 gündeki en son eligible touch'ı seçer. Bu nedenle model **available-data best effort** olarak değerlendirilmelidir.

**Ideal future state:**

Raw GA4 event/touch datasından kullanıcı başına ilk ücretli ödeme öncesindeki son 30 günlük eligible paid/non-direct touch üretilmeli ve ayrı bir mart olarak saklanmalıdır.

---

## 5.13 Proposed Future Mart — `bc_marketing_marts.ga4_last_paid_touch_30d`

**Rol:** Uzun vadede CAC ve channel LTV/CAC sorgularının attribution logic tekrarını azaltmak için önerilen standart attribution mart'ıdır.

**Önerilen grain:**

```text
one row per user_id per first_paid_date
```

**Önerilen alanlar:**

| Alan                           | Açıklama                                   |
| ------------------------------ | ------------------------------------------ |
| `user_id`                      | Kullanıcı.                                 |
| `first_paid_date`              | İlk ücretli ödeme tarihi.                  |
| `attributed_touch_date`        | Ödeme öncesi seçilen touch tarihi.         |
| `day_diff`                     | `first_paid_date - attributed_touch_date`. |
| `source`, `medium`, `campaign` | Raw attribution alanları.                  |
| `raw_mapped_channel`           | Kaynak mapped channel.                     |
| `normalized_channel`           | Standardize kanal.                         |
| `attribution_model`            | Örn. `last_paid_touch_30d`.                |
| `created_at`                   | Mart üretim zamanı.                        |

**Önerilen model:**

```text
last eligible paid/non-direct touch within 30 days before first paid
```

Bu mart üretildikten sonra CAC ve LTV/CAC sorgularının attribution CTE'leri sadeleştirilmeli ve ortak logic tek source of truth haline getirilmelidir.

---

## 6. Data Transfer Jobs

BigQuery Data Transfer job'ları reklam platformlarındaki raw spend datasını BigQuery raw datasetlerine taşır. Bu raw datasetler doğrudan dashboardlarda kullanılmak yerine `BC_ADS_DAILY_SPEND_UNIFIED_01` scheduled query'si ile normalize edilerek `bc_marketing_marts.ads_daily_spend` mart tablosuna aktarılır.

## 6.1 Google Ads Transfer

| Alan | Değer |
| --- | --- |
| Source | Google Ads |
| Customer ID | `686-138-2209` |
| Report Type | Standard |
| Destination Dataset | `bc_googleads_spend_raw` |
| Transfer Config Name | `ads_google_spend` |
| Schedule | Daily `00:01 UTC` |
| Current State | Aktif veri akışı vardır. Raw Google Ads tabloları üzerinden `bc_marketing_marts.ads_daily_spend` tablosuna günlük spend kayıtları yazılmaktadır. |
| Downstream Mart | `bc_marketing_marts.ads_daily_spend` |
| Örnek Source Table | `p_ads_CampaignBasicStats_6861382209` |
| Not | Removed/disabled items exclude açık. PMax tables ve Google Ads'e yeni eklenen Adwords dışı tablolar kapalı görünüyor. |

## 6.2 Meta / Facebook Ads Transfer

| Alan | Değer |
| --- | --- |
| Source | Facebook Ads / Meta Ads |
| Object | `AdInsights` |
| Level | Account |
| Destination Dataset | `bc_meta_spend_raw` |
| Transfer Config Name | `ads_meta_spend` |
| Schedule | Daily `00:01 UTC` |
| Aggregate Last N Days | 1 |
| Refresh Window | 7 |
| Current State | Aktif veri akışı vardır. `bc_meta_spend_raw` içerisindeki Meta Ads raw kayıtları `BC_ADS_DAILY_SPEND_UNIFIED_01` ile normalize edilerek `bc_marketing_marts.ads_daily_spend` tablosuna yazılmaktadır. |
| Downstream Mart | `bc_marketing_marts.ads_daily_spend` |
| Örnek Source Table | `AdInsights` |
| Not | Meta tarafında account-level AdInsights akışı kullanılmaktadır. Bu nedenle bazı satırlarda campaign_id / campaign_name alanları boş gelebilir. |

## 6.3 Unified Spend Flow

Aktif reklam harcaması akışı aşağıdaki şekilde çalışır:

```text
Google Ads Transfer → bc_googleads_spend_raw
Meta Ads Transfer   → bc_meta_spend_raw
                   ↓
BC_ADS_DAILY_SPEND_UNIFIED_01
                   ↓
bc_marketing_marts.ads_daily_spend
```

`ads_daily_spend`, Google ve Meta harcamalarını ortak şemada birleştirir. Bu tablo CAC, channel CAC, LTV/CAC ve payback analizlerinde primary spend source olarak kullanılmalıdır.

---

## 7. BigQuery Scheduled Query Inventory

| Scheduled Query                            | Schedule                 | Destination                                              | Kaynaklar                                                                               | Rol                                                                             |
| ------------------------------------------ | ------------------------ | -------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `BC_ADS_DAILY_SPEND_UNIFIED_01`            | Daily 04:00 UTC          | `bc_marketing_marts.ads_daily_spend`                     | `bc_googleads_spend_raw`, `bc_meta_spend_raw`                                           | Google/Meta raw spend tablolarından aktif gelen reklam harcamalarını günlük unified spend mart'a normalize eder. CAC altyapısının güncel primary spend kaynağıdır. |
| `content_report`                           | Every 10 minutes         | `looker_report.content_report`                           | `datamarts.user_video_*`, `tv_user_video`, `web_user_video`, `jw_video_master_category` | Legacy content watch reporting table.                                           |
| `content_report_streaming`                 | Every 15 minutes         | `looker_report.content_report_streaming`                 | Streaming user video tabloları                                                          | Streaming izleme datasını legacy mart'a taşır.                                  |
| `content_report_streaming_V2_tmp_20250201` | Daily 20:55 UTC          | `looker_report.content_report_streaming_V2_tmp_20250201` | `content_report_streaming_V2`                                                           | Geçici / backup / transform tablosu.                                            |
| `content_report_v2`                        | Daily 05:50 UTC          | `looker_report.content_report_V2`                        | GA4 `analytics_236816681`, `analytics_271525484`, `Backoffice_metadata.bo_titles`       | GA4 eventlerinden video action datası üretir.                                   |
| `Daily_Report_Metrics`                     | Daily 06:00 UTC / paused | `looker_report.Daily_Report_Metrics`                     | datamarts transaction/access/promotion tabloları                                        | Eski/günlük abonelik KPI üretimi. Paused görünüyor.                             |
| `Daily_Report_Metrics_Yesterday_Insert`    | Daily 21:01 UTC          | `looker_report.Daily_Report_Metrics`                     | `test_dataset.elastic_user`, `aws_s3_to_bq_migration.subs_payment`                      | T-1 günlük KPI satırlarını üretir. Güncel dashboard KPI'larının ana kaynağıdır. |
| `dogu_streaming`                           | Every 30 minutes         | `looker_report.content_report_streaming_V2`              | GA4 intraday events, `content_report_V2`, `bo_titles`, season helper                    | Güncel streaming V2 refresh pipeline'ı.                                         |

---

## 8. Airflow DAG Inventory

Airflow DAG içerikleri / underlying Python script'ler bu çalışma sırasında doğrudan görüntülenememiştir. Açıklamalar DAG adı, schedule, tag ve gözlenen source/destination mantığından türetilmiştir.

| DAG                                                       | Durum  | Inferred Purpose                                                                                                                |
| --------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `Prod_Gain_BO_Content_Title_Data_To_Bq_Dag`               | Active | Backoffice content/title datasını BigQuery `Backoffice_metadata` katmanına taşır.                                               |
| `Prod_Gain_BO_Promotion_Data_To_Bq_Dag`                   | Active | Backoffice promotion datasını `Backoffice_metadata.bo_promotions` tablosuna taşır.                                              |
| `Prod_Gain_Daily_Elastic_User_Data_To_Insider_Dag`        | Active | Elastic user datasını Insider tarafına upsert eder.                                                                             |
| `Prod_Gain_Elastic_User_All_Data_To_Bq_Dag`               | Active | Elastic user datasını BigQuery'ye taşır / SCD benzeri full snapshot mantığı çalıştırır.                                         |
| `Prod_Gain_GA4_Events_Count_Check_To_Bq_Dag`              | Active | GA4 event count anomaly / kalite kontrol job'ı.                                                                                 |
| `Prod_Gain_Internal_Data_Quality_To_Bq_Dag`               | Active | BigQuery üzerinde internal data quality kontrolleri ve Teams alert akışı.                                                       |
| `Prod_Gain_Never_Watched_Users_Data_To_Insider_Panel_Dag` | Active | Ödeme yapan ancak hiç izleme yapmayan kullanıcıları Insider'a gönderir.                                                         |
| `Prod_Gain_Never_Watched_Users_To_Bq_Scd_Dag`             | Active | Never-watched segmentini BigQuery tarafında SCD yapısında tutar.                                                                |
| `Prod_Gain_S3_Data_Count_Validator_To_Bq_Dag`             | Active | S3 ve BigQuery count validation; user\_actions, iys\_subscriptions, subs-payment gibi gruplar için veri bütünlüğü kontrol eder. |
| `Prod_Gain_S3_IYS_To_Redshift_Dag`                        | Active | S3 IYS datasını Redshift'e taşır.                                                                                               |
| `Prod_Gain_S3_Migration_Adjust_To_Bq_Dag`                 | Active | S3 Adjust datasını BigQuery'ye taşır.                                                                                           |
| `Prod_Gain_S3_Migration_IYS_To_Bq_Dag`                    | Active | S3 IYS subscription datasını BigQuery'ye taşır.                                                                                 |
| `Prod_Gain_S3_Migration_User_Action_To_Bq_Dag`            | Active | S3 user action datasını BigQuery'ye taşır.                                                                                      |
| `Prod_Gain_S3_User_Actions_To_Redshift_Dag`               | Active | S3 user actions datasını Redshift'e taşır.                                                                                      |
| `Prod_Gain_Subs_Payment_Data_To_Bq_Dag`                   | Active | S3 subscription/payment datasını `aws_s3_to_bq_migration.subs_payment` tablosuna taşır.                                         |
| `prod-subs-pay-dag`                                       | Active | Redshift / legacy subs payment pipeline.                                                                                        |
| `prod_subs_payment_data_validation`                       | Active | Subscription/payment data validation.                                                                                           |
| Test DAG'lar                                              | Mixed  | Test / dev amaçlı pipeline'lar.                                                                                                 |

---

## 8.1 Ara Toparlama — Pipeline ve Veri Akışının Okunması

İlk 8 bölümde anlatılan yapı, GAİN veri mimarisinin ham veri kaynaklarından raporlama katmanına kadar nasıl ilerlediğini özetler. Bu noktada mimariyi okumak için ana mantık şu şekildedir:

- Kullanıcı ve uygulama katmanında oluşan veri iki ana yöne ayrılır: operasyonel akış REST/Core sistemlerine, analytics/engagement akışı ise 3rd party platformlara gider.
- REST/Core kaynaklı operational stream Kinesis üzerinden Lambda'ya, oradan AWS S3 staging alanına taşınır.
- 3rd Party kaynaklı analytics stream ayrı Kinesis kolu üzerinden doğrudan AWS S3 staging alanına gelir.
- AWS S3 staging alanında toplanan veriler Airflow ve Python job'ları ile BigQuery'ye taşınır veya dönüştürülür.
- BigQuery içerisinde raw/source datasetlerden reporting/mart datasetlere geçiş Scheduled Query ve SQL/ELT mantığıyla yapılır.
- Looker Studio, Product, Marketing, Finance ve BI ekiplerinin tükettiği dashboard ve analizlerin büyük bölümü bu reporting/mart katmanı üzerinden beslenir.

Bu nedenle dokümanın ilk yarısı yalnızca tablo isimlerini listelemek için değil, bir verinin dashboard'a gelene kadar hangi sistemlerden geçtiğini açıklamak için kurgulanmıştır. Özellikle `subs_payment`, `content_report_streaming_V2`, `ContentMetaData`, `bo_promotions`, `ads_daily_spend` ve `Daily_Report_Metrics` gibi tablolar, downstream KPI ve dashboardların ana omurgasını oluşturur.

Bu noktadan sonra doküman, pipeline ve tablo envanterinden çıkıp Looker Studio tarafındaki dashboard bağımlılıklarına geçer. Böylece önce verinin nasıl üretildiği, ardından bu verinin dashboardlarda hangi KPI, grafik ve tabloları beslediği açıklanır.

---

## 9. Looker Studio Dashboard Mapping

> **Not:** Bu bölüm v0.3'te yeniden toparlandı. Canvas uzunluğu nedeniyle önceki görünümde yalnızca Sayfa 2 başlangıcı görünmüş olabilir. Aşağıdaki mapping, dashboard PDF'i ve iletilen SQL eşleşmeleri baz alınarak sayfa sayfa yeniden düzenlenmiştir.

Bu bölüm, Looker Studio dashboard'larında yer alan sayfa, KPI, grafik ve tabloların hangi SQL / data source üzerinden beslendiğini açıklar. Amaç, dashboard üzerinde görülen her metrik için geriye dönük olarak hangi BigQuery tablosu, hangi SQL mantığı ve hangi business rule kullanıldığını izlenebilir hale getirmektir.

---

## 9.1 Sayfa 1 — Kullanıcı Raporları

### KPI Kartları

Bu sayfadaki üst KPI kartlarının önemli bir kısmı aynı temel data source üzerinden beslenir. `Daily_Report_Metrics_Single_Data`, `looker_report.Daily_Report_Metrics` tablosundan T-1 tarihindeki satırları çeker ve Looker tarafında `rownum` / `metric` filtresiyle ilgili KPI ayrıştırılır.

Örnek temel kullanım:

```sql
SELECT *
FROM `microgain-9f959.looker_report.Daily_Report_Metrics`
WHERE date = DATE_SUB(CURRENT_DATE("Europe/Istanbul"), INTERVAL 1 DAY)
```

| KPI | SQL / Data Source | Açıklama |
| --- | --- | --- |
| Toplam Abonelik | `Daily_Report_Metrics_Single_Data` | T-1 `Daily_Report_Metrics` row'ları içinden ilgili `rownum` / `metric` filtresiyle gelir. |
| İptal Edilen Abonelik | `Daily_Report_Metrics_Single_Data` | T-1 iptal edilen abonelik KPI'ı. |
| 7 Günlük Denemede Olan Aboneler | `Daily_Report_Metrics_Single_Data` | Trial kullanımı / devam eden deneme metriği. |
| Hediye Kart Kullanmış Aboneler | `PREPAIDUSER` | Legacy Elastic + `subs_payment` üzerinden prepaid/payment_option kırılımı ile hesaplanır. |
| Ücretli Abonelik | `PAIDUSER` | Daily metric satırları ve prepaid kullanıcılar dikkate alınarak ücretli abonelik sayısı hesaplanır. |
| Yeni Abonelik Satın Alan | `Daily_Report_Metrics_Single_Data` | T-1 yeni satın alma metriği. |
| Grace Period Sürecindeki Aboneler | `Daily_Report_Metrics_Single_Data` | Grace period kullanıcı KPI'ı. |
| Promosyon Kullanmış Aboneler | `Daily_Report_Metrics_Single_Data` | Promosyon kullanmış ücretli abone KPI'ı. |

### Abonelik Genel Durum Grafikleri

| Grafik | SQL / Data Source | Açıklama |
| --- | --- | --- |
| Toplam Abonelik | `Daily_Report_Metrics` | Günlük toplam abonelik trendi. |
| Ücretli Abonelik | `Daily_Report_Metrics_Ucretli` | Günlük ücretli abonelik trendi. |
| Yeni Abonelik Satın Alan | `Daily_Report_Metrics_Yeni_Abonelik` | Günlük yeni satın alma trendi. |
| İptal Edilen Abonelik | `Daily_Report_Metrics_Iptal` | Günlük iptal trendi. |

---

## 9.2 Sayfa 2 — İçerik Genel Durum / Performans ve İzlenme

Varsayılan tarih filtresi genellikle son 7 gün olarak kullanılır. Bu sayfa içerik bazlı izlenme performansını; içerik adı, kategori, sezon, içerik türü, bölüm ve GAİN Orijinal filtreleriyle analiz eder.

| Bileşen | SQL / Data Source | Açıklama |
| --- | --- | --- |
| Filtreler ve ana performans tablosu | `SezonBolum_izlenme` | İçerik adı, sezon, bölüm, içerik türü, kategori, GAİN Original bilgisi, tekil kullanıcı ve izlenme sayısı alanlarını üretir. |
| Genel İzleme Trendleri | `User+ViewCountData` | Tarih bazında tekil kullanıcı sayısı ve izlenme sayısı trendini verir. |
| İçerik Bazlı İzlenme Trendleri | `GunlukIzlenmeTrendleri` | Günlük bazda içerik kırılımında izlenme sayısı trendini gösterir. |
| Sezon Bazlı İzlenme Trendleri | `GunlukIzlenmeTrendleri` | Sezon kırılımında izlenme trendi üretir; anlamlı yorum için genellikle tek içerik seçilerek okunmalıdır. |
| Diziler Top 10 | `User+ViewCountDataTop10` türevi | Dizi içerikleri için top 10 izlenme / tekil kullanıcı sıralaması. |
| Programlar Top 10 | `User+ViewCountDataTop10` türevi | Program içerikleri için top 10 izlenme / tekil kullanıcı sıralaması. |
| Filmler Top 10 | `User+ViewCountDataTop10` türevi | Film içerikleri için top 10 izlenme / tekil kullanıcı sıralaması. |
| Belgeseller Top 10 | `User+ViewCountDataTop10` türevi | Belgesel içerikleri için top 10 izlenme / tekil kullanıcı sıralaması. |

**Temel veri mantığı:** Bu sayfadaki içerik analizleri ağırlıklı olarak `looker_report.content_report_streaming_V2` ve `Backoffice_metadata.ContentMetaData` ilişkisine dayanır.

---

## 9.3 Sayfa 3 — İçerik Genel Durum / Abone Performansı ve Dönüşüm

Bu sayfa, içerik izleme davranışının abonelik kazanımı ve ilk izleme davranışıyla ilişkisini gösterir.

| Bileşen | SQL / Data Source | Açıklama |
| --- | --- | --- |
| Abone Performansı ve Dönüşüm Line Chart | `FirstWatch` | Gün bazında toplam izleyen abone, ilk defa izleyen abone ve izlemek için abone olma sayısını üretir. |
| Günlük Performans Sıralaması | `FirstWatch` | Tarih ve içerik kırılımında günlük performans sıralamasıdır. |
| Toplam Performans Sıralaması | `FirstWatch` | İçerik bazında toplam izleyen, ilk defa izleyen ve izlemek için abone olan kullanıcıları listeler. |

---

## 9.4 Sayfa 4 — İçerik Tercihleri ve 3 Aylık Retention

Bu sayfa, kullanıcıların ilk izlediği kategori ile LTV / retention ilişkisini ve expire öncesi son izlenen içerik/kategori davranışını gösterir.

| Bileşen | SQL / Data Source | Açıklama |
| --- | --- | --- |
| Abonelik Başlangıcında İzlenen Kategori | `BC_CATEGORY_LTV_02` | Kullanıcının ilk anlamlı izlediği içerik kategorisini bulur ve kategori bazında kullanıcı sayısı üretir. |
| Content Category vs 3-Month Retention | `BC_RETENTION_CONTENT_02` | İlk izlenen kategoriye göre 3 aylık retention oranını hesaplar. |
| Expire Öncesi Son İzlenen İçerik | `BC_LAST_WATCHED_CONTENTS` | Expire olmadan önceki son izlenen içerik dağılımını üretir. |
| Expire Öncesi Son İzlenen Kategori | `BC_LAST_WATCHED_CONTENTS` | Expire olmadan önceki son izlenen kategori dağılımını üretir. |

---

## 9.5 Sayfa 5 — Churn & Retention

Dashboard export'unda bu sayfa aktif bir grafik veya tablo içermemektedir. Şu an placeholder olarak değerlendirilir.

---

## 9.6 Sayfa 6 — Abonelik Ekonomisi ve Birim Ekonomisi

Bu sayfa MRR, revenue, ARPU, CAC, LTV, LTV/CAC, payback, aktif abone, channel bazlı LTV/CAC, watcher LTV ve kategori LTV gibi unit economics metriklerini içerir.

| Bileşen | SQL / Data Source | Açıklama |
| --- | --- | --- |
| MRR | `BC_UNIT_ECONOMICS_DAILY_01` | Month-end recurring revenue mantığıyla hesaplanır. |
| Son 1 Aylık Toplam Gelir | `BC_UNIT_ECONOMICS_DAILY_01` | Seçili dönemdeki net revenue. |
| ARPU | `BC_UNIT_ECONOMICS_DAILY_01` | Net revenue / active subscribers. |
| CAC | `BC_CAC_MONTHLY_01` | `ads_daily_spend` primary spend source ve attributed first paid users mantığıyla hesaplanır. |
| LTV/CAC Ratio | `BC_LTVCAC_REALIZED_MONTHLY_01` | Realized LTV / CAC oranı. |
| CAC Payback Period | `BC_LTVCAC_REALIZED_MONTHLY_01` | CAC / ARPU yaklaşımıyla hesaplanır. |
| Forecast LTV | `BC_FORECAST_LTV_MONTHLY_01` | ARPU × average lifetime months mantığında forecast LTV üretir. |
| Realized LTV | `BC_REALIZED_LTV_MONTHLY_01` | Gerçekleşmiş net revenue üzerinden realized LTV. |
| Son 3 Ay ile Karşılaştırma | `BC_UNIT_ECONOMICS_DAILY_01` | Aylık toplam gelir ve aktif abone karşılaştırması. |
| LTV Trend | `BC_REALIZED_LTV_MONTHLY_01` | Aylık realized LTV trendi. |
| Ortalama Kullanıcı Ömrü | `BC_FORECAST_LTV_MONTHLY_01` | Forecast modelindeki lifetime estimate. |
| Gün Bazlı Aktif Abone | `BC_UNIT_ECONOMICS_DAILY_01` | Günlük aktif abone trendi. |
| Aylık CAC Channel | `BC_CAC_MONTHLY_01` | Kanal bazında aylık CAC. |
| Geriye Dönük Analiz | `BC_LTVCAC_REALIZED_MONTHLY_01` | Ay bazında ratio status, realized LTV, CAC ve LTV/CAC. |
| Channel Bazlı LTV | `BC_CHANNEL_LTVCAC_REALIZED_01` | Channel kırılımında average realized LTV. |
| Channel Bazlı LTV/CAC | `BC_CHANNEL_LTVCAC_REALIZED_01` | Channel kırılımında LTV/CAC ratio. |
| Heavy Watcher Ödeme Aracı Dağılımı | `BC_HEAVY_PAYMENT_DISTRIBUTION_01` | Heavy watcher segmentinin payment option dağılımı. |
| Heavy vs Light Watcher LTV | `BC_WATCHER_LTV_02` | Heavy ve Light watcher segmentlerinin LTV karşılaştırması. |
| Kategori Bazlı LTV | `BC_CATEGORY_LTV_02` | İlk izlenen kategoriye göre LTV dağılımı. |

---

## 9.7 Sayfa 7 — Kampanya Performansı

Bu sayfa organik ve kampanya cohort'larını unit economics perspektifinden karşılaştırır. Ana SQL `BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02` olarak kullanılır.

| Bileşen | SQL / Data Source | Açıklama |
| --- | --- | --- |
| Organik / Kampanya KPI Kartları | `BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02` | `cohort_type = normal / campaign` ayrımıyla LTV, CAC, payback, ARPU ve LTV/CAC metriklerini üretir. |
| Kümülatif Gelir Grafiği | `BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02` | Lifetime month bazında cumulative revenue/LTV. |
| LTV Grafiği | `BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02` | Lifetime month bazında LTV. |
| Müşteri Kayıp Oranı Grafiği | `BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02` | Lifetime month bazında churn rate. |

---

## 9.8 Sayfa 8 — Kampanya Bazlı Abone ve Performans

Bu sayfa kampanya/promosyon kullanımı, aktif abone, yeni abone, churn ve devam eden abone gibi metrikleri kampanya kırılımında gösterir.

| Bileşen | SQL / Data Source | Açıklama |
| --- | --- | --- |
| Kampanya Bazlı Abone ve Performans Bar Chart | `BC_PROMOTION_ACTIVE_USABLE` | Kampanya bazında toplam kullanım, aktif abone, iptal eden abone ve devam eden abone metrikleri. |
| Kampanya Kırılımlı Aktif Abone Dağılımı | `BC_PROMOTION_ACTIVE_USABLE` | Aktif abonelerin kampanya dağılımı. |
| Kampanya Kırılımlı Günlük Abone Kazanımı | `BC_PROMOTION_ACTIVE_USABLE` | Günlük yeni abone kazanımı dağılımı. |
| Kampanya Kırılımlı İptal Eden Abone Dağılımı | `BC_PROMOTION_ACTIVE_USABLE` | İptal eden abonelerin kampanya dağılımı. |
| Promosyonlu Ödemelerde Ödeme Aracı Dağılımı | `PromotionInfo` | Promosyonlu ödeme yapan kullanıcıların payment option dağılımı ve minimum 1 ay ödeme yapma metriği. |
| Isı Haritalı Kampanya Tablosu | `BC_PROMOTION_ACTIVE_USABLE` | Kampanya bazında kullanım, aktif abone, yeni abone, iptal ve conversion metrikleri. |

---

## 9.9 Sayfa 9 — Kampanya Performansı Analizi

Bu sayfa özellikle 3 aylık kampanya performansını kampanya, platform, günlük detay ve izleme davranışı kırılımlarıyla gösterir. Ana SQL `BC_3MONTH_CAMPAING` olarak kullanılır.

| Bileşen | SQL / Data Source | Açıklama |
| --- | --- | --- |
| Kampanya Kırılımlı Abone Kazanımı | `BC_3MONTH_CAMPAING` | Kampanya detayına göre toplam kullanım dağılımı. |
| Platform Kullanım Dağılımı | `BC_3MONTH_CAMPAING` | Web, iOS, Android, TV platform kullanım dağılımı. |
| Günlük Kampanya Detay Analizi | `BC_3MONTH_CAMPAING` | Gün, kampanya ve platform kırılımında kullanım, aktif abone, yeni abone, churn, conversion, unique watcher ve ortalama izleme süresi. |
| Kampanya KPI Kartları | `BC_3MONTH_CAMPAING` | GAIN3AY, GS, FB ve BJK gibi kampanya kartlarının aktif abone, yeni abone, iptal, devam eden abone, tekil izleyici ve ortalama izleme süresi metrikleri. |

---

## 9.10 Looker Mapping Özeti

Looker Studio tarafındaki genel yapı şu şekilde okunmalıdır:

- Sayfa 1 abonelik ve kullanıcı KPI'larının günlük operasyonel özetidir.
- Sayfa 2-4 içerik performansı, izleme davranışı, abonelik dönüşümü, kategori tercihi ve retention analizlerini kapsar.
- Sayfa 5 şimdilik placeholder'dır.
- Sayfa 6 unit economics ve finansal/verimlilik KPI'larını içerir.
- Sayfa 7 kampanya ve organik cohort ekonomisini karşılaştırır.
- Sayfa 8 kampanya/promosyon bazlı aktiflik, churn ve conversion performansını gösterir.
- Sayfa 9 3 aylık kampanya performansının günlük, platform ve izleme davranışı kırılımlarını verir.

Bu mapping, dashboardda görünen bir KPI veya grafiğin hangi SQL'e ve dolayısıyla hangi BigQuery tablolarına dayandığını takip etmek için referans olarak kullanılmalıdır.

---

## Sayfa 1 — Kullanıcı Raporları

### KPI Kartları

Aynı SQL'i kullanan KPI'lar Looker içinde rownum/metric filtreleriyle ayrıştırılır.

| KPI                               | SQL / Data Source                  | Açıklama                                                                                           |
| --------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------- |
| Toplam Abonelik                   | `Daily_Report_Metrics_Single_Data` | T-1 `Daily_Report_Metrics` row'ları içinden ilgili rownum/metric.                                  |
| İptal Edilen Abonelik             | `Daily_Report_Metrics_Single_Data` | T-1 dashboard kartı.                                                                               |
| 7 Günlük Denemede Olan Aboneler   | `Daily_Report_Metrics_Single_Data` | Trial kullanımı / devam eden deneme KPI'ı.                                                         |
| Hediye Kart Kullanmış Aboneler    | `PREPAIDUSER`                      | Legacy Elastic + subs\_payment üzerinden payment\_option prepaid filtreli kullanıcılar.            |
| Ücretli Abonelik                  | `PAIDUSER`                         | Daily\_Report\_Metrics row'larından selected row toplamları ve prepaid count düşülerek hesaplanır. |
| Yeni Abonelik Satın Alan          | `Daily_Report_Metrics_Single_Data` | T-1 yeni satış KPI.                                                                                |
| Grace Period Sürecindeki Aboneler | `Daily_Report_Metrics_Single_Data` | Grace kullanıcı KPI.                                                                               |
| Promosyon Kullanmış Aboneler      | `Daily_Report_Metrics_Single_Data` | Promotion kullanmış ücretli abone KPI.                                                             |

### Abonelik Genel Durum Grafikleri

| Grafik                   | SQL / Data Source                    | Alanlar                                           |
| ------------------------ | ------------------------------------ | ------------------------------------------------- |
| Toplam Abonelik          | `Daily_Report_Metrics`               | `time_id`, `Total`, `rownum`, comparison alanları |
| Ücretli Abonelik         | `Daily_Report_Metrics_Ucretli`       | Ücretli abonelik trendi                           |
| Yeni Abonelik Satın Alan | `Daily_Report_Metrics_Yeni_Abonelik` | Yeni satış trendi                                 |
| İptal Edilen Abonelik    | `Daily_Report_Metrics_Iptal`         | İptal trendi                                      |

---

## Sayfa 2 — İçerik Genel Durum / Performans ve İzlenme

Varsayılan tarih filtresi: bugün dahil son 7 gün.

| Bileşen                         | SQL                  | Alanlar / Açıklama                                                                                   |
| ------------------------------- | -------------------- | ---------------------------------------------------------------------------------------------------- |
| Filtreler ve performans tablosu | `SezonBolum_izlenme` | `content_name`, `sezon`, `bolum`, `icerik_turu`, `kategori`, `gain_original`, `user_cnt`, `view_cnt` |
| Genel                           |                      |                                                                                                      |
