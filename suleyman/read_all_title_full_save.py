import requests
import json
import pandas as pd


otp_headers_sec = {
    "Content-Type": "application/json",
    "User-Agent": "Python/requests",
    "Authorization": "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJwcm9qZWN0SWQiOiIyZGE3a2Y4amYiLCJpZGVudGl0eSI6ImJhY2tvZmZpY2VfdXNlciIsImFub255bW91cyI6ZmFsc2UsInVzZXJJZCI6IjlONk1jZXByQk5Eek1pYjZpYXVyd0Z3bSIsImNsYWltcyI6eyJuYW1lIjoiU8O8bGV5bWFuIFRlbGxpb8SfbHUiLCJlbWFpbCI6InN1bGV5bWFudGVsbGlvZ2x1QGdhaW4uY29tLnRyIiwic3RhdHVzIjoiYWN0aXZlIiwicm9sZSI6ImFkbWluIn0sInNlc3Npb25JZCI6ImI3ZWFkNWY1NjUxZDQzOTE4ODg3OTFiZTdhZjI2NGRlIiwiaWF0IjoxNzUzMDg4MTQwLCJleHAiOjE3NTU2ODAxNDB9.RF5IwAWePJ50TfyMqZa6Kt5QGLRtxFaRGBU14Ef0b5GhqSnUwmGp4-vfdRlNCvKBfUJe3Dnni2GcdPcvPW4aeSc-O-wz26wfZ4ELfROG3ckiu1KLHhkPGNfGdZUl6X5c_9eyVsrupvGwRqvKb_hhQzPLsggc_rwJ8PvXUhtzcExMPkGGeXVKf2uYYam_1bNAABqZvfnXRFPMsgpNfm2-IacxK_8YLIPxuEifjuZIz7IwAnFQHUQIFchS-Oxk46fgxJVL64SVICAztzsfVEEAZNQpkasnlNtfsm7HVaNjJc_G-wA-f2kzWZQVFwADXmJjt-Q4MYdAXS0f3cdyJT67vQ"
}

title_list_url = "https://api.gain.tv/2da7kf8jf/CALL/Title/getTitleListForBo/default?__culture=tr-tr"
title_detail_url = "https://api.gain.tv/2da7kf8jf/CALL/Title/getTitleDetailForBo/{}?__culture=tr-tr"

def get_all_title_ids():
    """ Tüm titleId'leri çeken fonksiyon """
    title_ids = []
    index = 0

    while True:
        params = {
            "query": "*",
            "from": index,
            "pageSize": 50,
            "sorts": [{"createdAt": "desc"}]
        }

        response = requests.post(title_list_url, headers=otp_headers_sec, json=params)

        if response.status_code == 200:
            response_data = response.json()
            page_data = response_data.get('result', [])

            if not page_data:
                break

            for title in page_data:
                title_ids.append(title.get('titleId'))

            index += 50
        else:
            print(f"Başarısız! Status code: {response.status_code}")
            break

    print(f"Toplam {len(title_ids)} adet titleId bulundu.")
    return title_ids

def get_title_details(title_id):
    """ Tek bir titleId için detayları çeken fonksiyon """
    url = title_detail_url.format(title_id)
    response = requests.get(url, headers=otp_headers_sec)

    if response.status_code == 200:
        data = response.json().get('title', {})

        title_data = {
            "titleId": data.get("titleId", ""),
            "displayName": data.get("displayName", ""),
            "type": data.get("type", ""),
            "geoBlocking": data.get("geoBlocking", ""),
            "contentType_id": data.get("contentType", {}).get("id", ""),
            "imdbScore": data.get("imdbScore", ""),
            "publishYear": data.get("publishYear", ""),
            "searchKeywords": data.get("searchKeywords", ""),
            "tags": [{"id": tag.get("id", ""), "name": tag.get("name", "")} for tag in data.get("tags", [])],
            "artists": [{"id": artist.get("id", ""), "text": artist.get("text", "")} for artist in data.get("artists", [])],
            "genres": [{"id": genre.get("id", ""), "name": genre.get("name", "")} for genre in data.get("genres", [])],
            "directors": [{"id": director.get("id", ""), "text": director.get("text", "")} for director in data.get("directors", [])],
            "smartSigns": [{"id": ss.get("id", ""), "name": ss.get("name", "")} for ss in data.get("smartSigns", [])],
            "description_tr": data.get("description", {}).get("tr-tr", ""),
            "shortDescription_tr": data.get("shortDescription", {}).get("tr-tr", "")
        }

        season_rows = []
        for season in data.get("seasons", []):
            video_contents = []
            for video_content in season.get("videoContents", []):
                vc_entry = {
                    "videoContentId": video_content.get("videoContentId", ""),
                    "name.tr-tr": video_content.get("name", {}).get("tr-tr", ""),
                    "shortName.tr-tr": video_content.get("shortName", {}).get("tr-tr", ""),
                    "type": video_content.get("type", ""),
                    "countryInfo": []
                }

                for country_info in video_content.get("countryInfo", []):
                    ci_entry = {
                        "smartSigns": [
                            {"id": ss.get("id", ""), "name": ss.get("name", "")}
                            for ss in country_info.get("smartSigns", [])
                        ],
                        "media": {
                            "duration": country_info.get("media", {}).get("duration", "")
                        }
                    }
                    vc_entry["countryInfo"].append(ci_entry)

                video_contents.append(vc_entry)

            sezon_bilgisi = season.get("name", {}).get("tr-tr", "")
            season_row = title_data.copy()
            season_row.update({
                "seasons": season.get("seasonId", ""),
                "season_info": sezon_bilgisi,
                "videoContents": video_contents
            })

            season_rows.append(season_row)

        return season_rows
    else:
        print(f"Detay alınamadı: {title_id}, Status code: {response.status_code}")
        return []

def main():
    title_ids = get_all_title_ids()
    all_season_data = []

    for title_id in title_ids:
        season_data = get_title_details(title_id)
        if season_data:
            all_season_data.extend(season_data)


    df = pd.DataFrame(all_season_data)

    df.to_csv("all_seasons.csv", index=False)

    print("Tüm sezon verileri 'all_seasons.csv' dosyasına csv formatında kaydedildi.")

main()
