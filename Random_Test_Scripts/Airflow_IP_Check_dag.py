from airflow.decorators import dag, task
from datetime import datetime
import requests
@dag(
    start_date=datetime(2026,1,1),
    schedule=None,
    catchup=False
)
def check_outbound_ip():
    @task
    def get_ip():
        ip = requests.get("https://api.ipify.org").text
        print(f"Outbound IP: {ip}")
    get_ip()

check_outbound_ip()