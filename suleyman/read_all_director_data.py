import requests
import json
import pandas as pd

# API ve header ayarları
otp_headers_sec = {
    "Content-Type": "application/json",
    "User-Agent": "Python/requests",
    "Authorization": "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJwcm9qZWN0SWQiOiIzbW1uYmV0N3EiLCJpZGVudGl0eSI6ImJhY2tvZmZpY2VfdXNlciIsImFub255bW91cyI6ZmFsc2UsInVzZXJJZCI6IjhnNU1wcDlCVFJmeXJiODFhNlJPWkhiayIsImNsYWltcyI6eyJuYW1lIjoiS2FyZGVsZW4gWcO8Y2UiLCJlbWFpbCI6ImthcmRlbGVueXVjZUBnYWluLmNvbS50ciIsInN0YXR1cyI6ImFjdGl2ZSIsInJvbGUiOiJhZG1pbiJ9LCJzZXNzaW9uSWQiOiJmYjA2MWE3NTYzNmY0MmE0OGJiMzYyYmNlMWNiOGZlNCIsImlhdCI6MTc2NjU3MzA0NiwiZXhwIjoxNzY2NTc2NjQ2fQ.FIxoJZvsEri5rlZpC6bQtjMYDCYRunBmItIMj_GT2ORvTd7foXZaEtcRiCVKpPAVtuMXiwYonIAkSlbvQdncro3LwWHh-DY5lvkUvKJxrJYkGxqjsy7yaZyFCNxKLaAOM0Nqa7QgktIW6WPgKWwcbCB3UOo04rzevXrUxEvCgWtEkGHjJhzT9e3rE7gtnkA-7Ow-tVkSublE8zkeks9G67EE3RPT_BcCmnIySPC4xkEWrPHGRkW-WQM_caT8fb18uHeDvbO8iJT-WhNkjflKiUp-4Q5eLyJv4CVQWXGb_ZzTe4hYf4W0FfnDBV5jQTsKXe9W5sDu3OG1dxPRTvb8CQ"
}
director_list_url = "https://api-staging.gain.tv/3mmnbet7q/CALL/DirectorManager/getDirectorList/default?page=1&limit=10&sortOrder=asc&__culture=tr-tr"


def get_all_directors():
    """ Tüm sayfaları tarayarak yönetmen verilerini çeken fonksiyon """
    all_directors = []
    page = 1

    while True:
        response = requests.get(director_list_url.format(page), headers=otp_headers_sec)

        if response.status_code == 200:
            response_data = response.json()
            directors = response_data.get('directors', [])
            meta = response_data.get('meta', {})

            print("response_data")
            print(response_data)

            if not directors:
                break

            # Verileri listeye ekle
            for director in directors:
                director_data = {
                    "directorId": director.get("directorId", ""),
                    "text": director.get("text", "").strip(),
                    "description_tr": director.get("description", {}).get("tr-tr", "").strip(),
                    "description_en": director.get("description", {}).get("en-us", "").strip(),
                    "isActive": director.get("isActive", False),
                    "createdAt": director.get("createdAt", ""),
                    "updatedAt": director.get("updatedAt", "")
                }
                all_directors.append(director_data)

            # Mevcut sayfa ve toplam sayfa bilgisi
            current_page = int(meta.get('currentPage', 1))
            total_pages = int(meta.get('totalPages', 1))

            print(f"Sayfa {current_page}/{total_pages} tamamlandı. Toplam yönetmen: {len(all_directors)}")

            # Son sayfaya ulaşıldığında döngüyü sonlandır
            if current_page >= total_pages:
                break

            page += 1
        else:
            print(f"Başarısız! Status code: {response.status_code}")
            break

    return all_directors

def main():
    all_directors = get_all_directors()

    # DataFrame oluştur ve NDJSON formatında kaydet
    df = pd.DataFrame(all_directors)
    df.to_csv("all_directors.csv", index=False)
    print("Tüm yönetmen verileri 'all_directors.ndjson' dosyasına NDJSON formatında kaydedildi.")

main()
