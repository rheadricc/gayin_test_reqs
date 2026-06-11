# agent_log_v1.md

## 1. Amaç

Bu doküman, mevcut konuşmada Airflow / S3 / BigQuery entegrasyonu için öğrendiğimiz tüm bilgileri, mevcut S3 yapısından çıkarılan bulguları, riskleri ve sonraki adımları başka bir AI agent'a veya ekipteki başka bir kişiye aktarılabilecek şekilde özetlemek için hazırlanmıştır.

Çalışmanın ana hedefi şudur:

- Python tabanlı veri toplama / ETL scriptlerinin AWS MWAA üzerinde stabil scheduled DAG yapısına alınması.
- DAG dosyalarının, Python scriptlerinin ve SQL dosyalarının S3 üzerinden yönetilmesi.
- Airflow üzerinden çalışan süreçlerin BigQuery dataset/table yapılarını sağlıklı ve sürdürülebilir şekilde doldurması.
- Gerekli olduğunda BigQuery çıktıları üzerinden Looker Dashboard tarafında yeni bölümler hazırlanması.

Looker tarafı bu işin ilk fazı değildir. Öncelik Airflow job'larının stabil çalışması ve BigQuery tablolarının doğru dolmasıdır.

---

## 2. Kullanıcının istediği yeni Jira/task iş tanımı

Kullanıcı daha önce şirket içi Jira task formatlarına benzer şekilde bir iş talebi hazırlatmak istedi. Eski task örnekleri şu yapıdaydı:

- `Yapılması istenilen iş :` başlığı ile başlıyor.
- Önce iş gerekçesi ve amaç açıklanıyor.
- Ardından `Kapsam`, `Beklentiler`, bazen `Dashboard Beklentileri` gibi bölümler geliyor.
- Dil teknik ama Jira/product task seviyesinde; çok developer jargonu değil.
- Sonunda `cc : @İlker Yavuz` bulunuyor.

Bu konuşmada hazırlanan yeni task'ın özü:

> Python tabanlı veri toplama scriptlerinin Airflow üzerinde scheduled ve stabil biçimde çalışacak hale getirilmesi, gerekiyorsa S3 veya benzeri ara katmanlarla yönetilmesi, sonrasında BigQuery tarafında normalize edilmiş dataset/table yapılarının oluşturulması. İstek halinde bu datasetler Looker Dashboard tarafında yeni metrik/bölüm oluşturmak için kullanılacak.

Önerilen task ismi:

> **Python Veri Pipeline Süreçlerinin Airflow ve BigQuery Altyapısına Entegre Edilmesi**

Alternatif daha uzun ve mevcut Jira naming stiline yakın isim:

> **Python Tabanlı Veri Süreçlerinin Airflow Üzerinde Otomatik Olarak Çalıştırılması ve BigQuery’ye Aktarılması**

---

## 3. Mevcut Airflow ortamı hakkında bilinenler

Kullanıcının verdiği bilgiler ve ekran görüntülerinden çıkarılanlar:

- Airflow tipi: **AWS MWAA**
- Airflow versiyonu: **2.10.1**
- DAG'ler MWAA üzerinde çalışıyor.
- Airflow UI içinde `Airflow Plugins` sayfasında `aws_mwaa` plugin'i görünüyor.
- Airflow timezone UI tarafında `+03:00` olarak görünüyor.
- XCom ekranında daha önce çalışan DAG'lere ait kayıtlar var.
- Bazı DAG'ler başarılı şekilde scheduled çalışıyor.
- Örnek başarılı DAG:
  - `Prod_Gain_Elastic_User_All_Data_To_Bq_Dag`
  - schedule: `30 3 * * *`
  - Airflow UI'da 25 successful run görünüyor.
  - max active runs: 1
  - task: `fetch_and_insert_dim_user_raw`
- Bir diğer örnek başarılı DAG:
  - `Prod_Gain_GA4_Events_Count_Check_To_Bq_Dag`
  - schedule: `15 * * * *`
  - description: `Checking the event count anomalies as hourly for GA4.`

Bilinmeyen veya ayrıca AWS Console'dan doğrulanması gereken bilgiler:

- MWAA Python version
- MWAA environment class
- worker min/max
- scheduler count
- execution role
- MWAA'nın S3 DAG folder path'i
- requirements file path
- plugins.zip path

Bunlar AWS Console içinde şu yoldan kontrol edilebilir:

```text
AWS Console > MWAA > Environments > ilgili environment > Details
```

Özellikle bakılacak alanlar:

```text
DAGs folder
Requirements file
Plugins file
Execution role
Environment class
Min workers
Max workers
Schedulers
Airflow version
```

---

## 4. Airflow fileloc konusu

Airflow UI'da DAG detaylarında şu tarz path görünüyor:

```text
/usr/local/airflow/dags/Prod_Gain_Elastic_User_All_Data_To_Bq_Dag.py
```

Bu path MWAA worker/container içindeki lokal path'tir. Kullanıcının buraya direkt erişmesi beklenmez. MWAA, S3'teki DAG dosyalarını kendi worker filesystem'ine sync eder ve Airflow UI'da bu lokal path'i gösterir.

Bu nedenle dosyaların asıl kaynak yeri S3 tarafındaki DAG folder'dır. Kullanıcının dosya toplaması için doğru kaynak:

```text
s3://gain-data-airflow-bucket/airflow-dags/
s3://gain-data-airflow-bucket/python_scripts/
s3://gain-data-airflow-bucket/sql_scripts/
```

veya MWAA environment'ın Details ekranında görünen DAG folder path'idir.

---

## 5. Kullanıcının ilettiği S3 zip yapısı

Kullanıcı S3 içindeki dosyaları indirip `s3_all_files.zip` olarak iletti. Zip içeriği incelendi ve aşağıdaki ana yapı görüldü:

```text
s3_all_files/
├── airflow-dags/
├── python_scripts/
├── sql_scripts/
├── airflow_keys/
├── buildspec.yml
├── README.md
├── requeriments.txt
└── .DS_Store / __MACOSX kalıntıları
```

Not: `requirements.txt` dosyası `requeriments.txt` şeklinde yazılmış görünüyor. Bu bilinçli bir S3 key olabilir veya typo olabilir. MWAA environment'ın requirements path'i bu dosyaya bakıyorsa çalışır; bakmıyorsa dependency'ler MWAA'ya yüklenmeyebilir.

---

## 6. Mevcut repository/deploy mantığı

`buildspec.yml` incelendi. Mevcut yapıda CodeBuild benzeri bir CI/CD akışı kullanılıyor gibi görünüyor.

Özet akış:

1. AWS Secrets Manager'dan GitHub SSH key çekiliyor.
2. Repo remote'u GitHub SSH formatına set ediliyor:

```text
gain-medya/bigdata-airflow-workflows.git
```

3. `master` branch üzerinden son değişiklikler fetch ediliyor.
4. `git diff --name-only HEAD~1` ile son committe değişen dosyalar bulunuyor.
5. Değişen dosyalar şu bucket'a aynı path ile kopyalanıyor:

```text
s3://gain-data-airflow-bucket/$line
```

Bu nedenle production'da doğru deployment yöntemi muhtemelen:

```text
GitHub repo -> CodeBuild/buildspec -> S3 -> MWAA sync
```

Manuel S3 upload teknik olarak çalışabilir, fakat prod çalışan MWAA ortamında risklidir. Çünkü:

- CI/CD dışında yapılan dosya değişiklikleri repo ile S3 arasında drift yaratır.
- Geri alma/rollback zorlaşır.
- Aynı isimde DAG dosyası yüklenirse Airflow parse eder ve prod schedule'a girebilir.
- Dependency gerektiren bir script yüklenirse DAG parse olur ama runtime'da patlayabilir.
- Test dosyası veya yanlış schedule prod'da çalışabilir.

Önerilen güvenli yöntem:

```text
1. Önce lokal/test dataset ile script doğrulaması
2. Sonra GitHub branch/PR veya kontrollü S3 staging path
3. MWAA'ya paused DAG olarak deploy
4. Manual run test
5. Log/BQ output kontrolü
6. Schedule aktif etme
```

---

## 7. Mevcut `README.md` notu

README içeriği kısa ama önemli bir uyarı içeriyor:

> DAG dosyasını silmek için Airflow bucket S3 içerisinden manuel silmek gerekebilir; aksi halde CI/CD değişiklikleri DAG silmeyi otomatik yapmayabilir.

Bu şu anlama gelir:

- Buildspec sadece değişen/var olan dosyaları S3'e kopyalıyor.
- Repo'dan silinen dosyaların S3'ten otomatik silinmesi garanti değil.
- Bu yüzden eski DAG dosyaları S3'te kalabilir ve Airflow'da görünmeye devam edebilir.

Bu production temizlik açısından önemli bir risk.

---

## 8. Mevcut requirements dosyası

Zip içindeki dosya adı:

```text
requeriments.txt
```

İçeriği:

```text
apache-airflow-providers-slack
pandas
apache-airflow-providers-google
google-cloud-storage
apache-airflow-providers-amazon
elasticsearch<9.0.0
```

İlk değerlendirme:

- `pandas`, `google-cloud-storage`, `apache-airflow-providers-google`, `apache-airflow-providers-amazon`, `elasticsearch<9.0.0` mevcut.
- Mevcut bazı scriptlerde `pandas_gbq`, `google.cloud.bigquery`, `requests`, `boto3`, muhtemelen `psycopg2` ve `jinja2` kullanılıyor.
- `boto3` MWAA içinde çoğunlukla hazır olabilir ama açıkça pinlemek gerekebilir.
- `pandas-gbq` requirements içinde görünmüyor; bazı scriptlerde import edildiği için riskli.
- `requests` requirements içinde görünmüyor ama MWAA/Airflow ortamında hazır olabilir; yine de açıkça yazmak daha güvenli.
- Redshift tarafı için `psycopg2-binary` veya ilgili provider gerekebilir; bazı DAG/scriptler Redshift connection kullanıyor.

İleride tüm yeni scriptler de incelendikten sonra requirements final hale getirilmelidir.

Ön taslak:

```text
apache-airflow-providers-google
apache-airflow-providers-amazon
apache-airflow-providers-slack
pandas
pandas-gbq
google-cloud-bigquery
google-cloud-storage
elasticsearch<9.0.0
requests
boto3
psycopg2-binary
jinja2
```

Not: MWAA'da gereksiz paket yüklemek environment update süresini artırabilir veya dependency conflict yaratabilir. Final liste script importlarına göre daraltılmalıdır.

---

## 9. S3 içindeki DAG envanteri

Zip içinde `airflow-dags/` altında 23 Python dosyası görüldü.

| DAG file | DAG id | Schedule | S3 script dependency |
|---|---|---:|---|
| `Prod_Daily_Metrics_Redshift_To_Bq_Current_Date.py` | `Prod-Daily-Metrics-Redshift-To-Bq-Current-Date-Dag` | `0 19 * * *` | - |
| `Prod_Gain_BO_Content_Title_Data_To_Bq_Dag.py` | `Prod_Gain_BO_Content_Title_Data_To_Bq_Dag` | `30 0 * * *` | `python_scripts/Prod_Gain_BO_Content_Title_Data_To_Bq_Script.py` |
| `Prod_Gain_BO_Promotion_Data_To_Bq_Dag.py` | `Prod_Gain_BO_Promotion_Data_To_Bq_Dag` | `50 0 * * *` | `python_scripts/Prod_Gain_BO_Promotion_Data_To_Bq_Script.py` |
| `Prod_Gain_Daily_Elastic_User_Data_To_Insider_Dag.py` | `Prod_Gain_Daily_Elastic_User_Data_To_Insider_Dag` | `45 3 * * *` | `python_scripts/Prod_Gain_Daily_Elastic_User_Data_To_Insider_Script.py` |
| `Prod_Gain_Elastic_User_All_Data_To_Bq_Dag.py` | `Prod_Gain_Elastic_User_All_Data_To_Bq_Dag` | `30 3 * * *` | `python_scripts/Prod_Gain_Elastic_User_All_Data_To_Bq_Script.py` |
| `Prod_Gain_Ga4_Events_Count_Check_To_Bq_Dag.py` | `Prod_Gain_GA4_Events_Count_Check_To_Bq_Dag` | `15 * * * *` | `python_scripts/Prod_Gain_GA4_Events_Count_Check_To_Bq.py` |
| `Prod_Gain_Internal_Data_Quality_To_Bq_Dag.py` | `Prod_Gain_Internal_Data_Quality_To_Bq_Dag` | `55 3 * * *` | `python_scripts/Prod_Gain_Internal_Data_Quality_To_Bq_Script.py` |
| `Prod_Gain_Never_Watched_Users_To_Bq_Scd_Dag.py` | `Prod_Gain_Never_Watched_Users_To_Bq_Scd_Dag` | `45 20 * * 0` | `python_scripts/Prod_Gain_Never_Watched_Users_To_Bq_Scd.py` |
| `Prod_Gain_Never_Watched_Users_To_Insider_Dag.py` | `Prod_Gain_Never_Watched_Users_Data_To_Insider_Panel_Dag` | `55 20 * * 0` | `python_scripts/Prod_Gain_Never_Watched_Users_To_Insider_Script.py` |
| `Prod_Gain_S3_Data_Count_Validator_To_Bq_Dag.py` | `Prod_Gain_S3_Data_Count_Validator_To_Bq_Dag` | `5 1 * * *` | `python_scripts/Prod_Gain_S3_Data_Count_Validator_To_Bq_Script.py` |
| `Prod_Gain_S3_IYS_To_Redshift_Dag.py` | `Prod_Gain_S3_IYS_To_Redshift_Dag` | `2 * * * *` | - |
| `Prod_Gain_S3_Migration_Adjust_To_Bq_Dag.py` | `Prod_Gain_S3_Migration_Adjust_To_Bq_Dag` | `35 3 * * *` | - |
| `Prod_Gain_S3_Migration_IYS_To_Bq_Dag.py` | `Prod_Gain_S3_Migration_IYS_To_Bq_Dag` | `2 * * * *` | - |
| `Prod_Gain_S3_Migration_Subs_Payment_Data_To_Bq__Dag.py` | `Prod_Gain_Subs_Payment_Data_To_Bq__Dag` | `10 * * * *` | `python_scripts/Prod_Gain_Subs_Payment_Data_To_Bq_Script.py` |
| `Prod_Gain_S3_Migration_User_Action_To_Bq_Dag.py` | `Prod_Gain_S3_Migration_User_Action_To_Bq_Dag` | `4 * * * *` | `python_scripts/Prod_Gain_S3_Migration_User_Action_To_Bq_Script.py` |
| `Prod_Gain_S3_User_Actions_To_Redshift_Dag.py` | `Prod_Gain_S3_User_Actions_To_Redshift_Dag` | `4 * * * *` | `python_scripts/Prod_Gain_S3_User_Actions_To_Redshift_Script.py` |
| `Test_Gain_S3_Migration_Subs_Payment_Data_To_Bq_Dag.py` | `Test_Gain_Subs_Payment_Data_To_Bq__Dag` | `12 * * * *` | `python_scripts/Test_Gain_Subs_Payment_Data_To_Bq_Script.py` |
| `hourly_prod_user_status.py` | `hourly-prod-user-status-data` | `*/30 * * * *` | - |
| `s3_to_redshift_data_count_check.py` | `prod_subs_payment_data_validation` | `5 1 * * *` | - |
| `s3_to_redshift_subs_table.py` | `test-subs-pay-dag` | `@hourly` | - |
| `subs_payment_to_redshift_prod.py` | `prod-subs-pay-dag` | `@hourly` | - |
| `test_dag.py` | `Daily_Insider_User_Data_Upsert_Test_Dag` | `@daily` | - / farklı internal yapı |
| `test_dag_2.py` | parse edilebilir DAG id bulunamadı | - | - |

Notlar:

- Bazı DAG'ler S3'ten script indirip dynamic import ediyor.
- Bazı DAG'ler logic'i direkt DAG dosyası içinde barındırıyor.
- Test DAG'leri prod S3 içinde duruyor; bu ayrı bir temizlik konusu.
- `Prod_Gain_S3_Migration_Subs_Payment_Data_To_Bq__Dag.py` dosya adında çift underscore var.
- `Prod_Gain_Ga4_Events_Count_Check_To_Bq_Dag.py` dosya adı ile DAG id içinde GA4/Ga4 casing farkı var.

---

## 10. S3 içindeki Python script envanteri

Zip içinde `python_scripts/` altında 16 script görüldü:

```text
Prod_Gain_BO_Content_Title_Data_To_Bq_Script.py
Prod_Gain_BO_Promotion_Data_To_Bq_Script.py
Prod_Gain_Daily_Elastic_User_Data_To_Insider_Script.py
Prod_Gain_Elastic_User_All_Data_To_Bq_Script.py
Prod_Gain_GA4_Events_Count_Check_To_Bq.py
Prod_Gain_Internal_Data_Quality_To_Bq_Script.py
Prod_Gain_Never_Watched_Users_To_Bq_Scd.py
Prod_Gain_Never_Watched_Users_To_Insider_Script.py
Prod_Gain_S3_Data_Count_Validator_To_Bq_Script.py
Prod_Gain_S3_IYS_To_Redshift_Script.py
Prod_Gain_S3_Migration_Adjust_To_Bq_Script.py
Prod_Gain_S3_Migration_IYS_To_Bq_Script.py
Prod_Gain_S3_Migration_User_Action_To_Bq_Script.py
Prod_Gain_S3_User_Actions_To_Redshift_Script.py
Prod_Gain_Subs_Payment_Data_To_Bq_Script.py
Test_Gain_Subs_Payment_Data_To_Bq_Script.py
```

Bu scriptlerin genel işleri:

- BO content title verisini BigQuery'ye almak
- BO promotion verisini BigQuery'ye almak
- Elastic user verisini Insider'a göndermek
- Elastic user all data verisini BigQuery'ye almak
- GA4 hourly event count check yapmak
- Internal data quality sonuçlarını BigQuery'ye yazmak
- Never watched user segmentlerini BigQuery ve Insider tarafında yönetmek
- S3 migration kaynaklarını BigQuery'ye almak
- S3/IYS/User Actions kaynaklarını Redshift'e almak
- Subs payment datasını BigQuery'ye almak

---

## 11. SQL script envanteri

Zip içinde `sql_scripts/` altında görülen başlıca SQL dosyaları:

```text
Prod_Gain_Elastic_User_All_Data_To_Bq_Sql.sql
Prod_Gain_Elastic_User_Data_To_Bq_Sql.sql
bulk_insert.sql
daily_metrics.sql
daily_metrics_merge.sql
daily_metrics_test.sql
daily_report_metrics_total_paid_user_new.sql
hourly_user_status_aws.sql
total_paid_user_aws.sql
total_paid_user_bq.sql
```

Alt klasörler:

```text
sql_scripts/elastic_sql/
sql_scripts/data_quality_sql/
sql_scripts/never_watched_insider_sql/
sql_scripts/Insider_sql/
sql_scripts/monitoring/
```

Önemli alt klasör dosyaları:

```text
elastic_sql/Prod_Gain_Elastic_Select_All_User_Data.sql
elastic_sql/Prod_Gain_Elastic_Update_All_User_Data.sql
elastic_sql/Prod_Gain_Elastic_Insert_All_User_Data.sql

data_quality_sql/iys_data_quality_check.sql
data_quality_sql/user_actions_data_quality_check.sql
data_quality_sql/user_core_validations.sql
data_quality_sql/user_date_consistency_checks.sql
data_quality_sql/user_subscription_promotion_rules.sql

monitoring/ga4_hourly_event_check.sql

never_watched_insider_sql/get_all_current_never_watched_users_to_push_upsert_api.sql
never_watched_insider_sql/guncel_premium_user.sql
never_watched_insider_sql/never_watched_user_paid.sql
never_watched_insider_sql/new_never_watched_user_a.sql
never_watched_insider_sql/segmented_user_table.sql
never_watched_insider_sql/updated_never_watched_user_b.sql

Insider_sql/Prod_Gain_Insider_Daily_Upsert_Api_Get_Updated_User_Data.sql
Insider_sql/Prod_Gain_Insider_Daily_Upsert_Api_Custom_User_Attributes_Data.sql
```

---

## 12. Örnek çalışan DAG + script akışı

Kullanıcı ayrıca iki dosya yükledi:

```text
Prod_Gain_Elastic_User_All_Data_To_Bq_Dag.py
Prod_Gain_Elastic_User_All_Data_To_Bq_Script.py
```

Bu ikisi mevcut sistemin tipik çalışma modelini gösteriyor.

DAG tarafı:

- `boto3` ile S3 client oluşturuyor.
- S3'ten script indiriyor:

```text
bucket: gain-data-airflow-bucket
s3_key: python_scripts/Prod_Gain_Elastic_User_All_Data_To_Bq_Script.py
```

- Script'i temp dizine indiriyor.
- `importlib.util.spec_from_file_location` ile dynamic import ediyor.
- Script içindeki `fetch_dim_user_raw_and_push_bq(execution_date=execution_date)` fonksiyonunu çağırıyor.
- DAG schedule:

```text
30 3 * * *
```

- `catchup=True`
- `max_active_runs=1`
- retries: 1
- retry delay: 5 dakika

Script tarafı:

1. Airflow context'ten `execution_date` alıyor.
2. ETL tarih aralığını UTC olarak hesaplıyor.
3. Airflow Connection üzerinden Elasticsearch bilgilerini alıyor:

```text
elasticsearch_default
```

4. Elastic index:

```text
gain_2da7kf8jf_prod_user
```

5. `updatedAt` veya `createdAt` alanına göre ilgili gün verisini scroll ile çekiyor.
6. DataFrame'e çeviriyor.
7. `appliedApplicationForms` gibi list alanlarını JSON string'e çeviriyor.
8. `etl_date`, `createdAt`, `updatedAt` gibi tarih alanlarını normalize ediyor.
9. BigQuery target:

```text
project: microgain-9f959
table: gain_model_prod.prod_dim_user_raw
```

10. Airflow BigQuery connection:

```text
google_cloud_default_full
```

11. Aynı `etl_date` için eski kayıtları siliyor.
12. Yeni kayıtları `pandas_gbq.to_gbq(..., if_exists='append')` ile append ediyor.
13. Ardından S3'ten SQL scriptleri okuyup sırayla çalıştırıyor:

```text
sql_scripts/elastic_sql/Prod_Gain_Elastic_Select_All_User_Data.sql
sql_scripts/elastic_sql/Prod_Gain_Elastic_Update_All_User_Data.sql
sql_scripts/elastic_sql/Prod_Gain_Elastic_Insert_All_User_Data.sql
```

14. Hata olursa Teams alert atıyor.

Bu model teknik olarak çalışıyor ve ekranda başarılı run'lar görünüyor. Ancak webhook URL gibi secret değerler kod içinde hardcoded olmamalı.

---

## 13. XCom hakkında gözlem

Kullanıcı XCom ekran görüntüsü iletti. XCom'da görülen kayıtlar:

- `Prod_Gain_Daily_Elastic_User_Data_To_Insider_Dag`
- `prod_subs_payment_data_validation`
- `Prod_Gain_Never_Watched_Users_Data_To_Insider_Panel_Dag`

Bazı XCom key'leri:

```text
total_sent
return_value
```

Bu şu anlama geliyor:

- Bazı DAG/task'ler runtime output bilgisini XCom'a yazıyor.
- Örneğin Insider'a gönderilen toplam kullanıcı sayısı `total_sent` olarak tutuluyor olabilir.
- Validation job'larında Redshift count sonucu `return_value` olarak görünüyor olabilir.

XCom operasyonel debug için faydalı ama uzun vadeli monitoring store olarak kullanılmamalı. Özet metrikler BigQuery monitoring tablolarında tutulmalı; XCom daha çok task-to-task geçici state için kullanılmalı.

---

## 14. Bağlantılar / connection id'leri

Kod taramasında görülen Airflow connection id'leri:

```text
google_cloud_default
google_cloud_default_full
elasticsearch_default
insider_prod
insider_uat
redshift_default_prod
Redshift_Serverless_Prod_User
Redshift_Serverless_Test
aws_default
```

Bu connection'lar Airflow UI içinde şu yoldan kontrol edilebilir:

```text
Admin > Connections
```

Kontrol edilmesi gerekenler:

- Connection id birebir aynı mı?
- Host/login/password/extra alanları doğru mu?
- GCP service account hangi connection'da tutuluyor?
- Redshift serverless credential güncel mi?
- Insider prod ve UAT tokenları ayrı mı?
- AWS default connection MWAA IAM role ile mi çalışıyor?

---

## 15. Secret / token / credential riski

Mevcut dosyalarda bazı hassas değerlerin kod veya dosya içinde bulunma riski var. Güvenlik nedeniyle bu dokümana secret değerlerin kendisi yazılmamıştır.

Görülen risk tipleri:

- Teams webhook URL hardcoded olabilir.
- API bearer token veya refresh token benzeri değerler kod içinde olabilir.
- `airflow_keys/token_store.json` içinde token store benzeri bilgiler var.
- Buildspec AWS Secrets Manager'dan GitHub SSH key çekiyor.
- Insider / API / BO / Elasticsearch / Redshift credential'ları Airflow Connection içinde olmalı.

Production için öneri:

- Webhook, bearer token, refresh token, password gibi değerler koddan çıkarılmalı.
- Airflow Connections veya AWS Secrets Manager kullanılmalı.
- Token yenileme gerekiyorsa `refresh_token` mantığı script içinde değil, güvenli storage ile çalışmalı.
- Token store S3'te tutulacaksa IAM policy, encryption ve access scope net olmalı.
- Mümkünse Airflow Variable yerine AWS Secrets Manager tercih edilmeli.

---

## 16. Mevcut mimari modeli

Şu anki çalışan model genel olarak şöyle:

```text
S3 bucket
├── airflow-dags/*.py
├── python_scripts/*.py
├── sql_scripts/**/*.sql
└── requeriments.txt

MWAA
↓
DAG parse
↓
PythonOperator
↓
Runtime'da S3'ten script download
↓
Dynamic import
↓
Script execution
↓
Source system/API/S3/Elastic/Redshift
↓
BigQuery veya Redshift veya Insider
↓
SQL post-processing / monitoring / alert
```

Bu model avantajlı:

- DAG dosyası küçük kalıyor.
- Business logic scriptlerde tutuluyor.
- SQL dosyaları ayrı yönetiliyor.
- S3 path ile merkezi deploy yapılabiliyor.

Dezavantajları:

- Runtime dynamic import debug'u zorlaştırabilir.
- Script path yanlışsa DAG parse olur ama task runtime'da patlar.
- Dependency eksikliği parse aşamasında değil runtime'da görülebilir.
- Secret yönetimi dağınıksa production riski yaratır.
- DAG ve script versiyon uyumsuzluğu olabilir.

---

## 17. Direkt S3'e dosya atmak çalışır mı?

Kısa cevap:

> Teknik olarak evet, mevcut yapıda DAG dosyalarını ve scriptleri doğru S3 path'lerine atınca MWAA bunları görebilir ve çalıştırabilir. Ama prod'da körlemesine yapmak doğru değildir.

Neden riskli?

- Prod MWAA schedule'ı otomatik alır.
- DAG parse olduğu anda UI'a düşer.
- `is_paused_upon_creation` set edilmemişse schedule aktif olabilir.
- Yanlış target tabloya yazabilir.
- Eski scriptle yeni DAG veya yeni scriptle eski DAG uyumsuz çalışabilir.
- Requirements eksikse job runtime'da fail olur.
- Hardcoded test parametreleri prod'a veri basabilir.
- CI/CD ile manuel S3 upload arasında drift oluşur.

Güvenli yaklaşım:

```text
1. Yeni dosyaları önce local/test isimleriyle hazırlamak
2. Target BigQuery dataset'i test dataset yapmak
3. DAG id'yi test/staging prefix ile oluşturmak
4. Schedule kapalı veya None yapmak
5. MWAA'ya paused şekilde deploy etmek
6. Manual trigger ile test etmek
7. BigQuery output kontrolü yapmak
8. Prod target'a geçmek
9. Schedule açmak
```

---

## 18. Yeni yazılan scriptler için önerilen test stratejisi

Kullanıcı, yeni yazılan scriptlerin önce lokal çalıştırılıp BigQuery fieldlarını doğru doldurup doldurmadığının test edilmesi gerektiğini söyledi. Bu doğru yaklaşım.

Önerilen lokal/test adımları:

### 18.1. Local smoke test

Her script için:

```text
python xxx.py --mode manual --start-date YYYY-MM-DD --end-date YYYY-MM-DD --dry-run
```

Script şu kontrolleri yapmalı:

- API/source connection kuruluyor mu?
- Beklenen response geliyor mu?
- DataFrame oluşuyor mu?
- Kolon adları beklenen gibi mi?
- Data type dönüşümleri patlıyor mu?
- Boş veri geldiğinde davranış doğru mu?

### 18.2. BigQuery test dataset'e yazma

Prod target yerine test target kullanılmalı:

```text
microgain-9f959.<test_dataset>.<table_name>
```

Örnek naming:

```text
microgain-9f959.airflow_test.<source>_raw
microgain-9f959.airflow_test.<source>_normalized
```

### 18.3. Schema kontrolü

Her output tablo için:

```sql
SELECT *
FROM `project.dataset.table`
LIMIT 100;
```

Ayrıca:

```sql
SELECT
  COUNT(*) AS row_count,
  COUNT(DISTINCT id) AS unique_id_count,
  MIN(created_at) AS min_created_at,
  MAX(created_at) AS max_created_at
FROM `project.dataset.table`;
```

### 18.4. Backfill kontrolü

Backfill yapılabilen kaynaklar için küçük tarih aralığıyla test:

```text
1 gün
3 gün
1 hafta
1 ay
```

Backfill sırasında:

- Aynı gün tekrar çalışınca duplicate oluşuyor mu?
- Delete + insert mi yapıyor?
- Merge/upsert mi yapıyor?
- Partition filtresi doğru mu?
- `etl_date` ve source event date ayrımı doğru mu?

### 18.5. Airflow manual run

MWAA'da test DAG:

- paused deploy
- manual trigger
- log kontrolü
- XCom gerekiyorsa kontrol
- BigQuery output kontrol
- alert test

---

## 19. BigQuery raw/stage/final yaklaşımı

Kullanıcı raw tutmaya gerek olup olmadığından emin değil. Mevcut bazı scriptler Python içinde field ayrıştırması yapıyor olabilir.

Önerilen yaklaşım:

### Raw tutmanın faydalı olduğu durumlar

- API response karmaşıksa
- Backfill değerliyse
- Source schema değişebiliyorsa
- Debug ihtimali yüksekse
- Data volume makul seviyedeyse
- Reprocess ihtiyacı olacaksa

### Raw tutmanın şart olmadığı durumlar

- Source zaten normalize dosya veriyorsa
- Data çok küçük ve kolay tekrar çekilebiliyorsa
- API geçmiş veri sağlamıyorsa
- Script zaten deterministic şekilde clean output üretiyorsa

Önerilen genel katman:

```text
raw      -> source'tan gelen ham veya minimum dönüştürülmüş veri
staging  -> fieldları ayrılmış, typed, cleaned veri
mart     -> Looker/raporlama kullanımı için aggregate veya business-ready tablo
```

Ama her job için bu kadar katman şart değildir. Yeni scriptler incelendiğinde karar verilmeli.

---

## 20. Error handling / alert beklentisi

Kullanıcı retry + Slack alert istedi. Mevcut bazı scriptlerde Teams alert var.

Önerilen standart:

DAG default args:

```python
retries = 2
retry_delay = timedelta(minutes=5)
retry_exponential_backoff = True
max_retry_delay = timedelta(minutes=30)
```

DAG-level callback:

```python
on_failure_callback = send_alert
on_retry_callback = send_retry_alert  # opsiyonel
```

Task-level:

- Kritik tasklerde ayrıca alert olabilir.
- Ancak script içi alert + DAG callback çifte bildirim üretebilir; standartlaştırmak gerekir.

Alert içeriği:

```text
DAG id
Task id
Run id
Execution date
Try number
Log URL
Hata mesajı
Target table/source
```

Mevcut Teams webhook hardcoded olduğu için alert mekanizması connection/secret üzerinden çalışacak hale getirilmeli.

Slack istenirse:

- `apache-airflow-providers-slack` zaten requirements içinde var.
- Airflow Connection: `slack_default` veya custom conn id.
- Slack webhook/token Airflow Connection veya Secret Manager'da tutulmalı.

---

## 21. Schedule ve çalışma modları

Kullanıcı, yeni yazılan bazı scriptlerde manual test kolaylığı için `Daily`, `Monthly`, `Manual` gibi çalışma modları bırakıldığını söyledi.

Bunlar yeni scriptler gelince kontrol edilmeli. İdeal model:

```text
mode=daily    -> Airflow schedule üzerinden T-1/T execution date çalışır
mode=monthly  -> ay kapanışı veya aylık raporlar için kullanılır
mode=manual   -> kullanıcı parametresi ile tarih aralığı çalışır
```

Airflow'da parametre yönetimi için:

- `dag_run.conf`
- Airflow Variables
- DAG params

kullanılabilir.

Örnek manuel trigger config:

```json
{
  "mode": "manual",
  "start_date": "2026-05-01",
  "end_date": "2026-05-31"
}
```

Dikkat edilmesi gerekenler:

- Scheduled run ile manual run aynı target tabloya duplicate yazmamalı.
- Manual mode prod tabloya yazacaksa önce delete/merge mantığı olmalı.
- Monthly mode hangi ayı hesaplıyor net olmalı: current month mı previous month mı?
- Timezone açıkça belirlenmeli: Europe/Istanbul mı UTC mi?

---

## 22. Backfill stratejisi

Kullanıcı backfill yapılabilen kaynaklarda geçmiş datayı almak istiyor. Bu mantıklı çünkü geriye dönük veri değerli.

Önerilen backfill standardı:

- Backfill tüm kaynaklarda aynı olmayacak.
- API geçmiş veri sağlıyorsa backfill yapılabilir.
- Her job için `start_date`, `end_date`, `mode` parametresi olmalı.
- Backfill sırasında `catchup=True` kullanılabilir ama dikkatli olunmalı.
- Büyük backfill için Airflow scheduled catchup yerine batch/manual run daha kontrollü olabilir.

Kontrol edilmesi gerekenler:

```text
API rate limit
sayfalama/pagination
aynı gün tekrar çalışınca duplicate riski
BigQuery partition delete/insert veya MERGE yapısı
timezone farkı
```

---

## 23. Mevcut production çalışan job'lara dokunma stratejisi

Prod çalışan sistemde yapılacak en güvenli yaklaşım:

1. Var olan çalışan DAG/script dosyalarına dokunma.
2. Yeni işler için ayrı DAG id ve dosya adı kullan.
3. İlk deploy'da schedule kapalı/paused olsun.
4. Prod table yerine test table kullan.
5. Manual run ile doğrula.
6. Output doğruysa target'ı prod dataset'e çevir.
7. Sonra schedule aç.

Önerilen naming:

```text
Test_<Job_Name>_Dag.py
Test_<Job_Name>_Script.py
```

prod'a geçince:

```text
Prod_<Job_Name>_Dag.py
Prod_<Job_Name>_Script.py
```

DAG id değişirse Airflow bunu yeni DAG olarak görür; eski DAG S3'ten silinmezse UI'da kalabilir.

---

## 24. Dosya isimlendirme standardı önerisi

Mevcut sistemde genel naming pattern:

```text
Prod_Gain_<Source>_<Purpose>_To_<Target>_Dag.py
Prod_Gain_<Source>_<Purpose>_To_<Target>_Script.py
```

Örnek:

```text
Prod_Gain_Elastic_User_All_Data_To_Bq_Dag.py
Prod_Gain_Elastic_User_All_Data_To_Bq_Script.py
```

Yeni işler için öneri:

```text
Prod_Gain_<Provider>_<DataType>_To_Bq_Dag.py
Prod_Gain_<Provider>_<DataType>_To_Bq_Script.py
```

Eğer hem daily hem monthly aynı script içinde mod olarak varsa tek DAG veya iki DAG olabilir:

```text
Prod_Gain_Apple_Transactions_Daily_To_Bq_Dag.py
Prod_Gain_Apple_Transactions_Monthly_To_Bq_Dag.py
Prod_Gain_Apple_Transactions_To_Bq_Script.py
```

veya:

```text
Prod_Gain_Apple_Transactions_To_Bq_Dag.py
Prod_Gain_Apple_Transactions_To_Bq_Script.py
```

Tek script + çok DAG modeli daha temiz olabilir; çünkü script ortak fonksiyonları tutar, DAG sadece schedule/mode verir.

---

## 25. Yeni scriptler için beklenen klasör yapısı

Kullanıcı yeni yazılan py dosyalarını toparlayacak. İdeal paket yapısı:

```text
new_jobs/
├── airflow-dags/
│   ├── Prod_Gain_X_To_Bq_Dag.py
│   └── ...
├── python_scripts/
│   ├── Prod_Gain_X_To_Bq_Script.py
│   └── ...
├── sql_scripts/
│   ├── x/
│   │   └── transform.sql
│   └── ...
├── config/
│   └── sample_config.json  # varsa, secretsız
└── README.md
```

Her job için ayrıca şu bilgi iyi olur:

```text
source adı
data türü
günlük/aylık/manual çalışma ihtiyacı
beklenen BigQuery target dataset/table
backfill mümkün mü?
credential/token ihtiyacı var mı?
örnek output var mı?
```

---

## 26. Yeni script review checklist

Yeni dosyalar geldiğinde her script için şu kontrol yapılacak:

### Kod yapısı

- Script doğrudan import edilince çalışıyor mu, yoksa `if __name__ == '__main__'` altında mı çalışıyor?
- Airflow'dan çağrılacak net fonksiyon var mı?
- Parametreler `execution_date` veya `dag_run.conf` ile alınabiliyor mu?
- Timezone net mi?

### Source/API

- API endpoint hardcoded mu?
- Token hardcoded mu?
- Refresh token mantığı var mı?
- Pagination var mı?
- Rate limit handling var mı?
- Empty response davranışı doğru mu?

### BigQuery

- Target project/dataset/table doğru mu?
- Test target kullanılabiliyor mu?
- Schema net mi?
- DataFrame kolonları BigQuery fieldlarıyla uyumlu mu?
- Date/timestamp alanları doğru mu?
- Numeric alanlar doğru type'a çevriliyor mu?
- Idempotent mi? Aynı run tekrar ederse duplicate yaratıyor mu?

### Airflow

- DAG id unique mi?
- schedule doğru mu?
- `catchup` ihtiyaca uygun mu?
- `max_active_runs=1` var mı?
- retry var mı?
- alert callback var mı?
- dynamic import path doğru mu?

### Security

- Secret yok mu?
- Token yok mu?
- Webhook yok mu?
- Local path veya credential file dependency var mı?

### Operasyon

- Log mesajları yeterli mi?
- Row count loglanıyor mu?
- Source date range loglanıyor mu?
- Failure durumunda anlamlı hata veriyor mu?

---

## 27. Local test için önerilen komut yapısı

Yeni scriptleri lokal test edebilmek için mümkünse her scriptte CLI veya fonksiyonel entrypoint olmalı.

Örnek:

```bash
python Prod_Gain_X_To_Bq_Script.py \
  --mode manual \
  --start-date 2026-05-01 \
  --end-date 2026-05-02 \
  --target-dataset airflow_test \
  --dry-run false
```

Eğer mevcut scriptler Airflow Hook kullandığı için lokal çalışmıyorsa iki seçenek var:

1. Local Airflow connection setup yapmak.
2. Scripti refactor edip core business logic'i Airflow bağımlılığından ayırmak.

Önerilen refactor:

```text
fetch_data()
transform_data()
load_to_bq()
run(mode, start_date, end_date, target_table)
```

Airflow DAG sadece `run()` fonksiyonunu çağırmalı.

---

## 28. BigQuery test/doğrulama SQL şablonları

Her yeni tablo için ilk kontrol:

```sql
SELECT *
FROM `microgain-9f959.<dataset>.<table>`
LIMIT 100;
```

Satır ve tarih kontrolü:

```sql
SELECT
  COUNT(*) AS row_count,
  MIN(DATE(<date_field>)) AS min_date,
  MAX(DATE(<date_field>)) AS max_date
FROM `microgain-9f959.<dataset>.<table>`;
```

Duplicate kontrolü:

```sql
SELECT
  <business_key>,
  COUNT(*) AS cnt
FROM `microgain-9f959.<dataset>.<table>`
GROUP BY <business_key>
HAVING COUNT(*) > 1
ORDER BY cnt DESC;
```

Null kritik alan kontrolü:

```sql
SELECT
  COUNT(*) AS total_rows,
  COUNTIF(<critical_field> IS NULL) AS null_critical_field
FROM `microgain-9f959.<dataset>.<table>`;
```

---

## 29. Insider journey yorumu hakkında açıklama

Konuşmada başka bir Jira yorumuyla ilgili açıklama da yapıldı. Yorum şuydu:

```text
1. Payment fail recovery
2. Cancel intent interception
3. Personalized content comeback flow

bu üç başlık özelinde insider tarafında journey çalışması yapılmasını teklif ediyorum nedersiniz?
```

Açıklama:

- Bu öneri teknik data pipeline işinden ziyade CRM/growth/retention automation önerisidir.
- Insider üzerinden kullanıcı lifecycle journey kurgulanması isteniyor olabilir.

Başlıkların anlamı:

```text
Payment fail recovery
→ Ödeme başarısız olan kullanıcıyı abonelikten düşmeden önce geri kazanma akışı.

Cancel intent interception
→ İptal etmeye niyetlenen kullanıcıyı iptal öncesinde yakalayıp teklif/mesaj ile vazgeçirme akışı.

Personalized content comeback flow
→ İzlemeyi bırakmış veya pasifleşmiş kullanıcıyı kişiselleştirilmiş içerik önerileriyle geri döndürme akışı.
```

Bu yorum ayrı bir Insider/CRM task olarak ayrılabilir; mevcut Airflow/S3/BQ migration task'ına doğrudan dahil edilmemelidir.

---

## 30. Önemli kararlar / varsayımlar

Bu konuşmada netleşenler:

- Airflow ortamı AWS MWAA.
- Mevcut sistem S3 tabanlı DAG/script/SQL yönetimi kullanıyor.
- Prod dosyaları doğrudan S3'e atmak teknik olarak mümkün ama riskli.
- Production'a almadan önce lokal/test BQ dataset doğrulaması yapılmalı.
- Looker fazı sonraya bırakılacak.
- Retry + Slack/Teams alert hedefleniyor.
- Backfill yapılabilen kaynaklarda geçmiş veri alınmak isteniyor.
- Yeni yazılmış scriptler tekrar iletilecek; tam kod seviyesinde yeniden analiz edilecek.
- Mevcut çalışan S3 dosyaları yeni işler için referans mimari olarak kullanılabilir.

Varsayımlar:

- Bucket adı `gain-data-airflow-bucket` olarak devam ediyor.
- MWAA DAG folder path muhtemelen `airflow-dags/` veya buna bağlı bir path.
- `python_scripts/` ve `sql_scripts/` mevcut DAG'lerin runtime dependency path'i.
- GCP/BigQuery auth Airflow connection üzerinden çözülüyor.
- AWS S3 erişimi MWAA execution role ile çözülüyor.

Doğrulanması gerekenler:

- MWAA requirements path gerçekten `requeriments.txt` dosyasını mı gösteriyor?
- GitHub/CodeBuild pipeline aktif mi ve production deploy buradan mı yapılıyor?
- Yeni dosyalar manuel S3 upload ile mi yoksa repo/PR ile mi deploy edilecek?
- Slack mi Teams mi kullanılacak?
- BigQuery test dataset adı ne olacak?
- Her yeni job için source credential nerede tutulacak?

---

## 31. Sonraki adımlar

Kullanıcı yeni yazılan ve elden geçmesi gereken py dosyalarını toparlayacak.

Agent'ın bir sonraki adımda yapması gerekenler:

1. Kullanıcının göndereceği yeni zip'i aç.
2. `airflow-dags`, `python_scripts`, `sql_scripts` ayrımını çıkar.
3. Her DAG için script eşleşmesini tespit et.
4. Her script için import/dependency analizi yap.
5. Her script için credential/secret taraması yap; secret değerlerini asla yanıta yazma.
6. Her script için BigQuery target tablolarını çıkar.
7. Her script için local test planı yaz.
8. Requirements final önerisini hazırla.
9. Prod deploy checklist oluştur.
10. Gerekirse scriptleri test dataset kullanacak şekilde refactor et.

Önerilen çıktı formatı:

```text
1. Envanter tablosu
2. Job bazlı risk analizi
3. Requirements önerisi
4. Secret/connection taşıma listesi
5. Local test komutları
6. BigQuery doğrulama SQL'leri
7. MWAA deploy checklist
```

---

## 32. Agent için kısa özet

Bu işte temel yaklaşım şu olmalı:

> Mevcut prod MWAA/S3 yapısını bozma. Önce yeni scriptleri test BigQuery dataset'e yazacak şekilde doğrula. Sonra DAG'leri paused/manual çalışacak şekilde MWAA'ya al. Output doğrulandıktan sonra prod target + schedule aktif et. Secrets koddan çıkarılmadan production'a geçme.

En kritik riskler:

```text
hardcoded token/webhook
requirements eksikliği
manual S3 upload drift'i
prod tabloya yanlış/duplicate yazma
DAG schedule'ın istemeden aktif olması
repo/S3 arasında silinmeyen eski DAG kalıntıları
```

En kritik doğrulamalar:

```text
MWAA details ekranı
requirements path
execution role/IAM access
Airflow Connections
BigQuery test dataset
yeni scriptlerin target table/schema bilgisi
```
