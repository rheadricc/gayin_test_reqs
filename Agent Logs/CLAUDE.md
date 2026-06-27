# CLAUDE.md — GAİN API Query Repo Bağlam Dosyası

> Bu dosyayı her oturumun başında oku. Gereksiz keşif sorgusu atmaktan ve token harcamaktan kaçınmak için buradaki bağlamı kullan.

---

## 1. KİŞİ

- **Batuhan Çakır** — GAİN'de Data/BI Engineer
- Samimi konuş, kurumsal robot gibi değil
- Kısa komutlarla ilerler, bağlamı hatırlamanı bekler
- Önce dosyayı oku, sonra konuş; olmayan kolon uydurma
- Detay: `Agent Logs/Batuhan_Cakir_Everything.md`

---

## 2. TEKNİK ORTAM

- **BigQuery**: `microgain-9f959` projesi, Standard SQL
- **Looker Studio**: dashboard çıktısı
- **Airflow**: AWS MWAA 2.10.1, DAG'ler S3'te (`gain-data-airflow-bucket`)
- **Proje dizini**: `~/GAIN_API_QUERY`
- Python, macOS M3, VS Code

---

## 3. AKTİF PROJE: GAIN 215 — Finans Dashboard

Tam devir notu: `Agent Logs/GAIN_215_FINANS_DASHBOARD_DEVIR_NOTU.md`

### 3.1 Kritik İş Kuralları

| Kural | Değer |
|---|---|
| Test işlem filtresi | `COALESCE(amount, amount_before_promotions, 0) > 101` (kuruş bazlı) |
| Vergi | SQL'e dahil edilmez; Net = Brüt − ödeme kuruluşu komisyonu |
| Ücretli abone | `created_at <= gün <= valid_until` AND (ACTIVE veya CANCELED) |
| Kayıp tanımı | EXPIRED + IN\_GRACE + ON\_HOLD |
| Dashboard terminolojisi | "Aktif Abone" değil **"Ücretli Abone"** |
| MRR | Snapshot — ödeme günü bazlı nakit akışı değil |
| Tahsilat | Gerçek ödeme event'i bazlı nakit akışı |

### 3.2 Komisyon Oranları

| Sağlayıcı | Oran |
|---|---|
| App Store | %30 |
| Play Store | %15 |
| Payguru / Mobile | %15 |
| Iyzico | %3 |
| Craftgate | %0 (legacy) |

### 3.3 BigQuery Hedef Tablolar

```
microgain-9f959.bc_t.googleplay_transactions_raw
microgain-9f959.bc_t.apple_transactions_raw
microgain-9f959.bc_marketing_marts.ads_daily_spend   ← CAC kaynağı
```

### 3.4 Finans Dashboard SQL Dosyaları

| Sayfa | Dosya |
|---|---|
| 1. Sayfa Unit Economics | `looker_sqls/BC_UNIT_ECONOMICS_DAILY_01.sql` |
| 1. Sayfa Forecast LTV | `looker_sqls/BC_FORECAST_LTV_MONTHLY_01.sql` |
| 1. Sayfa Realized LTV | `looker_sqls/BC_REALIZED_LTV_MONTHLY_01.sql` |
| 1. Sayfa CAC | `looker_sqls/BC_CAC_MONTHLY_01.sql` |
| 1. Sayfa LTV/CAC | `looker_sqls/BC_LTVCAC_REALIZED_MONTHLY_01.sql` |
| 1. Sayfa Heavy/Light LTV | `looker_sqls/BC_WATCHER_LTV_02.sql` |
| 1. Sayfa Ödeme Dağılımı | `looker_sqls/BC_PAYMENT_METHOD_DISTRIBUTION_01.sql` |
| 1. Sayfa Heavy Dağılım | `looker_sqls/BC_HEAVY_PAYMENT_DISTRIBUTION_01.sql` |
| 2. Sayfa Reklam LTV | `looker_sqls/BC_CHANNEL_LTVCAC_REALIZED_01.sql` |
| 3. Sayfa Kampanya | `looker_sqls/BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02.sql` |
| 3. Sayfa 3 Aylık | `looker_sqls/BC_3MONTH_CAMPAING.sql` |
| Reklam Harcaması | `looker_sqls/BC_ADS_DAILY_SPEND_UNIFIED_01.sql` |
| Ads Backfill MERGE | `looker_sqls/BC_ADS_DAILY_SPEND_UNIFIED_BACKFILL.sql` |
| Provider KPI | `looker_sqls/BC_PAYMENT_PROVIDER_KPIS_01.sql` |

---

## 4. TAMAMLANAN İŞLER (26 Haziran 2026 itibarıyla)

- ✅ P0: Ads backfill tamamlandı — Meta 358/358, Google 358/358, 0 duplicate, 0 spend mismatch
- ✅ P1: Geriye Dönük Analiz 6 olgun cohort ayı görünüyor (Eyl 2025 – Şub 2026)
- ✅ P2: 1. ve 2. sayfa Looker çalışıyor — ARPU ₺206,70, Realized LTV ₺1.066, CAC Payback 0,47, LTV/CAC 6,42
- ✅ P3: BC_3MONTH_CAMPAING platform simidi çalışıyor, eksik streaming günleri "Veri yok" gösteriyor
- ✅ P4: Kampanya Ekonomisi sayfası temel görünüm tamam
- ✅ Google/Apple Airflow DAG'leri, Slack callbacks, dotenv kaldırma, credential Variable'lara taşıma
- ✅ Provider KPI SQL'i (BC_PAYMENT_PROVIDER_KPIS_01) — Apple, Google, Iyzico, Payguru dahil

---

## 5. AÇIK İŞLER (Öncelik Sırasıyla)

### 🔴 P3 — Looker "Geçersiz metrik" hatası
Kampanya Bazlı Abone sayfasında iki yerde Looker uyarısı var: "Bu grafikle geçersiz bir metrik var."
Muhtemelen BC_3MONTH_CAMPAING güncellendikten sonra Looker'da eski calculated field hâlâ bağlı.
Aksiyon: Veri kaynağında "Alanları yenile" → grafiklerle bağlı metrikleri tek tek kontrol et.

### 🔴 P5 — Provider KPI Looker Sayfası (TEST - INPROGRESS)
`BC_PAYMENT_PROVIDER_KPIS_01` SQL hazır. Looker'da yalnız "Ücretli Aboneler: 111.918" scorecard bağlanmış, geri kalan 5 KPI scorecard bağlanmadı.
Eklenecek alanlar:
- `previous_month_gross_collections_tl` → "Brüt Tahsilat Tutarı - Geçen Ay" (MRR deme!)
- `previous_month_net_collections_tl` → "Net Tahsilat Tutarı - Geçen Ay"
- `previous_month_transaction_count` → "İşlem Adedi - Geçen Ay"
- `selected_period_net_collections_tl` → "Seçilen Aralıktaki Net Tahsilat"
- `selected_period_transaction_count` → "Seçilen Aralıktaki İşlem Adedi"
- Hepsi için aggregation: `MAX`

### ⚠️ P1 — Meta Attribution Uyarısı
Meta'da yalnız 281 attributed user var, Google'da ~19.700. Meta CAC ~₺6.470 görünüyor — grafik ölçeği bozuluyor.
- 2. sayfaya veri kalite uyarısı notu ekle
- Gerçek Meta attribution kapsamı araştırılmalı

### ⚠️ P1 — TikTok Satırı
2. sayfada TikTok görünmüyor. Verify et: SQL'de TikTok var mı, data var mı?

### ⚠️ P2 — CAC Kart Etiketi
CAC kartı ₺201,58 gösteriyor ama hangi aya karşılık geldiği belli değil.
`is_latest_mature_month = true` filtreli; kart altına "En olgun cohort: [ay]" etiketi ekle.

### ⚠️ P2 — Eylül 2025 LTV/CAC = 35,1 Anomalisi
Geriye Dönük Analiz tablosunda Eyl 2025 CAC yalnız ₺16,03 → LTV/CAC 35,1.
Backfill öncesi o dönemde minimal harcama kaydı var. Tabloya not veya min. spend eşiği ekle.

### 🔵 P5 — Unified Payment Transaction Mart (başlanmadı)
- Günlük provider pivot tablosu
- Başarılı/başarısız/refund normalizasyonu (tüm kaynaklar)
- `> 101` test filtresi, TCMB kuru, dedupe
- Seçili dönem kümülatif alanlar
- Kuruluş bazlı indirilebilir detay sayfası

### 🔵 P6 — 2 Yıllık Ödeme Backfill (başlanmadı)
Google Play, Apple, Iyzico, Payguru — 2 yıllık backfill.

### 🔵 P7 — Airflow Production Son Kontrol (başlanmadı)
T-1 DAG manuel tetik, duplicate testi, Slack testi.

### 🔵 P8 — Repo Temizliği (başlanmadı)
19 modified SQL review, credential dosya güvenliği, SQL rehberleriyle senkronizasyon.

---

## 6. BİLİNEN RİSKLER

| Risk | Detay |
|---|---|
| Meta attribution | ~%18 coverage, 2 kullanıcı için ₺63K harcama — kesin finans gerçeği olarak sunma |
| Streaming eksikliği | Bazı günler upstream'de hiç veri yok; SQL tamir edemez |
| Looker cache | SQL değişince her zaman "Alanları yenile" çalıştır |
| Dirty worktree | Repo'da 19+ modified SQL var, toplu reset/revert yapma |
| Payguru net | `₺1.13M` hesaplanan net ≠ gerçek banka yatışı; settlement kaynağı finanstan alınmalı |

---

## 7. LOOKER AGGREGATİON KURALLARI

- Stok metrikler (abone sayısı vb.): **SUM yapma**, son günü göster
- Akış metrikler (churn, tahsilat): **SUM alınabilir**
- CAC Payback: `MAX(cac_payback_period)` + `is_latest_mature_month = true`
- LTV/CAC: `MAX(ltv_cac_ratio)` + `is_latest_mature_month = true`
- Provider KPI'lar: hepsi `MAX`

---

## 8. SLACK VE AIRFLOW

- Connection ID: `slack_default` (Slack Incoming Webhook)
- Kanal: `#airflow_notify`
- Callback dosyası: `S3'e atılacaklar/airflow-dags/slack_callbacks.py`
- Requirements: `S3'e atılacaklar/requeriments.txt` (yazım hatası — sistem bağımlılığı olduğu için dokunma)
