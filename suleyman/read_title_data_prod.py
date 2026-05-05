import bigquery
import requests
import json
import pandas as pd
import os
import boto3
from botocore.exceptions import ClientError
from google.cloud import bigquery
import farmhash

# S3 token dosyası ayarları
S3_BUCKET = "gain-test-bucket-1"
S3_KEY = "airflow_keys/token_store.json"
s3_client = boto3.client(
    "s3",
    aws_access_key_id="AKIA2LIP2KMHQEZ2Q2AV",
    aws_secret_access_key="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",
    region_name="eu-west-1"
)

REFRESH_URL = "https://api.gain.tv/2da7kf8jf/TOKEN/refresh?__culture=tr-tr"

def load_tokens():
    try:
        response = s3_client.get_object(Bucket=S3_BUCKET, Key=S3_KEY)
        return json.loads(response["Body"].read().decode("utf-8"))
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchKey":
            return {"accessToken": "", "refreshToken": ""}
        else:
            raise

def save_tokens(tokens):
    s3_client.put_object(
        Bucket=S3_BUCKET,
        Key=S3_KEY,
        Body=json.dumps(tokens),
        ContentType="application/json"
    )

def refresh_token():
    tokens = load_tokens()
    current_refresh_token = tokens.get("refreshToken")

    if not current_refresh_token:
        raise ValueError("Refresh token bulunamadı.")

    headers = {"Content-Type": "application/json"}
    body = {"refreshToken": current_refresh_token}

    response = requests.post(REFRESH_URL, headers=headers, json=body)

    if response.status_code == 200:
        new_tokens = response.json()
        save_tokens({
            "accessToken": new_tokens["accessToken"],
            "refreshToken": new_tokens["refreshToken"]
        })
        print("Token yenilendi.")
        return new_tokens["accessToken"]
    else:
        raise Exception(f"Token yenileme başarısız: {response.status_code}, {response.text}")

def get_otp_headers():
    tokens = load_tokens()
    print("Kullanılan accessToken:", tokens['accessToken'])
    return {
        "Content-Type": "application/json",
        "User-Agent": "Python/requests",
        "Authorization": f"Bearer {tokens['accessToken']}"
    }

def row_hash(row):
    relevant_data = {k: row[k] for k in row.keys() if k not in ['titleId', 'seasons']}
    row_str = json.dumps(relevant_data, sort_keys=True, ensure_ascii=False)
    return str(farmhash.fingerprint64(row_str))

def main():
    refresh_token()
    client = bigquery.Client()

    query = """
        SELECT titleid, seasons, 
               FARM_FINGERPRINT(TO_JSON_STRING(STRUCT(
                   displayname, type, geoblocking, contenttype_id, imdbscore,
                   publishyear, searchkeywords, tags, artists, genres, directors,
                   smartsigns, season_info, videocontents
               ))) AS content_hash
        FROM `microgain-9f959.Backoffice_metadata.bo_titles_backup_kullanilacak`
    """
    result = client.query(query).result()
    existing_hashes = set((row.titleid, row.seasons, str(row.content_hash)) for row in result)

    title_list_url = "https://api.gain.tv/2da7kf8jf/CALL/Title/getTitleListForBo/default?__culture=tr-tr"
    title_detail_url = "https://api.gain.tv/2da7kf8jf/CALL/Title/getTitleDetailForBo/{}?__culture=tr-tr"

    def get_all_title_ids():
        title_ids = []
        index = 0

        while True:
            params = {
                "query": "*",
                "from": index,
                "pageSize": 50,
                "sorts": [{"createdAt": "desc"}]
            }

            response = requests.post(title_list_url, headers=get_otp_headers(), json=params)

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
        url = title_detail_url.format(title_id)
        response = requests.get(url, headers=get_otp_headers())

        if response.status_code == 200:
            data = response.json().get('title', {})

            def stringify(value):
                if isinstance(value, (list, dict)):
                    return json.dumps(value)
                elif value is None:
                    return ""
                return value

            title_data = {
                "titleId": data.get("titleId", ""),
                "displayName": data.get("displayName", ""),
                "type": data.get("type", ""),
                "geoBlocking": stringify(data.get("geoBlocking")),
                "contentType_id": data.get("contentType", {}).get("id", ""),
                "imdbScore": float(data.get("imdbScore")) if data.get("imdbScore") is not None else None,
                "publishYear": float(data.get("publishYear")) if data.get("publishYear") is not None else None,
                "searchKeywords": stringify(data.get("searchKeywords")),
                "tags": stringify(data.get("tags")),
                "artists": stringify(data.get("artists")),
                "genres": stringify(data.get("genres")),
                "directors": stringify(data.get("directors")),
                "smartSigns": stringify(data.get("smartSigns"))
            }

            season_rows = []
            for season in data.get("seasons", []):
                video_contents = []
                for video_content in season.get("videoContents", []):
                    vc_entry = {
                        'videoContentId': video_content.get("videoContentId", ""),
                        'name.tr-tr': video_content.get("name", {}).get("tr-tr", ""),
                        'shortName.tr-tr': video_content.get("shortName", {}).get("tr-tr", ""),
                        'type': video_content.get("type", ""),
                        'countryInfo': video_content.get("countryInfo", [])
                    }
                    video_contents.append(vc_entry)

                season_row = title_data.copy()
                season_row.update({
                    "seasons": season.get("seasonId", ""),
                    "season_info": season.get("name", {}).get("tr-tr", ""),
                    "videoContents": stringify(video_contents)
                })
                season_rows.append(season_row)

            return season_rows
        else:
            print(f"Detay alınamadı: {title_id}, Status code: {response.status_code}")
            return []

    title_ids = get_all_title_ids()
    all_rows = []
    for tid in title_ids:
        all_rows.extend(get_title_details(tid))

    df = pd.DataFrame(all_rows)
    if df.empty:
        print("Hiç veri alınamadı.")
        return

    df["content_hash"] = df.apply(lambda x: row_hash(x), axis=1)
    current_hashes = set(zip(df["titleId"], df["seasons"], df["content_hash"]))

    new_entries = current_hashes - existing_hashes
    print(f"Yeni bulunan (titleId, seasons) sayısı: {len(new_entries)}")
    print(f"Yeni bulunan titleId sayısı: {len(set(tid for tid, _, _ in new_entries))}")

    delta_df = df[df.apply(lambda x: (x["titleId"], x["seasons"], x["content_hash"]) in new_entries, axis=1)]

    if not delta_df.empty:
        table_id = "microgain-9f959.Backoffice_metadata.bo_titles_backup_kullanilacak"
        job = client.load_table_from_dataframe(
            delta_df.drop(columns=["content_hash"]),
            table_id,
            job_config=bigquery.LoadJobConfig(
                write_disposition="WRITE_APPEND",
                autodetect=True
            )
        )
        job.result()
        print(f"BigQuery'ye {len(delta_df)} yeni satır eklendi.")
    else:
        print("Yeni eklenecek satır bulunamadı.")

if __name__ == "__main__":
    main()
