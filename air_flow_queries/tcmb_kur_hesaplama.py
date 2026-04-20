import requests
import xml.etree.ElementTree as ET
from datetime import datetime


def to_float(value):
    if value is None:
        return None
    value = value.strip()
    if value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def to_int(value):
    if value is None:
        return None
    value = value.strip()
    if value == "":
        return None
    try:
        return int(value)
    except ValueError:
        return None


def parse_tcmb_date(date_str):
    if not date_str:
        return None
    try:
        return datetime.strptime(date_str, "%m/%d/%Y").date().isoformat()
    except ValueError:
        return None


def get_tcmb_rates():
    url = "https://www.tcmb.gov.tr/kurlar/today.xml"

    response = requests.get(url, timeout=30)
    response.raise_for_status()

    root = ET.fromstring(response.content)

    result = {
        "rate_date": parse_tcmb_date(root.attrib.get("Date")),
        "date_tr": root.attrib.get("Tarih"),
        "bulletin_no": root.attrib.get("Bulten_No"),
        "source_url": url,
        "currencies": []
    }

    for currency in root.findall("Currency"):
        item = {
            "rate_date": parse_tcmb_date(root.attrib.get("Date")),
            "bulletin_no": root.attrib.get("Bulten_No"),
            "source_url": url,
            "cross_order": to_int(currency.attrib.get("CrossOrder")),
            "kod": currency.attrib.get("Kod"),
            "currency_code": currency.attrib.get("CurrencyCode"),
            "unit": to_int(currency.findtext("Unit")),
            "name_tr": currency.findtext("Isim"),
            "name_en": currency.findtext("CurrencyName"),
            "forex_buying": to_float(currency.findtext("ForexBuying")),
            "forex_selling": to_float(currency.findtext("ForexSelling")),
            "banknote_buying": to_float(currency.findtext("BanknoteBuying")),
            "banknote_selling": to_float(currency.findtext("BanknoteSelling")),
            "cross_rate_usd": to_float(currency.findtext("CrossRateUSD")),
            "cross_rate_other": to_float(currency.findtext("CrossRateOther")),
        }
        result["currencies"].append(item)

    return result


if __name__ == "__main__":
    data = get_tcmb_rates()

    print("Tarih:", data["rate_date"])
    print("Bülten No:", data["bulletin_no"])
    print("-" * 80)

    for currency in data["currencies"]:
        print(
            f"{currency['currency_code']} | "
            f"Birim: {currency['unit']} | "
            f"Alış: {currency['forex_buying']} | "
            f"Satış: {currency['forex_selling']}"
        )