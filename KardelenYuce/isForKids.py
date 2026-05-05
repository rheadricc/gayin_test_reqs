import requests
import time

BASE = "https://api.gain.tv/2da7kf8jf"
URL = f"{BASE}/CALL/Title/getTitleListForBo/default"

HEADERS = {
    "Content-Type": "application/json",
    "Authorization": "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJwcm9qZWN0SWQiOiIyZGE3a2Y4amYiLCJpZGVudGl0eSI6ImJhY2tvZmZpY2VfdXNlciIsImFub255bW91cyI6ZmFsc2UsInVzZXJJZCI6IlJpTmtLYnRTTzQ3WlB2UTMxSHhWQ3hoeCIsImNsYWltcyI6eyJuYW1lIjoiS2FyZGVsZW4gWcO8Y2UiLCJlbWFpbCI6ImthcmRlbGVueXVjZUBnYWluLmNvbS50ciIsInN0YXR1cyI6ImFjdGl2ZSIsInJvbGUiOiJhZG1pbiJ9LCJzZXNzaW9uSWQiOiJjNzcwNmFjNjU1MmE0NzM1YjBiZWVmNGRhNmU2OTk1MyIsImlhdCI6MTc2ODMxMTY2MiwiZXhwIjoxNzcwOTAzNjYyfQ.NjsAP8uA8lxlgssZCLCyGISGqVP6Aj64CTRhp3y1-WzOfl-SoSwj2iDYGz402JrxvXcSCZhEk5CsnWr2eKbIRyYCfurOw74CYicMraY4V1tfkRNbH1wVc7vefXSuhFlAOKL-NEaxfYu1SNnfkvN7mZl2qA5MGsqn0RBJ3ux9Eg2wSICDbzQ6cmbz-NVehbEZ05Dz6pwM8PT7hcYMr04SY9rBQ6OJZ2Ppuy4pz-QVuv2HpBs3pzVZyCuz71g3mzAjcldLnbon-wP2c-rTsxn1d-Mr650IlIhRqGTaHcDa9WdUTPMvpVfZoP2ArKTZxY29jwEFovp27dtySgxHWACd0A"
}

CULTURE = "tr-tr"
PAGE_SIZE = 10
TOTAL_PAGES = 77
SLEEP = 0.1


def genre_names(item: dict) -> str:
    genres = item.get("genres") or []
    names = []
    for g in genres:
        n = (g.get("name") or "").strip()
        if n:
            names.append(n)
    return ", ".join(names) if names else "(genre yok)"


def fetch_batch(offset: int) -> dict:
    params = {"__culture": CULTURE}
    body = {
        "query": "*",
        "from": offset,
        "pageSize": PAGE_SIZE,
        "sorts": [{"createdAt": "desc"}]
    }
    r = requests.post(URL, headers=HEADERS, params=params, json=body, timeout=30)
    r.raise_for_status()
    return r.json()


def main():
    total_seen = 0
    kids_count = 0

    offset = 0
    for page in range(1, TOTAL_PAGES + 1):
        resp = fetch_batch(offset)
        items = resp.get("result", [])

        if not items:
            print(f"[STOP] page={page} offset={offset} boş döndü | meta={resp.get('meta')}")
            break

        print(f"\n--- PAGE {page}/{TOTAL_PAGES} (from={offset}) ---")

        for item in items:
            total_seen += 1
            if item.get("isForKids") is True:
                kids_count += 1
                print(
                    f"✅ {item.get('displayName')} | "
                    f"id={item.get('titleId')} | "
                    f"type={item.get('type')} | "
                    f"genres={genre_names(item)}"
                )

        offset += PAGE_SIZE
        time.sleep(SLEEP)

    print("\n====================")
    print(f"Toplam görülen title : {total_seen}")
    print(f"isForKids = true     : {kids_count}")


if __name__ == "__main__":
    main()
