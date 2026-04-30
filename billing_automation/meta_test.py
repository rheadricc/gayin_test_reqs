import requests

ACCESS_TOKEN = "EAAJrW2U9pZA8BRRHLIL6ZCbSePkXq2vQeKTlZAR3L3DZAssqI7BjGg9OKgo549P4FSV8UWZAqEaAzns7BoyMOWA6yH77iiPHxOYIMwxg7q5ZCtVZCOg8UAiAIza5H6P40aFvU1WkZAFqIPzDTGDn18497G71ZCFG8fIYCii1saEyhZCnIkeuMpRI4EdAKe4IGwH8TX6QZDZD".strip()

for endpoint in ["me/permissions", "me/adaccounts"]:
    url = f"https://graph.facebook.com/v19.0/{endpoint}"
    params = {
        "access_token": ACCESS_TOKEN,
        "fields": "id,name,account_status,currency"
    } if endpoint == "me/adaccounts" else {"access_token": ACCESS_TOKEN}

    r = requests.get(url, params=params, timeout=30)
    print("\nENDPOINT:", endpoint)
    print("STATUS:", r.status_code)
    print("RESPONSE:", r.text)