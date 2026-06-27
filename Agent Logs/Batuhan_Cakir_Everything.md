# Batuhan Çakır — Kapsamlı Bağlam Dosyası

> Son güncelleme: 26 Haziran 2026
>
> Amaç: Bu dosya Claude Code veya başka bir AI asistana verilmek üzere,
> Batuhan'ın teknik çalışma bağlamını, kişisel tercihlerini, iletişim stilini
> ve iş alanına dair tüm bilinen bilgileri tek yerde toplar.
>
> Kaynak: ChatGPT ve Codex oturumlarından derlenen 14 ayrı MD dosyası + ekleri.
>
> Önemli uyarı: Tarihli finansal rakamlar, kilo/ağırlık bilgileri, adres,
> abonelik fiyatları ve benzeri değişken veriler güncel gerçek kabul edilmemeli;
> gerekiyorsa Batuhan'a tekrar sorulmalıdır.

---

## BÖLÜM 1 — KİŞİSEL PROFİL

- Adı: **Batuhan Çakır**
- Tercih edilen hitap: "Çakır", samimi konuşmalarda "kanka", "aga", "agacim", "dayi", "bro"
- Doğum tarihi: 1 Ocak 2002
- Yaşadığı yer: İstanbul
- macOS kullanıcı adı: `batuhancakir`
- Dijital rumuz: `Rheadric`
- Sosyal medya (tarihsel — güncel durumu doğrulanmalı):
  - Steam: `vscakir123`
  - YouTube: `@Rheadric`
  - Twitch: `Rheadricc`
  - Instagram: `Rheadric`
- Meslek: Yazılım Mühendisi / Data & BI Engineer
- Şirket: **GAİN** dijital yayın platformu
- Ekip: Product Team içinde veri/BI sorumluluğu

---

## BÖLÜM 2 — İLETİŞİM VE YAZIM TARZI

### Günlük iletişim

- Türkçe konuşur.
- Mesajları doğal, konuşma dilinde ve zaman zaman küfürlüdür. Küfür samimiyet/mizah ifadesidir; saldırı değil.
- Kısa komutlarla ilerleyebilir: "Kanka şunu düzeltsene.", "Bir baksana.", "Bunu BQ'de çalışacak hale getir.", "Aga son halini yolla."
- Eksik bağlamla mesaj atabilir; önceki kararlar biliniyorsa kullanılmalı, bilinmiyorsa uydurulmamalı.
- Uzun açıklama istese bile metnin gereksiz dolguyla uzamasını istemez.
- Beklenti: **teknik doğruluk + sade dil + net sonuç**

### Asistandan beklenen ton

- Samimi, rahat, doğrudan
- Kurumsal robot gibi konuşulmamalı
- Aşırı övgü, yapay motivasyon cümleleri, kalıp teklifler kullanılmamalı
- Hata yapıldıysa kıvırmadan söylenmeli: "Burada ben yanlış okumuşum.", "Bu varsayım tutmuyor."
- Batuhan haklıysa açıkça kabul et; yanlış varsayım varsa nazik ama net düzelt
- Emin olunmayan konu kesinmiş gibi anlatılmamalı

### Profesyonel yazım (dokümanlarda)

- Net ve kurumsal ama okunabilir
- Problem / amaç / kapsam / teknik detay / beklenen çıktı ayrımı
- Adlandırma mantığı: `[Kaynak] + [işlem] + [çıktı]`
  - Örnek: `Python Veri Pipeline Süreçlerinin Airflow ve BigQuery Altyapısına Entegre Edilmesi`
- Dokümanlar yeni bir analist/developer okuyunca sistemi anlayacak kadar teknik olmalı

---

## BÖLÜM 3 — ÇALIŞMA PROTOKOLÜ (Claude Code / Codex için)

Bir iş geldiğinde sırayla:

1. Talebin kod değişikliği mi, analiz mi, araştırma mı olduğunu belirle.
2. Repo/dosya erişimi varsa ilgili dosyaları oku.
3. Mevcut schema ve iş kurallarını kontrol et.
4. Önceki kararlarla çelişen durum varsa belirt.
5. Dar kapsamlı ve uyumlu değişikliği uygula.
6. Syntax/test/çalışmayı mümkün olduğunca doğrula.
7. Sonucu Batuhan'ın diline uygun, kısa ve açık anlat.

Kesin kurallar:

- "Düzelt" denildiğinde öneri değil dosyayı gerçekten düzenlemek beklenir.
- Mevcut kodun çalışan yapısı korunmalı; gereksiz refactor yapılmamalı.
- Batuhan'ın başka değişiklikleri varsa geri alınmamalı.
- Test edilmeden "çalışır" denilmemeli.
- Eski dosyayı yeni dosya sanma.
- Aynı dosyanın tamamını sohbete basmak yerine dosyayı düzenle ve yolu ver.

Son cevapta mutlaka: neyin değiştiği / neden değiştiği / test edilip edilmediği / bir sonraki adım.

---

## BÖLÜM 4 — TEKNİK YETKİNLİKLER VE ARAÇLAR

### Aktif teknolojiler

- **BigQuery** (Standard SQL) — ana data warehouse
- **Looker Studio** — dashboardlar
- **Python** (`requests`, `pandas`, Google Cloud client libs)
- **Apache Airflow** — AWS MWAA 2.10.1
- **AWS S3** — DAG ve script depolama
- **REST API entegrasyonları** (Postman, Swagger/OpenAPI, JWT/Bearer token)
- **GA4**, Google Ads, Meta Ads / AdInsights
- **Apple App Store Connect API**, Google Play Console raporları
- **Git**, VS Code, macOS terminali
- `.env`, virtualenv/venv, zaman zaman conda
- Jira, Confluence, Notion
- Excel, Google Sheets
- FastAPI, PostgreSQL, SQLAlchemy (çalışma bağlamı)

### Yerel çalışma alışkanlıkları

- MacBook Pro M3 + VS Code
- Proje dizini: `~/GAIN_API_QUERY` (geçmişte kullanılan)
- Scriptleri terminalden sanal ortam açarak çalıştırır
- Lokal test → CSV çıktı alma → BQ'ye yazmadan önce veriyi kontrol
- Python scriptlerinde açık, izlenebilir log tercih eder
- Token/credential kod içine gömülmemeli; Airflow Variables, S3 token store veya env var kullanılmalı

---

## BÖLÜM 5 — GAİN İŞ BAĞLAMI

GAİN bir dijital yayın platformudur. Batuhan'ın ana çalışma alanları:

- Abonelik ve ödeme analitigi
- Aktif abone, ücretli abone ve churn tanımları
- Retention ve winback
- LTV, CAC, ARPU, MRR ve birim ekonomisi
- Kampanya dönüşümü ve promosyon attribution
- Ödeme sağlayıcı dağılımı
- İçerik izleme analizi
- Kullanıcı profilleri ve kids profili analizi
- Reklam harcamaları ve pazarlama attribution
- App Store ve Google Play gelirleri
- Veri pipeline'larının Airflow ve BigQuery'ye taşınması
- Looker Studio dashboard tasarımı
- Teknik veri dokümantasyonu (v0.1'den v1.1'e kadar yazdı)

---

## BÖLÜM 6 — BIGQUERY TABLOLARI VE DATASETLER

> Schema değişebilir. SQL yazmadan önce doğrula.

### Abonelik ve kullanıcı

```
microgain-9f959.aws_s3_to_bq_migration.subs_payment
  → user_id, status, payment_option, amount, currency,
    created_at, valid_until, free_trial_start_date,
    free_trial_end_date, subscription_plan_id,
    grace_until, hold_until, inserted_date

microgain-9f959.looker_report.elastic_active_user
  → user_id, subscription_plan_id, status, valid_until, created_at
```

### İçerik ve izleme

```
microgain-9f959.looker_report.content_report_streaming_V2
  → user_id, video_id, watch_time_second, device, event_date

microgain-9f959.Backoffice_metadata.ContentMetaData
  → video_id, displayname, contenttype_id, genres
```

### Promosyon

```
microgain-9f959.Backoffice_metadata.bo_promotions
  → promotionId, name, type, isActive, başlangıç/bitiş alanları
  Promo türleri: MASS, UNIQUE, USER_GROUP, PREPAID
```

### Günlük metrik

```
microgain-9f959.looker_report.Daily_Report_Metrics
  → metric, date, value
```

### Ödeme sağlayıcıları ve finans

```
microgain-9f959.bc_t.iyzico_transactions_raw
microgain-9f959.bc_t.payguru_transactions_raw
microgain-9f959.bc_t.google_play_estimated_sales_raw
microgain-9f959.bc_t.tcmb_exchange_rates_raw
microgain-9f959.bc_t.googleplay_transactions_raw   (yeni — GAIN 215)
microgain-9f959.bc_t.apple_transactions_raw        (yeni — GAIN 215)
Param, Paynkolay, Craftgate → ilgili raw/mart tablolar
```

### Marketing

```
bc_marketing_marts.ads_daily_spend       ← aktif CAC kaynağı
bc_marketing_raw.manual_monthly_spend    ← legacy/historical
GA4 attribution tabloları
Google Ads hesabı: 6861382209
Meta AdInsights transferleri
```

### Profil analizleri

```
microgain-9f959.bc_t.user_kids_profile_state
microgain-9f959.bc_t.active_subscribers_snapshot
microgain-9f959.bc_t.multi_profile_counter
  → run_date, scanned_accounts, total_profiles,
    avg_profiles_per_account, multi_profile_users,
    single_profile_users, valid_until_from_date, query_hash
```

### Finans dashboard SQL'leri (GAIN 215 projesi)

```
BC_UNIT_ECONOMICS_DAILY_01
BC_FORECAST_LTV_MONTHLY_01
BC_REALIZED_LTV_MONTHLY_01
BC_CAC_MONTHLY_01
BC_LTVCAC_REALIZED_MONTHLY_01
BC_WATCHER_LTV_02
BC_PAYMENT_METHOD_DISTRIBUTION_01
BC_HEAVY_PAYMENT_DISTRIBUTION_01
BC_CHANNEL_LTVCAC_REALIZED_01
BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02
BC_3MONTH_CAMPAING
BC_ADS_DAILY_SPEND_UNIFIED_01
BC_PAYMENT_PROVIDER_KPIS_01
```

---

## BÖLÜM 7 — İŞ KURALLARI (ABONELİK VE FİNANS)

### Gerçek ücretli abonelik filtresi

```sql
amount >= 101            -- veya kuruş bazlı: COALESCE(amount, amount_before_promotions, 0) > 101
payment_option != 'PREPAID'
subscription_plan_id IS NOT NULL
```

### Abonelik statüleri

| Statü | Anlam |
|---|---|
| `ACTIVE` | Ücretli, aktif |
| `CANCELED` | Yenilemeyi kapattı ama valid_until gelmemişse hâlâ ücretli |
| `IN_GRACE` | Ödeme alınamadı, kayıp eşiğinde |
| `ON_HOLD` | Ödeme alınamadı, kayıp eşiğinde |
| `EXPIRED` | Kaybedildi |

**Finans tanımı:** Kayıp = `EXPIRED + IN_GRACE + ON_HOLD`

### Ücretli abone (günlük)

```
created_at <= gün <= valid_until
```

Dashboard terminolojisi: **"Aktif Abone"** değil **"Ücretli Abone"** kullanılmalı.

### Churn

- Genel: `today > valid_until` ve artık aktif statüde değil
- Core daily SQL'de: son gerçek ücretli kaydın statüsü `ACTIVE` veya `CANCELED` değilse, `valid_until_date` churn tarihi
- Ana churn KPI'ı: `churned_paid_subscriber_count` (akış metriği, SUM alınabilir)
- `expired_status_subscriber_count` ≠ `churned_paid_subscriber_count`

### First paid ve cohort

- Cohort başlangıcı: `first real paid date`
- PREPAID ve düşük tutarlı ödemeler (< 101) cohort'a girmez
- Attribution: first paid tarihinden önceki 30 gündeki son uygun non-direct touch

### Komisyon oranları

| Sağlayıcı | Oran |
|---|---|
| App Store | %30 |
| Play Store | %15 |
| Mobile/Payguru | %15 |
| Iyzico | %3 |
| Craftgate | %0 (legacy) |
| Prepaid | %0 |

KDV finans SQL'lerine dahil **edilmez**. Net = Brüt − ödeme kuruluşu komisyonu.

### Döviz

- TCMB kuru tablosu: `tcmb_exchange_rates_raw`
- Store ödemeleri bazı tablolarda zaten TRY'ye çevrilmiş olabilir; ikinci kez kur uygulanmaz
- `total_revenue_tl` ile `net_revenue_tl` ayrımı önemli

### Test kayıtları

- `valid_until` bugünden 2 yıldan ileride olan kayıtlar (ör. 2124-01-01) subs_base seviyesinde tüm SQL'den çıkarılır

---

## BÖLÜM 8 — CORE CHURN/RETENTION SQL (BC_CHURN_RETENTION_CORE_DAILY)

Dosya: `BC_CHURN_RETENTION_CORE_HEALTH.sql`
Grain: 1 satır = 1 gün, tek tarih alanı: `date`
Looker parametreleri: `@DS_START_DATE`, `@DS_END_DATE`

### Çıktı alanları

```
date
subscriber_count
paid_subscriber_count
churned_paid_subscriber_count
canceled_subscriber_count
grace_period_subscriber_count
active_status_subscriber_count
in_grace_status_subscriber_count
on_hold_status_subscriber_count
expired_status_subscriber_count
avg_subscription_tenure_month
```

### Kurallar

- `subscriber_count`: statü boş değil VE EXPIRED değil
- `paid_subscriber_count`: ACTIVE + CANCELED, valid_until_date >= date
- `grace_period_subscriber_count`: IN_GRACE + ON_HOLD, ilgili grace/hold bitiş tarihine kadar
- `avg_subscription_tenure_month`: ilk gerçek ücretli tarihten bugüne gün / 30.4375 (= 365.25/12)
- `paid = active_status + canceled_subscriber` eşitliği her zaman kontrol edilmeli

### 31 Mayıs 2026 test sonucu

```
subscriber_count              = 121.835
paid_subscriber_count         = 118.333
churned_paid_subscriber_count =     386
canceled_subscriber_count     =   7.056
grace_period_subscriber_count =   3.321
active_status_subscriber_count = 111.277
in_grace_status_subscriber_count =  2.285
on_hold_status_subscriber_count  =  1.036
expired_status_subscriber_count  =    349
avg_subscription_tenure_month    =  10.88
```

### Dashboard kuralı

- Stok metrikleri tarih aralığında **SUM yapılmamalı** → seçili aralığın son günü gösterilmeli
- `churned_paid_subscriber_count` akış metriğidir → SUM alınabilir

---

## BÖLÜM 9 — FİNANS DASHBOARD (GAIN 215) — ÖZET VE AÇIK İŞLER

### Tamamlandı ✅

- Google ve Apple raw BQ tablo SQL'leri
- Lokal (CSV) / Airflow (BQ) çalışma ayrımı; S3 scriptlerinden dotenv kaldırılması
- Airflow Variable tabanlı credential aktarımı
- Slack Incoming Webhook (`#airflow_notify`), success/failure callback
- Vergi düşümünün SQL'lerden kaldırılması
- Unit economics temel metrik düzeni (ARPU, MRR, tahsilat ayrımı)
- Forecast LTV ve Realized LTV mantığı
- Heavy/Light (ilk 30 gün izleme) LTV düzeni
- İkinci sayfa SQL/veri kaynağı eşleştirmesi
- Üçüncü sayfa kampanya ekonomisi formülleri
- BC_3MONTH_CAMPAING ana SQL düzeltmeleri
- Provider-only ilk 5 KPI SQL'i (Apple, Google, Iyzico, Payguru)

### Devam eden ⏳

- Meta ve Google Ads backfill (hedef: 1 Temmuz 2025 – 23 Haziran 2026)
  - Hedef tablo: `bc_marketing_marts.ads_daily_spend`
  - 25 Haz 2026 durumu: Meta ~172/358, Google ~186/358
- Backfill tamamlanınca: `BC_ADS_DAILY_SPEND_UNIFIED_BACKFILL.sql` MERGE

### Kritik riskler

- Attribution coverage düşük: Şubat 2026'da yalnız ~%18,4 attributed
- Meta attributed user çok az (2 kullanıcı vs ₺63.615 harcama) → veri kalite uyarısıyla sunulmalı
- Bazı günler streaming kaynağında hiç veri yok (upstream sorun)
- Repo dirty worktree — toplu revert/reset yapılmamalı
- Looker cache: SQL değişince "Alanları yenile" çalıştırılmalı

### CAC/LTV doğrulanmış son rakam (Şubat 2026 — son olgun cohort)

```
Attributed yeni ücretli kullanıcı: 1.568
Toplam reklam harcaması:          ₺207.587,43
Cohort CAC:                        ₺132,39
İlk 3 aylık realized LTV:         ₺850,11
LTV/CAC:                            6,42
CAC payback:                        0,47 ay
```

---

## BÖLÜM 10 — AIRFLOW VE ETL

### Ortam

- AWS MWAA Airflow 2.10.1
- DAG ve script dosyaları S3 bucket: `gain-data-airflow-bucket`
- S3 path'leri: `airflow-dags/`, `python_scripts/`, `airflow_keys/`
- `.env` bağımlılığı prod scriptlerden kaldırıldı
- Airflow Variables JSON ile yönetiliyor
- Token yönetimi S3'te `token_store.json` ile

### Çalışma modeli

- Günlük akışlarda T-1 verisi
- Aynı tarihi silip yeniden ekleme (idempotent)
- Snapshot tablolarda günlük append
- Duplicate riski olan tablolarda staging + MERGE/upsert

### Otomatize akışlar

Kids profile metrics, Iyzico, Param, Payguru, Paynkolay, TCMB döviz kuru, Multi-profile counter, Google Play estimated sales, Apple Store, Google Ads, Meta Ads, Google/Apple transactions (GAIN 215)

### Slack bildirimleri

- Connection ID: `slack_default`
- Kanal: `#airflow_notify`
- Callback dosyası: `slack_callbacks.py` (DAG ile aynı klasörde olmalı)

### Sağlayıcı notları

- Param verisi Mayıs 2025 sonrasında olmayabilir
- Payguru günlük iki satır, `merchantId = 3031`
- TCMB akışı günlük 50+ kur getirebilir

---

## BÖLÜM 11 — BACKOFFICE API

Sık kullanılan endpointler:

```
/CALL/User/getUserList/default
/CALL/User/getUserDetailForBo/{user_id}
```

Bilinen davranışlar:

- User list `page_size <= 100`
- Yanıtta `meta.total`, `perPage`, `totalPage`
- Detail yanıtında `profiles[]` var
- Kids profil tespiti: `profileType == "KID"` veya `isKidProfile == true`
- `subs_payment.status` abonelik statüsü; account statüsüyle karıştırılmamalı

Profil tarama: 5,4 milyon hesap 8-10 saat alıyordu. Hedef: günlük 30 dk–2 saat. Çözüm: BigQuery'den `validUntil >= T-90` listesi alıp sadece bu kullanıcılar için detail endpoint çağır.

---

## BÖLÜM 12 — SQL YAZIM KURALLARI

Her SQL'de kontrol listesi:

1. Grain'i yaz (1 satır ne ifade ediyor?)
2. Tarih alanının anlamını yaz
3. Stok ve akış metriklerini ayır
4. `COUNT(DISTINCT user_id)` gerekip gerekmediğini kontrol et
5. Null, duplicate ve join çoğalmasını kontrol et
6. TRY/PREPAID/amount/status filtrelerini kontrol et
7. Test veya anomalik hesapları kontrol et (2124 yılı gibi)
8. Looker aggregation davranışını belirt (SUM mu MAX mı?)

---

## BÖLÜM 13 — LOOKER STUDIO TERCİHLERİ

- Stok metrikler tarih aralığında **SUM yapılmaz**; son gün gösterilir
- Akış metrikler (churn gibi) SUM alınabilir
- Ratio alanları satır bazında toplanmaz
- Numeric alan (sıralama için) ile görünen label ayrılmalı
- Tarih filtresi ve veri grain'i her SQL'de açık olmalı
- Bir SQL'de tek tarih alanı tercih edilir
- Dashboard fazla kalabalıklaştırılmaz

---

## BÖLÜM 14 — İÇERİK ANALİTİĞİ KARARLARI

- Tekil içerik ve genre toplamları **ayrı** hesaplanır
- `content_name` ve `genre` ayrı aggregation mantığına sahip olmalı
- Heavy segmentinde günlük 24 saatin üzerinde izleme engellenmeli
- Light segmentinde 1 dakikanın altındaki izlemeler dahil edilmemeli
- Kullanıcı bazında abonelik başlangıcına yakın ilk izleme davranışı analiz edilebilir

---

## BÖLÜM 15 — BATUHAN'IN SEVMEDIĞI ÇALIŞMA BİÇİMLERİ

- Dosyayı okuyabilecekken tekrar kendisine yapıştırtmak
- Aynı hatalı çözümün küçük değişikliklerle yeniden verilmesi
- `.env` kaldırılması istenmişken kodun hâlâ dotenv araması
- Schema görüntüsü verilmişken olmayan kolon adları uydurmak
- `created_at` yokken `created_at` kullanmak
- Test etmeden "çalışır" demek
- Eski dosyayı yeni dosya sanmak
- Gereksiz refactor ile çalışan kısımları bozmak
- Sadece teorik plan verip dosyayı düzeltmemek
- Çok uzun, tekrarlı ve sonuca varmayan açıklamalar
- "Paid", "active", "subscriber", "churn" kavramlarını birbirine karıştırmak
- Looker'da stok metriğini SUM'layarak şişirilmiş sonuç üretmek

## BÖLÜM 16 — BATUHAN'IN BEĞENDİĞİ ÇALIŞMA BİÇİMLERİ

- Önce kodu ve schema'yı okumak
- Sorunu kendi cümleleriyle doğru biçimde geri kurmak
- Çalışan dosyayı doğrudan düzeltmek
- Değişiklikleri sınırlı ve gerekçeli yapmak
- Kısa kontrol sorguları ile hipotez test etmek
- Mayıs 2026 gibi sabit test ayları kullanmak
- CSV çıktı alıp trend, toplam ve eşitlik kontrolü yapmak
- `paid = active + canceled` gibi ara toplamlarla mantık doğrulamak
- Hata yapıldığında doğrudan kabul etmek
- Sonraki adımı net bir şekilde belirlemek

---

## BÖLÜM 17 — KİŞİSEL HAYAT

### Semanur Özdemir (partner/nişanlı)

- İlişki başlangıcı: 21 Ağustos 2025
- Evlilik hedefi: 2027
- Doğum tarihi: 19 Temmuz 1999 | İstanbul | Aile kökeni: Rize
- Meslek: Avukat (yaklaşık 3. yıl)
- Türk-Alman Üniversitesi'nde yüksek lisans
- Batuhan bazen "Sema" veya "Sem" der
- 2025 Audi Q2 35 TFSI 150 hp aracı var

### Günlük düzen

- Ofis: 09:00–18:00
- Sabah: 08:00 civarında kalkış; SleepCycle akıllı alarm 07:40–08:10, yedek 08:20
- Tipik spor akşamı (kötü senaryo): 19:15 eve varış → 20:15–20:30 çıkış → 20:50 spor salonu → ~1.5 saat antrenman → 22:20 çıkış → 22:45 Semanur'u bırakma → 23:10 eve dönüş → 00:30 yatışa hazır

### Fitness (değişken — yeni plan öncesi sor)

- Boy: ~175 cm | Geçmiş ağırlık: 65–66 kg | Hedef: 70–72 kg, düşük yağ oranı
- Hipertrofi odaklı çalışır
- Sevmedikleri: bench press, klasik squat, deadlift
- Sevdikleri: cable overhead triceps extension, Egyptian lateral raise
- Lying leg raise tercih (hanging yerine); ab rollout programdan çıkarıldı
- Cuma ve Pazar dinlenme günleri

---

## BÖLÜM 18 — ARAÇLAR VE CİHAZLAR

### Motosikletler

- **Honda ADV 350** (2025) — günlük/pratik; Metzeler Karoo Street lastik
- **KTM RC 390** (2024, Aralık 2024 tescilli) — sportif/keyif; quickshifter var; ~4000 km

### Cihazlar

- MacBook Pro M3
- iPhone, iPad + Apple Pencil
- Apple Watch Ultra
- Windows masaüstü bilgisayar
- SteelSeries Arctis Nova Pro Wireless
- Anker B2697 140W adaptor
- DJI Osmo Action 4
- Monster Aryond A32 monitör (panel arızası yaşandı)

---

## BÖLÜM 19 — OYUN VE HOBİ

- Steam kullanıcısı (`vscakir123`); kütüphanesinde ~195 oyun, seviye 10
- Oyun değerlendirmesinde yorum değil oynama saati + achievement tamamlama oranı önemli
- Grind'dan kaçmaz ama 10 saat grind + 24 saatlik yapay craft bekleme sevmez (Warframe örneği)
- RPG, survival, hikaye tabanlı oyunlar; Witcher evreni sevgisi
- Dungeons & Dragons ilgisi var; elf rogue karakteri → `Retinol Feridun` (ironik mizah)
- İçerik üreticisi geçmişi: `Rheadric` adıyla, `Ehvenisers` serisi (30+ bölüm)
- Karanlik fantasy isimleri sever: `Morvane the Pale`, `Ravenor Blackveil`, `Valen Nightreign`

---

## BÖLÜM 20 — SATIN ALMA VE ARAŞTIRMA TARZI

- Sadece teknik özellik listesi istemez
- Reddit, forumlar, mağazalar ve uzun vadeli kullanıcı yorumları incelenmesini ister
- Türkiye'deki fiyat ve stok önemli
- Alternatifler fiyat/performans açısından karşılaştırılmalı
- Zaten sahip olduğu ürün ve abonelikler hesaba katılmalı
- Sonunda net karar istenir: "almaya değer mi, değmez mi?"

Mevcut abonelikler (Haziran 2026 — fiyatlar değişebilir):

- Netflix Premium, Amazon Prime, YouTube Premium
- Ev internetinden TV+ ve HBO/Max dahil olabilir

---

## BÖLÜM 21 — FİNANS VE KRİPTO BAĞLAMI

- Kripto ve kaldıraçlı işlemlerle ilgisi var
- Finansal sorularda gerçek zamanlı veri olmadan fiyat veya yönlendirme verilmemeli
- Risk, liquidation ve pozisyon boyutu açıkça belirtilmeli
- Heyecanlı dille konuşsa bile kesin kazanç vaadi verilmemeli

---

## BÖLÜM 22 — EĞİTİM BAĞLAMI

- Haziran 2026'da algoritmalar, araştırma yöntemleri ve Yesevilik derslerinden sınav hazırlığı
- Öğrenme biçimi: önce soru çöz, yanlış üzerinden hedefli açıklama al
- Sort yöntemleri, Big-O notasyonu (O(log n) gibi) kısa özet formatı tercih edilir
- Türkçe/dil ödevlerinde format: `kelime → değişim → ses olayının adı`

---

## BÖLÜM 23 — GİZLİLİK — ASLA SAKLANMAMASI GEREKENLER

Aşağıdakiler Claude Code'a, AGENTS.md'ye veya repoya yazılmamalıdır:

- Bearer tokenlar, JWT'ler, API secretları
- Service account private key'leri
- Banka/kart/ekstre ayrıntıları
- Açık ev adresi
- Kimlik numaraları
- Üretim ortamında kullanılan gizli endpoint parametreleri

---

## BÖLÜM 24 — DEĞİŞKEN — GÜNCELLENMESİ GEREKEN BİLGİLER

Yeni bir istekte tekrar teyit edilmeli:

- Kilo, yağ oranı ve fitness programı
- Semanur'un güncel fitness verileri
- Aktif abonelik servisleri ve fiyatları
- Araç kilometreleri
- Kullanılan telefon/iPad modeli
- GAİN schema ve tablo alanları
- Komisyon ve vergi oranları
- Kampanya ID'leri ve aktif kampanyalar
- Airflow DAG schedule'ları
- Ödeme sağlayıcılarının güncel davranışı
- İş unvanı ve ekip organizasyonu
- Kripto pozisyonları
- Güncel gelir ve finansal durum

---

## BÖLÜM 25 — SON ÖZET

Batuhan teknik olarak güçlü, detayları sorgulayan ve sonuca odaklı bir veri/yazılım mühendisidir. İşinin önemli bir bölümü ham veriyi çekmekten ibaret değildir; iş kuralını doğru tanımlamak, pipeline'ı güvenilir hale getirmek, BigQuery'de doğru grain ile modellemek ve Looker Studio'da yanlış aggregation'a izin vermeden sunmaktır.

Onunla iyi çalışmak için:
- Bağlamı hatırla
- Dosyayı oku
- İş kuralını teyit et
- Gereksiz şeyleri bozma
- Gerçekten uygula
- Test et
- Hatayı gizleme
- Sonucu sade anlat

Samimi konuşması ciddiyetsizlik anlamına gelmez. Kodun, verinin ve metriklerin doğruluğuna yüksek önem verir.
