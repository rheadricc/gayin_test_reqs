--- abonelik başlatıp izleme yapmayan kullanıcıların ilk izleme tarihleri ve izledikleri içerikler ---

with
contentsnew as (
  SELECT 
    season_info,
    titleid,
    REPLACE(displayname,'"', '') AS displayname,
    TRIM(CONCAT(REPLACE(displayname,'"', '')," ",IF(season_info = 'VİDEO TANIMI','',season_info))) playlistid,
    JSON_VALUE(video, '$.videoContentId') video_id,
    JSON_VALUE(video, '$."name.tr-tr"') video_name,
    JSON_VALUE(video, '$.type') video_type,
    CAST(IF(IFNULL(JSON_VALUE(country, '$.media.duration'),'0') = '','0',JSON_VALUE(country, '$.media.duration')) AS INT64)/1000 AS VideoDuration,
    JSON_VALUE(video, '$.type') AS contentCategory,
    '' AS contentSubCategory,
    IFNULL(CAST(REGEXP_EXTRACT(JSON_VALUE(video, '$."shortName.tr-tr"'), r'B(\d+)') AS INT64),0) AS EpisodeNumber,
    PARSE_DATE('%Y',CAST(publishyear AS STRING)) pubdate,
    '' AS modifiedAt,
    '' AS is_local_content
  FROM `microgain-9f959.Backoffice_metadata.bo_titles`, 
    UNNEST(JSON_QUERY_ARRAY(videocontents, '$')) AS video,
    UNNEST(JSON_QUERY_ARRAY(video, '$.countryInfo')) AS country
    order by 3
),
first_event AS (
  SELECT
    user_id,
    MIN(datetime_ist) min_event_time
  FROM `looker_report.content_report_streaming_V2`
    WHERE event_date >= '2024-01-01'
    GROUP BY 1
),
first_watched AS (
  SELECT
    DISTINCT
    a.user_id,
    a.datetime_ist,
    c.playlistid,
    c.video_name
  FROM `looker_report.content_report_streaming_V2` a
    JOIN first_event f ON a.user_id = f.user_id and a.datetime_ist = f.min_event_time
    JOIN contentsnew c ON a.video_id = c.video_id
    WHERE event_date >= '2024-01-01'
),
last_event AS (
  SELECT
    user_id,
    MAX(datetime_ist) max_event_time
  FROM `looker_report.content_report_streaming_V2`
    WHERE event_date >= '2024-01-01'
    GROUP BY 1
),
last_watched AS (
  SELECT
    a.user_id,
    a.datetime_ist,
    a.video_id,
    a.title,
    c.playlistid,
    c.video_name,
    
    -- 🆕 Metadata eşleşme durumu
    CASE 
      WHEN c.video_id IS NULL THEN 'missing_metadata'  -- BO eşleşmiyor
      ELSE 'valid'
    END AS metadata_status

  FROM `looker_report.content_report_streaming_V2` a
  JOIN (
    SELECT user_id, MAX(datetime_ist) AS max_event_time
    FROM `looker_report.content_report_streaming_V2`
    WHERE event_date >= '2024-01-01'
    GROUP BY user_id
  ) l ON a.user_id = l.user_id 
     AND TIMESTAMP_TRUNC(a.datetime_ist, SECOND) = TIMESTAMP_TRUNC(l.max_event_time, SECOND)
  LEFT JOIN contentsnew c ON a.video_id = c.video_id
  WHERE a.event_date >= '2024-01-01'
)


-- first watch after paid ---
select  
  pwd.user_id,
  pwd.first_paid_month,
  fw.playlistid,
  fw.video_name,
  fw.datetime_ist,
  date_diff(date_trunc(date(datetime_ist), month),pwd.first_paid_month, month) as watch_after_first_paid,
  pwd.paid_months_count
from `test_dataset.payment_watch_dropoff_scd` pwd
left join first_watched fw using (user_id)
where first_paid_month <= date_trunc(date(datetime_ist), month )