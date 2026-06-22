-- Google Play estimated sales raw table
-- Target: microgain-9f959.bc_t.googleplay_transactions_raw

CREATE TABLE IF NOT EXISTS `microgain-9f959.bc_t.googleplay_transactions_raw`
(
  order_number STRING OPTIONS(description = 'Google Play order number'),
  order_charged_date DATE OPTIONS(description = 'Order charged or refund date'),
  order_charged_timestamp TIMESTAMP OPTIONS(description = 'Order charged timestamp in UTC'),
  financial_status STRING OPTIONS(description = 'Financial state such as Charged or Refund'),
  device_model STRING,
  product_title STRING,
  package_id STRING,
  product_type STRING,
  sku_id STRING,
  currency_of_sale STRING,
  item_price NUMERIC,
  taxes_collected NUMERIC,
  charged_amount NUMERIC,
  city_of_buyer STRING,
  state_of_buyer STRING,
  postal_code_of_buyer STRING,
  country_of_buyer STRING,
  base_plan_or_purchase_option_id STRING,
  offer_id STRING,
  group_id STRING,
  first_usd_1m_eligible STRING,
  promotion_id STRING,
  coupon_value NUMERIC,
  discount_rate NUMERIC,
  featured_product_id STRING,
  price_experiment_id STRING,
  sales_channel STRING,
  source_zip STRING OPTIONS(description = 'Google Cloud Storage source ZIP object'),
  source_csv STRING OPTIONS(description = 'CSV filename inside the source ZIP'),
  report_target_date DATE OPTIONS(description = 'Date selected by the export job'),
  export_loaded_at_utc TIMESTAMP OPTIONS(description = 'UTC timestamp when the export was prepared')
)
PARTITION BY order_charged_date
CLUSTER BY financial_status, currency_of_sale, country_of_buyer, sku_id
OPTIONS (
  description = 'Raw daily Google Play estimated sales, charges and refunds'
);
