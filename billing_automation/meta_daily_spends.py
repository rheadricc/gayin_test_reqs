import requests
import json

ACCESS_TOKEN = "EAAJrW2U9pZA8BRRHLIL6ZCbSePkXq2vQeKTlZAR3L3DZAssqI7BjGg9OKgo549P4FSV8UWZAqEaAzns7BoyMOWA6yH77iiPHxOYIMwxg7q5ZCtVZCOg8UAiAIza5H6P40aFvU1WkZAFqIPzDTGDn18497G71ZCFG8fIYCii1saEyhZCnIkeuMpRI4EdAKe4IGwH8TX6QZDZD".strip()
AD_ACCOUNT_ID = "act_1326208638940273"

url = "https://graph.facebook.com/v19.0/me/adaccounts"
params = {
    "access_token": ACCESS_TOKEN,
    "fields": "id,name,account_status,currency"
}

r = requests.get(url, params=params, timeout=30)
print(r.status_code)
print(r.text)