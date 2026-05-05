import requests
import json
import pandas as pd

# API ve header ayarları
otp_headers_sec = {
    "Content-Type": "application/json",
    "User-Agent": "Python/requests",
    "Authorization": "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJwcm9qZWN0SWQiOiIyZGE3a2Y4amYiLCJpZGVudGl0eSI6ImJhY2tvZmZpY2VfdXNlciIsImFub255bW91cyI6ZmFsc2UsInVzZXJJZCI6IjlONk1jZXByQk5Eek1pYjZpYXVyd0Z3bSIsImNsYWltcyI6eyJuYW1lIjoiU8O8bGV5bWFuIFRlbGxpb8SfbHUiLCJlbWFpbCI6InN1bGV5bWFudGVsbGlvZ2x1QGdhaW4uY29tLnRyIiwic3RhdHVzIjoiYWN0aXZlIiwicm9sZSI6ImFkbWluIn0sInNlc3Npb25JZCI6IjAxOTFlYTA3OTAyNjRlMWRhZTI1NmQxMzkxMjdhM2U2IiwiaWF0IjoxNzY2NTczNjk3LCJleHAiOjE3NjkxNjU2OTd9.shDvm7PwSDFICS_4HTzGLUexjNyAVomuMo2R2_90ggL49iXthPsVjyNZCukBe2UDj81YsE39hQI5WrEK0r100Kp7OfVEfk0hWGDLrnhDFF-nM-6VDaafgf8PZITLN9Lj52T9GtctBMFa16eo4V6nkLOuMwO7MhwY1mNs_iW2aDCyuBAhR6M_2Ida2Xjvb8xUDMYvozqEh2Zz5HWEFDIBq3fCh42FsahcszSIZSAUYs24zxyVHJ1Uv_p-D6uJmq7aRFaC_Ksh3WsGSW694yj2FtUpI6IKnnaNxV0VbLNEFnaa5o9GCCKjt43gJw7yI-JYzZj5dj37FduzouPtPC8P1w"
}

artist_list_url = "https://api.gain.tv/2da7kf8jf/CALL/ArtistManager/getArtistList/default?page={}&limit=10&sortOrder=asc&__culture=tr-tr"

def get_all_artists():
    """ Tüm sayfaları tarayarak artist verilerini çeken fonksiyon """
    all_artists = []
    page = 1

    while True:
        response = requests.get(artist_list_url.format(page), headers=otp_headers_sec)

        if response.status_code == 200:
            response_data = response.json()
            artists = response_data.get('artists', [])
            meta = response_data.get('meta', {})

            if not artists:
                break

            # Verileri listeye ekle
            for artist in artists:
                artist_data = {
                    "artistId": artist.get("artistId", ""),
                    "text": artist.get("text", "").strip(),
                    "description_tr": artist.get("description", {}).get("tr-tr", "").strip(),
                    "description_en": artist.get("description", {}).get("en-us", "").strip(),
                    "isActive": artist.get("isActive", False),
                    "createdAt": artist.get("createdAt", ""),
                    "updatedAt": artist.get("updatedAt", "")
                }
                all_artists.append(artist_data)

            # Mevcut sayfa ve toplam sayfa bilgisi
            current_page = int(meta.get('currentPage', 1))
            total_pages = int(meta.get('totalPages', 1))

            print(f"Sayfa {current_page}/{total_pages} tamamlandı. Toplam artist: {len(all_artists)}")

            # Son sayfaya ulaşıldığında döngüyü sonlandır
            if current_page >= total_pages:
                break

            page += 1
        else:
            print(f"Başarısız! Status code: {response.status_code}")
            break

    return all_artists

def main():
    all_artists = get_all_artists()

    # DataFrame oluştur ve NDJSON formatında kaydet
    df = pd.DataFrame(all_artists)
    df.to_csv("all_artists.csv", index=False)

main()
