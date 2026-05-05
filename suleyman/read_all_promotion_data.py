import requests
import json
import pandas as pd

# API ve header ayarları
otp_headers_sec = {
    "Content-Type": "application/json",
    "User-Agent": "Python/requests",
    "Authorization": "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJwcm9qZWN0SWQiOiIyZGE3a2Y4amYiLCJpZGVudGl0eSI6ImJhY2tvZmZpY2VfdXNlciIsImFub255bW91cyI6ZmFsc2UsInVzZXJJZCI6IjlONk1jZXByQk5Eek1pYjZpYXVyd0Z3bSIsImNsYWltcyI6eyJuYW1lIjoiU8O8bGV5bWFuIFRlbGxpb8SfbHUiLCJlbWFpbCI6InN1bGV5bWFudGVsbGlvZ2x1QGdhaW4uY29tLnRyIiwic3RhdHVzIjoiYWN0aXZlIiwicm9sZSI6ImFkbWluIn0sInNlc3Npb25JZCI6ImVjNzY4NTViNDNiMDQ2Nzc5N2M4ZTViMDc2MjRiMTM5IiwiaWF0IjoxNzYwNTE4MTk2LCJleHAiOjE3NjMxMTAxOTZ9.IdzPfign5ZzDvcI84iIoP7Kc8dDuXQ89q4SJKx3cd0e3Xl9IdCs-X3_HPQl-tLBZsoTd-9MBFAX6kCy4A_VuVuilVCXSChASUDE_kxo9XDnyYCvUfl6a9xbTMnSMh0Bwmt4bmr8hLA-5L1-paRMWsen28Al6zOUT_BLhUhMK6bd879dTJjbdrIFYUaUrY7KZ3KGnNDZYfDIGbqapGXuGk0ZnzwgUm-7Qayk7_bCkEY_UDZZVdJEYsdoEeDn75S7IX8sRDXL3dxrdoRlL_LA5Zdw1KMI_JU0nGl1r0qh6wpfT24NU1mon2hGQmfgQAktTvgYztJpW78DaYUTpu3lKrA"
}

promotion_list_url = "https://api.gain.tv/2da7kf8jf/CALL/Promotion/getPromotionList/default"

def get_all_promotions():
    """ Tüm sayfaları tarayarak Promotion verilerini çeken fonksiyon """
    all_promotions = []
    page = 0  # `from` değeri için başlangıç 0
    page_size = 10  # Sayfa başına 10 kayıt
    total_fetched = 0  # Toplam çekilen kayıt sayısı

    while True:
        # `POST` isteği için payload
        payload = {
            "query": "isActive:true",
            "from": page * page_size,
            "pageSize": page_size,
            "sorts": [{"createdAt": "desc"}]
        }

        # POST isteği
        response = requests.post(promotion_list_url, headers=otp_headers_sec, json=payload)

        if response.status_code == 200:
            response_data = response.json()
            promotions = response_data.get('result', [])
            meta = response_data.get('meta', {})

            if not promotions:
                break

            # Verileri listeye ekle
            for promotion in promotions:
                promotion_data = {
                    "promotionId": promotion.get("promotionId", ""),
                    "name": promotion.get("name", "").strip(),
                    "type": promotion.get("type", ""),
                    "isActive": promotion.get("isActive", False),
                    "countries": promotion.get("countries", []),
                    "paymentOptions": promotion.get("paymentOptions", []),
                    "campaignStartDate": promotion.get("campaignStartDate", ""),
                    "campaignEndDate": promotion.get("campaignEndDate", ""),
                    "codeCount": promotion.get("codeCount", 0),
                    "maxUsageCount": promotion.get("maxUsageCount", 0),
                    "usageCount": promotion.get("usageCount", 0),
                    "createdBy": promotion.get("createdBy", ""),
                    "createdAt": promotion.get("createdAt", ""),
                    "benefits": promotion.get("benefits", []),
                    "generatedCodeCount": promotion.get("generatedCodeCount", 0),
                    "assignedTo": promotion.get("assignedTo", [])
                }
                all_promotions.append(promotion_data)

            total_fetched += len(promotions)
            print(f"Sayfa {page + 1} tamamlandı. Toplam çekilen promotion: {total_fetched}")

            # Son sayfaya ulaşıldığında döngüyü sonlandır
            if len(promotions) < page_size:
                break

            page += 1
        else:
            print(f"Başarısız! Status code: {response.status_code}")
            break

    return all_promotions

def main():
    all_promotions = get_all_promotions()

    # DataFrame oluştur ve NDJSON formatında kaydet
    df = pd.DataFrame(all_promotions)


    df.to_csv("all_promotions_active.csv", index=False)

    df.to_json("all_promotions_passive.ndjson", orient="records", lines=True, force_ascii=False)
    print("Tüm aktif promotion verileri 'all_promotions.ndjson' dosyasına NDJSON formatında kaydedildi.")

main()
