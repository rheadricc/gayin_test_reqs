import requests
import json
import pandas as pd

# API ve header ayarları
otp_headers_sec = {
    "Content-Type": "application/json",
    "User-Agent": "Python/requests",
    "Authorization": "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJwcm9qZWN0SWQiOiIyZGE3a2Y4amYiLCJpZGVudGl0eSI6ImJhY2tvZmZpY2VfdXNlciIsImFub255bW91cyI6ZmFsc2UsInVzZXJJZCI6IjlONk1jZXByQk5Eek1pYjZpYXVyd0Z3bSIsImNsYWltcyI6eyJuYW1lIjoiU8O8bGV5bWFuIFRlbGxpb8SfbHUiLCJlbWFpbCI6InN1bGV5bWFudGVsbGlvZ2x1QGdhaW4uY29tLnRyIiwic3RhdHVzIjoiYWN0aXZlIiwicm9sZSI6ImFkbWluIn0sInNlc3Npb25JZCI6IjgwMjJmNTYxMjQ2ODQwNTk5NjNkZDlhMTU5NzAxNGQwIiwiaWF0IjoxNzQ0NDk4NDI3LCJleHAiOjE3NDcwOTA0Mjd9.hJD8fIyceyAoSI9Sp1MNr4Q19oOLbdLYMRJYuwt3CFaeFEV2FItjA-KnqnlgTmFUPvh1YZ6Y16xkUOG2H3OX-Qw1Btk1NXl5dKL-os9vbCiYFyM9S0RAN1Aa-GPJ5zmezmjp14BRc74xY2EOs5v3y2BwQnBSJKCSGOD5XZDYlKRM3DrAkCP-GsiSbpjVHYkF3to0PL8SgIV6KtLFK3fULVhM--ssa1zHpmbaGFAV6CCVEctZYBORooYxjwYuJY10ZSZtgpNttnbwVtl1yIliDC2ySB3WIFUw7Yfe8lew4TO9TeyE3IUUJtO2PTHWJOVRUjtBPYz2rA_syb6RovOXhw"
}

genre_list_url = "https://api.gain.tv/2da7kf8jf/CALL/GenreManager/getGenreList/default?page={}&limit=10&sortOrder=asc&__culture=tr-tr"

def get_all_genres():
    """ Tüm sayfaları tarayarak Genre verilerini çeken fonksiyon """
    all_genres = []
    page = 1

    while True:
        response = requests.get(genre_list_url.format(page), headers=otp_headers_sec)

        if response.status_code == 200:
            response_data = response.json()
            genres = response_data.get('genres', [])
            meta = response_data.get('meta', {})

            if not genres:
                break

            # Verileri listeye ekle
            for genre in genres:
                genre_data = {
                    "genreId": genre.get("genreId", ""),
                    "name": genre.get("name", "").strip(),
                    "text_tr": genre.get("text", {}).get("tr-tr", "").strip(),
                    "text_en": genre.get("text", {}).get("en-us", "").strip(),
                    "createdAt": genre.get("createdAt", ""),
                    "updatedAt": genre.get("updatedAt", "")
                }
                all_genres.append(genre_data)

            # Mevcut sayfa ve toplam sayfa bilgisi
            current_page = int(meta.get('currentPage', 1))
            total_pages = int(meta.get('totalPages', 1))

            print(f"Sayfa {current_page}/{total_pages} tamamlandı. Toplam genre: {len(all_genres)}")

            # Son sayfaya ulaşıldığında döngüyü sonlandır
            if current_page >= total_pages:
                break

            page += 1
        else:
            print(f"Başarısız! Status code: {response.status_code}")
            break

    return all_genres

def main():
    all_genres = get_all_genres()

    # DataFrame oluştur ve NDJSON formatında kaydet
    df = pd.DataFrame(all_genres)
    df.to_csv("all_genres.csv", index=False)
    print("Tüm genre verileri 'all_genres.ndjson' dosyasına NDJSON formatında kaydedildi.")

main()
