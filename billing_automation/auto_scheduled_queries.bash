#bq ls --transfer_config --transfer_location=us | Bunun ile config sonunda lazım olan ID'yi alabilirsiniz.
#Mac veya Linux terminalinde çalıştırabilirsiniz. Öncelikle bq komut satırı aracını kurmanız gerekmektedir.
#Bu script, BigQuery Transfer Service kullanarak belirli bir transfer konfigürasyonu için istenilen yıldaki istenilen aylar için günlük transfer çalışmaları oluşturur. 
#Her gün için ayrı bir transfer çalışması oluşturulur ve her çalışmanın başlangıç ve bitiş zamanları belirtilir. Eğer transfer çalışması oluşturulurken bir hata oluşursa, script 180 saniye bekler ve tekrar denemeye devam eder.

CONFIG='projects/microgain-9f959/locations/us/transferConfigs/6a6005c4-0000-2657-9467-240588774a20'

for month in 01 02 03 04
do
  case "$month" in
    01|03) last_day=31 ;;
    02) last_day=28 ;;
    04) last_day=30 ;;
  esac

  for day in $(seq -w 1 $last_day)
  do
    echo "Starting 2026-${month}-${day}"

    until bq mk --transfer_run \
      --start_time="2026-${month}-${day}T00:00:00Z" \
      --end_time="2026-${month}-${day}T23:59:59Z" \
      "$CONFIG"
    do
      echo "Still busy, retrying in 180 seconds..."
      sleep 180
    done

    echo "Submitted 2026-${month}-${day}"
    echo "Waiting 180 seconds before next day..."
    sleep 180
  done
done