-- Apple App Store subscriber report raw table
-- Target: microgain-9f959.bc_t.apple_transactions_raw

CREATE TABLE IF NOT EXISTS `microgain-9f959.bc_t.apple_transactions_raw`
(
  source_report_date DATE OPTIONS(description = 'App Store Connect daily report date requested from the API'),
  export_loaded_at_utc TIMESTAMP OPTIONS(description = 'UTC timestamp when the export was prepared'),
  event_date DATE OPTIONS(description = 'Date of the subscription event reported by Apple'),
  app_name STRING,
  app_apple_id STRING,
  subscription_name STRING,
  subscription_apple_id STRING,
  subscription_group_id STRING,
  standard_subscription_duration STRING,
  subscription_offer_name STRING,
  promotional_offer_id STRING,
  subscription_offer_type STRING,
  subscription_offer_duration STRING,
  marketing_opt_in_duration STRING,
  customer_price NUMERIC,
  customer_currency STRING,
  developer_proceeds NUMERIC,
  proceeds_currency STRING,
  preserved_pricing STRING,
  proceeds_reason STRING,
  client STRING,
  device STRING,
  country STRING,
  subscriber_id STRING OPTIONS(description = 'Apple-generated subscriber identifier'),
  subscriber_id_reset STRING,
  refund STRING,
  purchase_date DATE,
  units NUMERIC
)
PARTITION BY source_report_date
CLUSTER BY subscriber_id, country, customer_currency, refund
OPTIONS (
  description = 'Raw daily Apple App Store detailed subscriber reports'
);
