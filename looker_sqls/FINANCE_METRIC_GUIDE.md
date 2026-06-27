# GAIN Finans Dashboard Metrik Rehberi

## Brüt ve net

- `gross_*`: Müşteriden çekilen tutar. Ödeme kuruluşu komisyonu düşülmemiştir.
- `net_*`: Yalnız ödeme kuruluşu komisyonu düşülmüştür.
- Hiçbir finans SQL'inde vergi düşülmez.

## MRR ve tahsilat farkı

MRR bir tarih anındaki ücretli abonelerin aylık tekrar eden gelir kapasitesidir.
Ödeme gününden bağımsız bir snapshot metriğidir.

Tahsilat, ödeme işleminin gerçekten gerçekleştiği gündeki para akışıdır.
Bir ayın tahsilatı ile o ay sonundaki MRR aynı rakam olmak zorunda değildir.

## Looker kart eşleştirmesi

| Kart | Kullanılacak alan | Looker agregasyonu |
|---|---|---|
| MRR BO - önceki tamamlanmış ay sonu | `net_mrr_previous_month_end_tl` | `MAX` |
| MRR BO - seçili tarih sonu | `net_mrr_selected_end_tl` | `MAX` |
| Önceki tamamlanmış ay net tahsilatı | `previous_month_net_collections_tl` | `MAX` |
| Son 30 gün net tahsilatı | `trailing_30d_net_collections_tl` | `MAX` |
| Seçili tarih aralığı net tahsilatı | `selected_period_net_collections_tl` | `MAX` |
| Seçili tarih aralığı brüt tahsilatı | `selected_period_gross_collections_tl` | `MAX` |
| Seçili tarih aralığı işlem adedi | `selected_period_transaction_count` | `MAX` |
| Günlük net tahakkuk geliri | `net_accrued_revenue_tl` | `SUM` |
| Günlük ücretli abone | `paid_subscribers` | Günlük değer |
| Ay sonu ücretli abone | `paid_subscribers` + `is_month_end = true` | `MAX` |

`previous_month_*`, `trailing_30d_*` ve `selected_period_*` alanları yalnız
`is_selected_end = true` satırında doludur. Bu alanlarda `SUM` yerine `MAX`
kullanılması daha güvenlidir.

## Tarih filtresi davranışı

Sorgudaki bütün hazır dönemler `@DS_END_DATE` tarihine göre hesaplanır.

- Dashboard varsayılan bitiş tarihi T-1 ise hazır kartlar otomatik güncellenir.
- Tarih filtresinin bitiş tarihi değiştirilirse “önceki ay” ve “son 30 gün”
  yeni seçilen bitiş tarihine göre tekrar hesaplanır.
- Tamamen serbest bir tarih aralığı için `selected_period_*` alanları kullanılır.

Başlık kartları için ayrıca kullanıcıya tarih filtresi yaptırmak gerekmez.
Esnek analiz ve özel dönem taleplerinde `selected_period_*` kullanılmalıdır.

## Forecast LTV

`forecast_ltv_tl`:

```text
Tamamlanmış ay net ARPU / önceki 3 tamamlanmış ay ortalama kayıp oranı
```

Kaybedilmiş kullanıcı statüleri:

- `IN_GRACE`
- `ON_HOLD`
- `EXPIRED`

Kısmi aylar forecast sorgusuna dahil edilmez.

## Realized LTV

`realized_ltv_tl`, kullanıcının ilk gerçek ödemesinden metrik dönem sonuna kadar
gerçekleşmiş komisyon sonrası net ödemelerinin kullanıcı başına ortalamasıdır.

Tahakkuk veya paket bedelinin günlere bölünmüş hali kullanılmaz. Son ay kısmi
olabilir; karşılaştırmalarda `is_completed_month = true` filtresi önerilir.

## İkinci sayfa: Reklam Kanalı LTV/CAC

Veri kaynağı: `BC_CHANNEL_LTVCAC_REALIZED_01`

- Yalnız ilk ödemesinden sonra üç aylık gözlem süresi tamamlanan cohort'lar
  kullanılır; churn eden kullanıcılar dahildir.
- `avg_realized_ltv_tl`, kullanıcının ilk üç ayındaki komisyon sonrası gerçek
  net tahsilat ortalamasıdır.
- CAC ve LTV aynı acquisition ayı ve aynı reklam kanalı üzerinden eşleştirilir.
- Kanal ataması ilk ödemeden önceki 30 gündeki son uygun paid touch'tır.
- Harcama bulunmayan kanal/aylar LTV/CAC oranına dahil edilmez.

### Looker tablo kurulumu

| Ayar | Alan |
|---|---|
| Filtre | `channel_scope = selected_period` |
| Boyut | `channel` |
| Kullanıcı | `users` |
| Harcama | `spend_tl` |
| CAC | `cac_tl` |
| İlk 3 aylık realized LTV | `avg_realized_ltv_tl` |
| Medyan ilk 3 aylık LTV | `median_realized_ltv_tl` |
| LTV/CAC | `ltv_cac_ratio` |
| Veri kalite durumu | `cac_status` |

Kanalın olgun kullanıcı sayısı çok düşükse oran oynaktır. Looker'da `users >= 30`
filtresi önerilir. Aylık trend için `channel_scope = monthly`, tarih boyutu
olarak `month` kullanılmalıdır.

### Geriye Dönük Analiz tablosu

Bu tabloda kanallar Looker içinde `SUM` veya basit ortalama ile
birleştirilmemelidir. SQL'in ürettiği ağırlıklı birleşik satır kullanılmalıdır:

| Ayar | Değer |
|---|---|
| Filtre 1 | `channel_scope = monthly` |
| Filtre 2 | `channel = all_paid_channels` |
| Boyut | `month` |
| İlk 3 aylık LTV | `avg_realized_ltv_tl` (`MAX`) |
| CAC | `cac_tl` (`MAX`) |
| LTV/CAC | `ltv_cac_ratio` (`MAX`) |

Tablonun veri kaynağı `BC_LTVCAC_REALIZED_MONTHLY_01` ise ayrıca kanal filtresi
gerekmez; sorgu zaten ay başına tek birleşik paid-channel satırı döndürür:

| Looker sütunu | Ham SQL alanı | Agregasyon |
|---|---|---|
| İlk 3 aylık LTV | `realized_ltv_tl` | `MAX` |
| CAC | `cac_tl` | `MAX` |
| LTV/CAC Ratio | `ltv_cac_ratio` | `MAX` |

Looker içinde yeniden oluşturulmuş `CAC (₺)`, `avg_realized_ltv_tl` veya
toplanmış ratio calculated field'ları kullanılmamalıdır. Kontrol amacıyla
`ratio_formula_check` alanı her satırda `realized_ltv_tl / cac_tl` sonucunu
verir ve `ltv_cac_ratio` ile birebir eşit olmalıdır.

`all_paid_channels` hesabında:

- LTV, kanallardaki kullanıcıların kullanıcı ağırlıklı ortalamasıdır.
- CAC, tüm paid kanal harcamalarının tüm attributed kullanıcılara bölümüdür.
- LTV/CAC, birleşik LTV'nin birleşik CAC'ye bölümüdür.

24 Haziran 2026 itibarıyla üç aylık gözlem süresi tamamen biten son cohort ayı
Şubat 2026'dır. Altı aylık doğru görünüm Eylül 2025 - Şubat 2026'dır; ancak
bu aylar yalnız otomatik reklam harcaması backfill'i tamamlandıktan sonra
gösterilmelidir. `manual_monthly_spend` finans sorgularında kullanılmaz.

## Heavy ve Light LTV

`BC_WATCHER_LTV_02` içindeki `avg_ltv_tl`, churn dahil ve ilk ödemeden sonra
üç aylık gözlem süresi tamamlanan kullanıcıların sabit ilk üç aylık realized
LTV değeridir. Grafiğin adı **İlk 3 Aylık Realized LTV - Heavy vs Light**
olmalıdır.

## Üçüncü sayfa: Kampanya Ekonomisi

Veri kaynağı: `BC_CAMPAIGN_UNIT_ECONOMICS_COHORT_02`

Organik/kampanyalı ayrımı için `cohort_type_key = normal/campaign` kullanılır.
Eski `cohort_type` alanı geriye uyumluluk için büyük harfle dönmeye devam eder.

### Scorecard formülleri

| Metrik | Looker formülü |
|---|---|
| Realized LTV | `AVG(terminal_realized_ltv_anchor_tl)` |
| Aylık ARPU | `SUM(actual_net_revenue_tl) / SUM(active_flag)` |
| Blended CAC | `AVG(cac_user_anchor_tl)` |
| CAC Payback (ay) | `AVG(cac_user_anchor_tl) / (SUM(actual_net_revenue_tl) / SUM(active_flag))` |
| LTV/CAC | `AVG(terminal_realized_ltv_anchor_tl) / AVG(cac_user_anchor_tl)` |

`AVG(cum_actual_ltv_tl)` scorecard LTV'si olarak kullanılmaz. Aynı kullanıcıyı
her lifetime ayında yeniden ağırlıklandırdığı için eski 348/221 TL benzeri
değerler üretir.

CAC, reklam harcamasının tüm yeni ücretli kullanıcılara bölündüğü blended
metriktir. Reklam harcamasını promosyonlu ve promosyon uygulanmamış kullanıcıya
bağlayan bir attribution alanı bulunmadığından “Organik CAC” ve “Kampanya CAC”
gerçek anlamda ayrı acquisition maliyetleri değildir. Cohort'ların farklı
aylarda edinilmesi nedeniyle iki kart farklı çıkabilir. `cac_status = ok`
olmayan dönemler CAC, payback ve LTV/CAC değerlendirmesine alınmamalıdır.

### Grafikler

| Grafik | Boyut | Metrik |
|---|---|---|
| Aylık Net Tahsilat | `lifetime_month` | `SUM(actual_net_revenue_tl)` |
| Kümülatif Kullanıcı Başı Gelir / LTV | `lifetime_month` | `AVG(cum_actual_ltv_tl)` |
| Aylık Müşteri Kayıp Oranı | `lifetime_month` | `SUM(churn_event_flag) / SUM(churn_risk_flag)` |
| Kümülatif Kaybedilmiş Payı | `lifetime_month` | `AVG(cumulative_inactive_flag)` |

Eski “Kümülatif Gelir” grafiğinde `SUM(cum_actual_ltv_tl)` kullanılmamalıdır.
İleri lifetime aylarında gözlemlenebilen cohort sayısı azaldığı için gerçekten
kümülatif bir değer olmasına rağmen çizgi aşağı düşer ve yanıltıcı görünür.

Aktiflik, tamamlanan aylarda ay sonu; devam eden ayda T-1 snapshot'ına göre
hesaplanır. SQL'in bitiş tarihi kullanıcı gelecekte bir tarih seçse bile T-1'i
geçmez. Haziran gibi tamamlanmamış ayları dışlamak gereken grafiklerde
`is_completed_activity_month = true`, CAC analizlerinde ise
`is_completed_cohort_month = true` filtresi kullanılabilir.

Kampanya adı/türü filtresi doğrudan tüm sayfaya uygulanırsa `promotion_name`
alanı boş olan organik cohort da filtre dışı kalır. Bir kampanyayı organik
baseline ile karşılaştırmak için kampanya adı ve türü kontrolleri yalnız
kampanya kartları/grafikleriyle aynı Looker grubunda tutulmalıdır. Ödeme aracı
filtresi iki cohort türüne de uygulanabilir.
