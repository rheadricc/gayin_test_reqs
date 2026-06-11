

# GAIN201 Agent Log - S3 / Airflow / BigQuery Entegrasyon Çalışması

**Hazırlayan:** Batuhan ÇAKIR | GAIN Data Analyst
**Kapsam:** GAİN payment/API scriptlerinin lokal çalışan yapıdan MWAA Airflow + S3 + BigQuery prod akışına taşınması  
**Ana hedef:** CSV bağımlılığını kaldırıp, verileri doğrudan BigQuery raw tablolarına yazan, Airflow üzerinden günlük/aylık/manual çalışabilen stabil pipeline yapısı kurmak.

---

## 1. Genel Mimari

Bu çalışmada scriptler ikiye ayrıldı:

1. **Lokal geliştirme/test scriptleri**
   - `.env` dosyalarıyla çalışmaya devam edebilir.
   - Geliştirici bilgisayarında manuel test, backfill ve debug için kullanılır.

2. **Airflow'a atılacak prod scriptleri**
   - `.env` bağımlılığı kaldırıldı.
   - Tüm config/secrets değerleri Airflow DAG içinden `os.environ.update(...)` ile script runtime'ına basılıyor.
   - API key/secret bilgileri Airflow Variables üzerinden okunuyor.
   - BigQuery bağlantısı eski sistemle uyumlu olacak şekilde Airflow Connection `google_cloud_default` üzerinden sağlanıyor.

Prod akış şu şekilde standardize edildi:

```text
Airflow DAG
↓
S3'ten ilgili Python scriptini indirir
↓
Scripti /tmp altına koyar
↓
importlib ile module olarak import eder
↓
Airflow Variable değerlerini os.environ'a basar
↓
BigQuery client'ı google_cloud_default connection ile patchler
↓
module.main() çağırır
↓
Script API'den veriyi çeker ve BigQuery raw tabloya yazar
```

---

## 2. S3 Klasör / Path Standardı

S3 bucket:

```text
gain-data-airflow-bucket
```

Kullanılan ana path'ler:

```text
airflow-dags/      → Airflow DAG dosyaları
python_scripts/    → DAG'lerin S3'ten indirip çalıştırdığı script dosyaları
airflow_keys/      → token_store.json gibi ortak token/credential dosyaları
```

Önemli karar:

- `.env` dosyaları S3'e yüklenmeyecek.
- Lokal test `.env` ile devam edebilir ama prod Airflow tarafı `.env` okumayacak.
- Dosyalar klasör olarak rastgele yüklenmeyecek; S3 key/path birebir DAG içinde beklenen path ile aynı olacak.

Yanlış örnek:

```text
S3'e atılacaklar/iyzico_api_etc/iyzico_transaction_export.py
```

Doğru örnek:

```text
python_scripts/iyzico_transaction_export.py
```

---

## 3. S3'e Yüklenecek DAG Dosyaları

Aşağıdaki DAG dosyaları `airflow-dags/` altına yüklenmelidir:

```text
airflow-dags/iyzico_transaction_dag.py
airflow-dags/param_dag.py
airflow-dags/payguru_transactions_dag.py
airflow-dags/paynkolay_transactions_dag.py
airflow-dags/tcmb_airflow_dag.py
airflow-dags/kids_identifier_dag.py
```

---

## 4. S3'e Yüklenecek Script Dosyaları

Aşağıdaki script dosyaları `python_scripts/` altına yüklenmelidir:

```text
python_scripts/iyzico_transaction_export.py
python_scripts/param.py
python_scripts/payguru.py
python_scripts/paynkolay.py
python_scripts/tcmb_kur_hesaplama.py
python_scripts/kids_async_identifier.py
```

Kids için token dosyası:

```text
airflow_keys/token_store.json
```

Bu dosya prod'da Kids scriptinin BO API access token'ı okuması için kullanılır.

---

## 5. BigQuery Tablo Listesi

Bu çalışma kapsamında oluşturulan / kullanılan BigQuery raw tabloları:

```text
microgain-9f959.bc_t.iyzico_transactions_raw
microgain-9f959.bc_t.param_transactions_raw
microgain-9f959.bc_t.payguru_transactions_raw
microgain-9f959.bc_t.nkolay_transactions_raw
microgain-9f959.bc_t.tcmb_exchange_rates_raw
microgain-9f959.bc_t.user_kids_profile_state
microgain-9f959.bc_t.user_kids_profile_state_staging
microgain-9f959.bc_t.active_subscribers_snapshot
```

Tablo açıklamaları:

| Tablo | Açıklama |
|---|---|
| `iyzico_transactions_raw` | Iyzico transaction verileri |
| `param_transactions_raw` | Param / TurkPos transaction verileri |
| `payguru_transactions_raw` | Payguru transaction verileri |
| `nkolay_transactions_raw` | N Kolay / Paynkolay transaction verileri |
| `tcmb_exchange_rates_raw` | TCMB günlük döviz kuru verileri |
| `user_kids_profile_state` | Kullanıcı bazlı güncel Kids profil state tablosu |
| `user_kids_profile_state_staging` | Kids profil state staging tablosu |
| `active_subscribers_snapshot` | Aktif abone / Kids profil snapshot-log tablosu |

---

## 6. BigQuery Load / Duplicate Önleme Standardı

Payment ve TCMB scriptlerinde BigQuery yazma mantığı şu şekilde standardize edildi:

```text
1. İlgili tarih / tarih aralığı belirlenir.
2. BigQuery tablosu yoksa schema ile oluşturulur.
3. Aynı tarih aralığındaki eski satırlar silinir.
4. Yeni veri JSONL load job ile WRITE_APPEND olarak yüklenir.
```

Kritik kararlar:

- `insert_rows_json` kullanılmadı; streaming buffer yüzünden `DELETE` işlemlerinde risk oluşturuyordu.
- `load_table_from_dataframe` kullanılmadı; MWAA ortamında `pyarrow` bağımlılığı gerektirebiliyor.
- Bunun yerine `NEWLINE_DELIMITED_JSON` dosyası üzerinden `client.load_table_from_file(...)` kullanıldı.
- Aynı tarih aralığı tekrar çalıştırıldığında duplicate beklenmez.

Örnek duplicate önleme mantığı:

```sql
DELETE FROM `project.dataset.table`
WHERE source_date BETWEEN @start_date AND @end_date
```

TCMB özelinde:

```sql
DELETE FROM `microgain-9f959.bc_t.tcmb_exchange_rates_raw`
WHERE rate_date = @rate_date
```

---

## 7. Airflow Variables

Airflow UI yolu:

```text
Admin → Variables
```

Import işlemi için JSON formatında `variables.json` hazırlanıp Airflow UI üzerinden import edildi.

Import edilen variable seti:

```text
GOOGLE_APPLICATION_CREDENTIALS_PATH
IYZICO_API_KEY
IYZICO_SECRET_KEY
IYZICO_BASE_URL
TURKPOS_SOAP_URL
TURKPOS_CLIENT_CODE
TURKPOS_CLIENT_USERNAME
TURKPOS_CLIENT_PASSWORD
TURKPOS_GUID
PAYGURU_PRODUCT
PAYGURU_BASE_URL
PAYGURU_MERCHANT_ID
PAYGURU_SERVICE_IDS
NKOLAY_BASE_URL
NKOLAY_LIST_SX
NKOLAY_MERCHANT_SECRET_KEY
TCMB_BASE_URL
TCMB_URL
```

Not:

- `GOOGLE_APPLICATION_CREDENTIALS_PATH` ilk aşamada eklendi ancak sonrasında DAG'ler eski sistemle uyumlu hale getirildiği için BigQuery tarafında ana bağlantı `google_cloud_default` Airflow Connection üzerinden yapıldı.
- Secret değerler scriptlere yazılmadı.
- `.env` prod S3'e yüklenmedi.

---

## 8. Airflow Connections / BigQuery Credential Kararı

Mevcut Airflow ortamında şu connection'ın hazır olduğu görüldü:

```text
google_cloud_default
```

Eski GAİN DAG'lerinde BigQuery bağlantısı şu mantıkla kuruluyordu:

```python
hook = BigQueryHook(gcp_conn_id="google_cloud_default")
credentials = hook.get_credentials()
project_id = hook.project_id
bq_client = bigquery.Client(credentials=credentials, project=project_id)
```

Yeni DAG'ler de buna uyumlu hale getirildi.

Bunun için tüm yeni DAG dosyalarına şu importlar eklendi:

```python
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from google.cloud import bigquery
```

Ve şu helper eklendi:

```python
def patch_bigquery_client(module, gcp_conn_id: str = "google_cloud_default"):
    """Make downloaded scripts use Airflow's existing GCP connection instead of a local key file."""
    if not hasattr(module, "bigquery"):
        return

    hook = BigQueryHook(gcp_conn_id=gcp_conn_id)
    credentials = hook.get_credentials()
    connection_project_id = hook.project_id or "microgain-9f959"
    original_client = bigquery.Client

    def airflow_bigquery_client(*args, **kwargs):
        project = kwargs.get("project") or connection_project_id
        return original_client(credentials=credentials, project=project)

    module.bigquery.Client = airflow_bigquery_client
```

Script import edildikten sonra her DAG içinde şu çağrı yapıldı:

```python
patch_bigquery_client(module)
```

Böylece script içinde `bigquery.Client(project=...)` çağrısı kalsa bile Airflow runtime'da `google_cloud_default` connection credential'ı ile çalışır.

---

## 9. DAG Çalışma Modları

Iyzico, Param, Payguru ve N Kolay için üç DAG pattern'i kullanıldı:

```text
*_daily    → daily mode
*_monthly  → monthly mode
*_manual   → manual mode
```

Daily DAG'lerde UI üzerinden manuel trigger alınsa bile script `daily` mode ile çalışır. Çünkü task içinde:

```python
op_kwargs={"mode": "daily"}
```

kullanıldı.

Manual mode çalıştırmak için ilgili `*_manual` DAG trigger edilmelidir.

---

## 10. DAG ID Listesi

Airflow UI'da görülen yeni DAG'ler:

```text
iyzico_transactions_daily
iyzico_transactions_monthly
iyzico_transactions_manual
param_transactions_daily
param_transactions_monthly
param_transactions_manual
payguru_transactions_daily
payguru_transactions_monthly
payguru_transactions_manual
nkolay_transactions_daily
nkolay_transactions_monthly
nkolay_transactions_manual
tcmb_exchange_rates_daily
gain_kids_profile_full_scan
```

---

## 11. Schedule Bilgileri

Genel schedule standardı:

```text
Daily payment DAG'leri   → 0 7 * * *
Monthly payment DAG'leri → 0 6 2 * *
Manual payment DAG'leri  → schedule=None
TCMB daily               → 0 11 * * *
Kids full scan           → 0 2 * * *
```

Not:

- Airflow UI timezone +03 olarak görünmektedir.
- Daily DAG'ler ağırlıklı olarak T-1 verisini çekecek şekilde script içinde tasarlanmıştır.

---

## 12. Script Bazlı Notlar

### 12.1 Iyzico

Dosyalar:

```text
airflow-dags/iyzico_transaction_dag.py
python_scripts/iyzico_transaction_export.py
```

Hedef tablo:

```text
microgain-9f959.bc_t.iyzico_transactions_raw
```

Önemli alan:

```text
report_date
```

Backfill test komutu:

```bash
python iyzico_transaction_export.py custom --start-date 2026-03-01 --end-date 2026-06-08
```

Airflow test sırasında ilk hata:

```text
ModuleNotFoundError: No module named 'dotenv'
```

Çözüm:

- Airflow'a gidecek scriptlerde `dotenv` import ve `load_dotenv(...)` çağrıları kaldırıldı.
- Local scriptler ayrı tutuldu, lokal kullanımda `.env` devam edebilir.

---

### 12.2 Param / TurkPos

Dosyalar:

```text
airflow-dags/param_dag.py
python_scripts/param.py
```

Hedef tablo:

```text
microgain-9f959.bc_t.param_transactions_raw
```

Önemli alan:

```text
source_date
```

Backfill test komutu:

```bash
python param.py custom --start-date 2026-03-01 --end-date 2026-06-08
```

Not:

- Mayıs 2026 sonrası veri gelmemesi normal kabul edildi; bu kanaldan ödeme alınması bırakıldı.

---

### 12.3 Payguru

Dosyalar:

```text
airflow-dags/payguru_transactions_dag.py
python_scripts/payguru.py
```

Hedef tablo:

```text
microgain-9f959.bc_t.payguru_transactions_raw
```

Önemli alanlar:

```text
source_date
service_id
```

Backfill test komutu:

```bash
python payguru.py custom --start-date 2026-03-01 --end-date 2026-06-08
```

Not:

- Query sonuçlarında `service_id=3509` ve `service_id=3513` bazında çift satır görülmesi duplicate değil, iki farklı servis kırılımı olarak değerlendirildi.

---

### 12.4 N Kolay / Paynkolay

Dosyalar:

```text
airflow-dags/paynkolay_transactions_dag.py
python_scripts/paynkolay.py
```

Hedef tablo:

```text
microgain-9f959.bc_t.nkolay_transactions_raw
```

Önemli alan:

```text
source_date
```

Backfill test komutu:

```bash
python paynkolay.py custom --start-date 2026-03-01 --end-date 2026-06-08
```

Not:

- N Kolay aktif kullanılmadığı için geriye dönük veri çıkmaması normal değerlendirildi.

---

### 12.5 TCMB Kur

Dosyalar:

```text
airflow-dags/tcmb_airflow_dag.py
python_scripts/tcmb_kur_hesaplama.py
```

Hedef tablo:

```text
microgain-9f959.bc_t.tcmb_exchange_rates_raw
```

Önemli alanlar:

```text
rate_date
requested_date
currency_code
```

Backfill test komutu:

```bash
python tcmb_kur_hesaplama.py custom --start-date 2026-03-01 --end-date 2026-06-08
```

Tek gün test:

```bash
python tcmb_kur_hesaplama.py custom --date 2026-06-05
```

Notlar:

- TCMB eski tarih XML pattern'i desteklendi:

```text
https://www.tcmb.gov.tr/kurlar/YYYYMM/DDMMYYYY.xml
```

- Hafta sonu / resmi tatil gibi XML olmayan günlerde script 404 alırsa günü skip eder.
- Güvenilecek tarih alanı `rate_date` olarak kabul edildi.
- Tek tablo + partition yapısı seçildi:

```text
BQ_TABLE_MODE=partitioned
BQ_TABLE=tcmb_exchange_rates_raw
```

---

### 12.6 Kids Profile State

Dosyalar:

```text
airflow-dags/kids_identifier_dag.py
python_scripts/kids_async_identifier.py
```

Hedef tablolar:

```text
microgain-9f959.bc_t.user_kids_profile_state
microgain-9f959.bc_t.user_kids_profile_state_staging
microgain-9f959.bc_t.active_subscribers_snapshot
```

Prod token path:

```text
s3://gain-data-airflow-bucket/airflow_keys/token_store.json
```

Önemli kararlar:

- Kids için tarihsel backfill yapılmadı; script güncel aktif kullanıcı state'ini tarar.
- `active_subscribers_snapshot` tablosunda aynı gün içinde birden fazla snapshot olması bilinçli olarak kabul edildi. Bu tablo log/snapshot mantığında tutulur.
- `user_kids_profile_state` için staging + MERGE mantığında `user_id` bazlı dedupe eklendi.

Airflow test sırasında hata:

```text
ModuleNotFoundError: No module named 'tqdm'
```

Çözüm:

- Airflow'a gidecek Kids scriptinden `tqdm` import'u kaldırıldı.
- Progress bar yerine log mesajı kullanılacak hale getirildi.

---

## 13. Dependency / Requirements Notları

Mevcut S3'te dosya adı legacy olarak yanlış yazılmış olabilir:

```text
Requeriments.txt
```

Bu isimlendirme eski sistemde kullanılıyorsa bozulmaması için korunabilir. Önemli olan MWAA Environment config içinde Requirements file path hangi dosyayı gösteriyorsa onun güncel olmasıdır.

İlk önerilen minimal paketler:

```text
aiohttp
boto3
google-cloud-bigquery
pandas
requests
python-dotenv
tqdm
```

Ancak prod scriptlerinde sonradan şu karar alındı:

- `python-dotenv` dependency'sine ihtiyaç bırakılmadı.
- `tqdm` dependency'sine ihtiyaç bırakılmadı.
- Prod scriptleri `.env` veya terminal progress bar bağımlılığı olmadan çalışacak hale getirildi.

Bu nedenle Airflow runtime açısından kritik kalan paketler:

```text
aiohttp
boto3
google-cloud-bigquery
pandas
requests
google-api-core
```

Not:

- `boto3` ve Airflow provider paketleri MWAA ortamında zaten bulunabilir.
- Eksik paketler task loglarında `ModuleNotFoundError` ile anlaşılır.

---

## 14. Debug Sürecinde Öğrenilenler

### 14.1 XCom Hata Değildir

Airflow UI'da görülen:

```text
No XCom
```

bir hata değildir. Sadece ilgili task'ın XCom üretmediğini gösterir. Bizim DAG'ler tek task'lı çalıştığı ve task'lar arası veri aktarımı yapmadığı için XCom kullanılmamaktadır.

Gerçek hata için bakılması gereken yer:

```text
DAG → Task Instance → Logs
```

veya MWAA CloudWatch:

```text
CloudWatch Log Groups → airflow-gain-airflow-Task
```

## 15. Manual Test Sırası

Önerilen manual test sırası:

```text
1. tcmb_exchange_rates_daily
2. param_transactions_daily
3. iyzico_transactions_daily
4. payguru_transactions_daily
5. nkolay_transactions_daily
6. gain_kids_profile_full_scan
```

Neden:

- TCMB secret gerektirmez, BigQuery connection ve S3 script download test etmek için uygundur.
- Kids en ağır iştir, en sona bırakılmalıdır.

Manual trigger notu:

- `*_daily` DAG manuel trigger edilirse yine `daily` mode çalışır.
- `*_manual` DAG trigger edilirse script `manual` mode çalışır.

---

## 16. Backfill Komutları

Üç aylık test/backfill için kullanılan tarih aralığı:

```text
2026-03-01 → 2026-06-08
```

Iyzico:

```bash
cd /Users/batuhancakir/GAIN_API_QUERY/iyzico_api_etc
python iyzico_transaction_export.py custom --start-date 2026-03-01 --end-date 2026-06-08
```

Param:

```bash
cd /Users/batuhancakir/GAIN_API_QUERY/param_api_etc
python param.py custom --start-date 2026-03-01 --end-date 2026-06-08
```

Payguru:

```bash
cd /Users/batuhancakir/GAIN_API_QUERY/payguru_api_etc
python payguru.py custom --start-date 2026-03-01 --end-date 2026-06-08
```

N Kolay:

```bash
cd /Users/batuhancakir/GAIN_API_QUERY/paynkolay_api_etc
python paynkolay.py custom --start-date 2026-03-01 --end-date 2026-06-08
```

TCMB:

```bash
cd /Users/batuhancakir/GAIN_API_QUERY/tcmb_kur
python tcmb_kur_hesaplama.py custom --start-date 2026-03-01 --end-date 2026-06-08
```

Kids güncel state:

```bash
cd /Users/batuhancakir/GAIN_API_QUERY/bo_profile_count/kids_counter
python kids_async_identifier.py
```

---

## 17. BigQuery Kontrol Sorguları

Iyzico:

```sql
SELECT
  report_date,
  COUNT(*) AS row_count,
  COUNT(DISTINCT transaction_id) AS unique_transaction_count,
  MIN(etl_loaded_at) AS first_loaded_at,
  MAX(etl_loaded_at) AS last_loaded_at
FROM `microgain-9f959.bc_t.iyzico_transactions_raw`
GROUP BY report_date
ORDER BY report_date DESC;
```

Param:

```sql
SELECT
  source_date,
  COUNT(*) AS row_count,
  COUNT(DISTINCT transaction_id) AS unique_transaction_count,
  MIN(etl_loaded_at) AS first_loaded_at,
  MAX(etl_loaded_at) AS last_loaded_at
FROM `microgain-9f959.bc_t.param_transactions_raw`
GROUP BY source_date
ORDER BY source_date DESC;
```

Payguru:

```sql
SELECT
  source_date,
  service_id,
  COUNT(*) AS row_count,
  COUNT(DISTINCT transaction_id) AS unique_transaction_count,
  MIN(etl_loaded_at) AS first_loaded_at,
  MAX(etl_loaded_at) AS last_loaded_at
FROM `microgain-9f959.bc_t.payguru_transactions_raw`
GROUP BY source_date, service_id
ORDER BY source_date DESC, service_id;
```

N Kolay:

```sql
SELECT
  source_date,
  COUNT(*) AS row_count,
  COUNT(DISTINCT transaction_id) AS unique_transaction_count,
  MIN(etl_loaded_at) AS first_loaded_at,
  MAX(etl_loaded_at) AS last_loaded_at
FROM `microgain-9f959.bc_t.nkolay_transactions_raw`
GROUP BY source_date
ORDER BY source_date DESC;
```

TCMB:

```sql
SELECT
  rate_date,
  COUNT(*) AS row_count,
  COUNT(DISTINCT currency_code) AS currency_count,
  MIN(etl_loaded_at) AS first_loaded_at,
  MAX(etl_loaded_at) AS last_loaded_at
FROM `microgain-9f959.bc_t.tcmb_exchange_rates_raw`
GROUP BY rate_date
ORDER BY rate_date DESC;
```

Kids state:

```sql
SELECT
  COUNT(*) AS row_count,
  COUNT(DISTINCT user_id) AS unique_user_count,
  COUNTIF(has_kid_profile) AS kids_user_count,
  MAX(checked_at) AS last_checked_at
FROM `microgain-9f959.bc_t.user_kids_profile_state`;
```

Kids snapshot:

```sql
SELECT
  DATE(snapshot_ts) AS snapshot_date,
  COUNT(*) AS snapshot_count,
  ARRAY_AGG(
    STRUCT(snapshot_ts, active_total, kids_total, source)
    ORDER BY snapshot_ts DESC
    LIMIT 5
  ) AS latest_snapshots
FROM `microgain-9f959.bc_t.active_subscribers_snapshot`
GROUP BY snapshot_date
ORDER BY snapshot_date DESC;
```

---

## 18. Son Durum / Yapılması Gerekenler

Tamamlananlar:

- Lokal backfill testleri yapıldı.
- BigQuery tabloları doldu.
- DAG dosyaları Airflow UI'da görünür hale geldi.
- Airflow Variables import edildi.
- DAG'ler `google_cloud_default` connection sistemine uyumlu hale getirildi.
- Airflow'a atılacak scriptlerden `.env` / `dotenv` bağımlılığı kaldırılmaya başlandı.
- Kids scriptinden `tqdm` bağımlılığı kaldırıldı.

Devam eden / dikkat edilecek işler:

1. Airflow'a atılacak tüm `python_scripts/*.py` dosyalarında `dotenv` import/call kalmadığı doğrulanmalı.
2. Güncellenen scriptler doğru S3 path'lerine tekrar yüklenmeli.
3. DAG'ler sırayla manual trigger ile test edilmeli.
4. Hatalar XCom'dan değil CloudWatch task loglarından okunmalı.
5. İlk stabil run'lardan sonra günlük schedule'ların açık/kapalı durumları netleştirilmeli.

---

## 19. Önemli Uyarılar

- `.env` dosyaları prod S3'e yüklenmemeli.
- Secret değerler GitHub/S3 içinde düz dosya olarak tutulmamalı.
- `variables.json` sadece Airflow import için lokal kullanılmalı, sonrasında güvenli yerde saklanmalı veya silinmeli.
- S3'e klasör komple atılırken path bozulmamalı; DAG'lerin beklediği path birebir korunmalı.

---

## 20. Kısa Özet

Bu çalışma ile GAİN tarafındaki Iyzico, Param, Payguru, N Kolay, TCMB ve Kids profile scriptleri lokal/manuel yapıdan Airflow orchestrated prod yapıya taşındı. Scriptlerin BigQuery'ye doğrudan, duplicate önlemeli ve tarih bazlı replace mantığıyla yazması sağlandı. Secrets yönetimi Airflow Variables'a, BigQuery credential kullanımı ise mevcut `google_cloud_default` Airflow Connection'a bağlandı. `.env`, `dotenv` ve `tqdm` gibi lokal/debug odaklı bağımlılıklar prod scriptlerinden temizlenmeye başlandı. S3 path standardı netleştirildi ve Airflow DAG'leri UI'da görünür hale getirildi.