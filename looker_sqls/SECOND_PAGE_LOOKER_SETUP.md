# İkinci Sayfa — Looker Kurulumu

SQL'leri Looker'a yeniden yapıştırdıktan sonra veri kaynağında **Alanları
yenile** işlemini çalıştır. Eski calculated field veya cache'te kalan alanları
grafiklerde kullanma.

## 1. Geriye Dönük Analiz

Veri kaynağı: `BC_LTVCAC_REALIZED_MONTHLY_01`

- Boyut: `month`
- Metrikler:
  - `realized_ltv_tl` — MAX
  - `cac_tl` — MAX
  - `ltv_cac_ratio` — MAX
- `channel` filtresi kullanma. Bu sorgu bütün ücretli kanalların birleşik sonucudur.
- `is_latest_mature_month = true` filtresini kaldır. Bu filtre yalnızca en son
  olgun cohort ayını bırakır.

## 2. Reklam Kanalı LTV

Veri kaynağı: `BC_CHANNEL_LTVCAC_REALIZED_01`

- Boyut: `channel`
- Metrik: `avg_realized_ltv_tl` — MAX
- Ek bilgi/tooltip:
  - `users`
  - `avg_payment_count_3m`
  - `cohort_start_month`
  - `cohort_end_month`
  - `loaded_cohort_month_count`
  - `cohort_window_status`
- Filtre gerekmez. Sorgu kanal başına yalnızca bir satır döndürür.
- Otomatik reklam harcaması olmayan kanallar gösterilmez.
- `cohort_window_status = partial_backfill` ise son altı olgun ayın reklam
  harcaması henüz tamamen yüklenmemiştir; kanal kıyasını nihai kabul etme.

`avg_realized_ltv_tl`, kullanıcının ilk ödemesinden sonraki üç ayda gerçekleşen
komisyon sonrası tahsilatlarının kullanıcı başına ortalamasıdır. Tek aylık ARPU
değildir.

## 3. Reklam Kanalı Aylık CAC

Veri kaynağı: `BC_CAC_MONTHLY_01`

- Boyut: `month`
- Kırılım boyutu: `channel`
- Metrik: `cac_tl` — MAX
- Filtre: `channel_scope = monthly`

`all_channels` serisi birleşik CAC değeridir. Grafikte istenmiyorsa ayrıca
`channel != all_channels` filtresi eklenebilir.

## 4. Reklam Kanalı CAC

Veri kaynağı: `BC_CAC_MONTHLY_01`

- Boyut: `channel`
- Metrik: `cac_tl` — MAX
- Filtreler:
  - `channel_scope = selected_period`
  - `channel != all_channels`
- Varsayılan son 28 gün filtresi kullanılabilir. Sorgu selected-period satırını
  raporun bitiş ayıyla etiketler ve hesabı son olgun cohort aylarından yapar.

## 5. Reklam Kanalı LTV/CAC

Veri kaynağı: `BC_CAC_MONTHLY_01`

- Boyut: `channel`
- Metrik: `ltv_cac_ratio` — MAX
- Filtreler:
  - `channel_scope = selected_period`
  - `channel != all_channels`
- Varsayılan son 28 gün filtresi kullanılabilir.

Bu oran doğrudan `realized_ltv_tl / cac_tl` hesabıdır. İki değer de aynı
tamamlanmış üç aylık acquisition-cohort evrenini kullanır.

## İlk Sayfa Bağlantıları

- Realized LTV ve geriye dönük altı aylık LTV:
  `BC_REALIZED_LTV_MONTHLY_01`
- CAC Payback Period ve LTV/CAC Ratio:
  `BC_LTVCAC_REALIZED_MONTHLY_01`

CAC Payback ve LTV/CAC kartlarında `is_latest_mature_month = true`
kullanılabilir; ancak kartın tarih aralığı son 28 gün olmamalıdır. En son olgun
cohort ayını kapsayacak şekilde en az son 12 ay seçilmelidir.
