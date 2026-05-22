-- SCHEDULED QUERY
-- Name: content_report
-- Schedule: Every 10 minutes

CREATE OR REPLACE TABLE `microgain-9f959.looker_report.content_report` 
PARTITION BY event_date
CLUSTER BY title,playlistid,contentCategory
as
with
videos_info as (
   SELECT 
    videoId,
    unique_playlistId,
    playlistId,
    title,
    contentCategory,
    contentSubCategory,
    episodeNumber,
    duration_in_second video_duration_second,
    datetime(timestamp_millis(pubdate),"Europe/Istanbul") pubdate,
    datetime(timestamp_millis(modifiedAt),"Europe/Istanbul") modifiedAt,
    is_local_content
  FROM `microgain-9f959.datamarts.jw_video_master_category`
),
seasonlength as (
  select 
    sum(video_duration_second) Season_Length,
    playlistid
  from videos_info
    group by 2
),
all_data as (SELECT 
    user_id,
    cast(event_date as date) event_date,
    datetime(timestamp_micros(event_timestamp),"Europe/Istanbul") Datetime_Ist,
    video_id,
    ga_session_id,
    millis watch_millis,
    millis / 1000 watch_time_second,
    device_category,
    device_platform,
    g_continent,
    g_country,
    g_city
  FROM `microgain-9f959.datamarts.web_user_video`
    WHERE CAST(event_date AS DATE) >= "2023-06-01"
UNION ALL
  SELECT 
    user_id,
    cast(event_date as date) event_date,
    datetime(timestamp_micros(event_timestamp),"Europe/Istanbul") Datetime_Ist,
    video_id,
    ga_session_id,
    millis watch_millis,
    millis / 1000 watch_time_second,
    device_category,
    device_platform,
    g_continent,
    g_country,
    g_city
  FROM `microgain-9f959.datamarts.tv_user_video`
    WHERE CAST(event_date AS DATE)  >= "2023-06-01"
UNION ALL  
  SELECT 
    user_id,
    PARSE_DATE('%Y%m%d',  event_date) event_date, 
    datetime(timestamp_micros(event_timestamp),"Europe/Istanbul") Datetime_Ist,
    video_id,
    ga_session_id,
    millis watch_millis,
    millis / 1000 watch_time_second,
    device_category,
    device_platform,
    g_continent,
    g_country,
    g_city
  FROM `microgain-9f959.datamarts.user_video_*`
  	WHERE _TABLE_SUFFIX >= '20230601'
)
  SELECT 
    ad.user_id,
    ad.event_date,
    ad.Datetime_Ist,
    ad.video_id,
    ad.ga_session_id,
    ad.watch_millis,
    ad.watch_time_second,
    ad.device_category,
    ad.device_platform,
    ad.g_continent,
    ad.g_country,
    ad.g_city,
    vi.unique_playlistId,
    CASE
      WHEN ad.video_id = 'rmE13XCT' THEN 'Ufkun Ötesinde'
      ELSE vi.playlistId
    END playlistId,
    CASE
      WHEN ad.video_id = 'rmE13XCT' THEN 'Ufkun Ötesinde'
      ELSE vi.title
    END title,
    vi.contentCategory,
    vi.contentSubCategory,
    vi.episodeNumber,
    vi.video_duration_second, 
    vi.pubdate,
    vi.modifiedAt,
    vi.is_local_content,
    sl.Season_Length
  FROM
    all_data ad
      LEFT JOIN videos_info vi ON ad.video_id = vi.videoid
      LEFT JOIN seasonlength sl on vi.playlistId = sl.playlistId
