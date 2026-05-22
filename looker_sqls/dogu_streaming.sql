-- SCHEDULED QUERY
-- Name: dogu_streaming
-- Schedule: Every 30 minutes

CREATE OR REPLACE TABLE `microgain-9f959.looker_report.content_report_streaming_V2`
PARTITION BY event_date
CLUSTER BY title,playlistid,contentCategory  
as
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
contentsarray as (
select 
  displayname,
  seasonname,
  SPLIT(CAST(REPLACE(REPLACE(REPLACE(replace(videocontentids,'[',''),']',''),"'",""),' ','') AS STRING), ',') arraycolumn
from `microgain-9f959.test_dataset.video_df_season` 
),
contents as(
select seasonname,displayname,concat(displayname,' ',seasonname) playlistname, video_id from contentsarray, unnest(arraycolumn) video_id
--where displayname like 'Doğu%'
),
VideosInfo as (
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
SeasonLength as (
  select 
    sum(video_duration_second) Season_Length,
    playlistid
  from VideosInfo
    group by 2
),
 BaseData1 as (
  SELECT
      event_date,
      event_timestamp,
      event_name,
      event_params,
      event_previous_timestamp,
      event_value_in_usd,
      event_bundle_sequence_id,
      user_pseudo_id,
      privacy_info,
      user_properties,
      user_first_touch_timestamp,
      user_ltv,
      device,
      geo,
      app_info,
      traffic_source,
      stream_id,
      platform,
      CASE
        WHEN user_id IS NOT NULL THEN user_id
        ELSE (SELECT value.string_value FROM UNNEST(user_properties) WHERE KEY = "user_gid") 
      END user_id,
      CASE 
        WHEN LOWER(platform) = 'web' and stream_id != '2591735133' THEN 'WEB'
        WHEN ((device.category != 'smart tv' and lower(platform) != 'web') and (stream_id != '2591735133')) THEN 'MOBILE'
        ELSE 'TV' 
      END AS meta_platform,
      --_TABLE_SUFFIX AS table_id,
      20250128 AS table_id,
      device.category AS device_category,
      platform AS device_platform,
      geo.continent AS g_continent,
      geo.country AS g_country,
      geo.city AS g_city,
      '' as firebase_screen,  
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = "ga_session_id") as ga_session_id,  
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = "ga_session_number") as ga_session_number
    FROM
      `microgain-9f959.analytics_236816681.events_intraday_*` --TABLESAMPLE SYSTEM (1 PERCENT)
    WHERE --REGEXP_EXTRACT(_TABLE_SUFFIX, '[0-9]+') BETWEEN FORMAT_DATE("%Y%m%d", CURRENT_DATE()-6) AND FORMAT_DATE("%Y%m%d", CURRENT_DATE("Europe/Istanbul"))
      --AND 
      event_name IN ('video_actions','video_action')
      and _TABLE_SUFFIX = FORMAT_DATE("%Y%m%d", CURRENT_DATE("Europe/Istanbul"))
),
BaseData2 as (
  SELECT
      event_date,
      event_timestamp,
      event_name,
      event_params,
      event_previous_timestamp,
      event_value_in_usd,
      event_bundle_sequence_id,
      user_pseudo_id,
      privacy_info,
      user_properties,
      user_first_touch_timestamp,
      user_ltv,
      device,
      geo,
      app_info,
      traffic_source,
      stream_id,
      platform,
      CASE
        WHEN user_id IS NOT NULL THEN user_id
        ELSE (SELECT value.string_value FROM UNNEST(user_properties) WHERE KEY = "user_gid") 
      END user_id,
      CASE 
        WHEN LOWER(platform) = 'web' and stream_id != '2591735133' THEN 'WEB'
        WHEN ((device.category != 'smart tv' and lower(platform) != 'web') and (stream_id != '2591735133')) THEN 'MOBILE'
        ELSE 'TV' 
      END AS meta_platform,
      --_TABLE_SUFFIX AS table_id,
      20250128 AS table_id,
      CASE
      WHEN (SELECT value.string_value FROM UNNEST(event_params) WHERE KEY = 'g_device_type') = 'Smart TV' THEN 'smart tv'
      else device.category
      END AS device_category,
      platform AS device_platform,
      geo.continent AS g_continent,
      geo.country AS g_country,
      geo.city AS g_city,
      '' as firebase_screen,  
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = "ga_session_id") as ga_session_id,  
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = "ga_session_number") as ga_session_number
    FROM
      `microgain-9f959.analytics_271525484.events_intraday_*` --TABLESAMPLE SYSTEM (1 PERCENT)
    WHERE --REGEXP_EXTRACT(_TABLE_SUFFIX, '[0-9]+') BETWEEN FORMAT_DATE("%Y%m%d", CURRENT_DATE()-6) AND FORMAT_DATE("%Y%m%d", CURRENT_DATE("Europe/Istanbul"))
      --AND 
      event_name IN ('video_actions','video_action')
      and _TABLE_SUFFIX = FORMAT_DATE("%Y%m%d", CURRENT_DATE("Europe/Istanbul"))
),
BaseData as (
  select * from BaseData1
    union all
  select * from BaseData2
),
BaseDataSecond as (
  select  
    user_id,
    event_timestamp,
    (SELECT value.string_value  FROM UNNEST(event_params) WHERE KEY IN ("videoId", "video_id", "mediaId")) AS video_id,
    (SELECT value.string_value  FROM UNNEST(event_params) WHERE KEY IN ("video_name")) AS video_name_ga,
    (SELECT value.string_value  FROM UNNEST(event_params) WHERE KEY IN ("title_name")) AS title_name_ga,
    'playing' AS video_action,
    (SELECT value.int_value  FROM UNNEST(event_params) WHERE KEY IN ("engagement_time_msec")) AS value,
    device_category,
    device_platform,
    g_continent,
    g_country,
    g_city,
    firebase_screen,
    ga_session_id,
    ga_session_number,
    user_pseudo_id,
    meta_platform
  from BaseData
),
BaseDataThird as
(
  SELECT
      user_id,
      event_timestamp,
      video_id,
      video_action,
      device_category,
      device_platform,
      g_continent,
      g_country,
      g_city,
      firebase_screen,
      ga_session_id,
      ga_session_number,
      video_name_ga,
      title_name_ga,
      user_pseudo_id,
      SUM(value) AS value
  FROM BaseDataSecond
    GROUP BY
      user_id,
      event_timestamp,
      video_id,
      video_action,
      device_category,
      device_platform,
      g_continent,
      g_country,
      g_city,
      firebase_screen,
      ga_session_id,
      video_name_ga,
      title_name_ga,
      user_pseudo_id,
      ga_session_number
),
BaseDataLast as (
  SELECT
    *,
    LAG(event_timestamp) OVER(PARTITION BY user_id, video_id ORDER BY event_timestamp) AS last_event_timestamp
  FROM BaseDataThird
),
ReportData as (select 
    user_id,
    video_id,
    FORMAT_DATE("%Y%m%d",DATE(DATETIME(TIMESTAMP_MICROS(event_timestamp), "Europe/Istanbul"))) AS event_date,
    MIN(event_timestamp) AS event_timestamp, 
    datetime(timestamp_micros(event_timestamp),"Europe/Istanbul") Datetime_Ist,
    device_category,
    device_platform,
    g_continent,
    g_country,
    g_city,
    firebase_screen,
    ga_session_id,
    ga_session_number,
      video_name_ga,
      title_name_ga,
      user_pseudo_id,
    SUM(value) AS watch_millis,
    SUM(value) / 1000 watch_time_second, 
  from BaseDataLast
    GROUP BY
      user_id, 
      datetime(timestamp_micros(event_timestamp),"Europe/Istanbul"),
      video_id,
      event_date,
      device_category,
      device_platform,
      g_continent,
      g_country,
      g_city,
      firebase_screen,
      ga_session_id,
      video_name_ga,
      title_name_ga,
      ga_session_number,
      user_pseudo_id
)
  SELECT
    ad.user_id,
    PARSE_DATE('%Y%m%d',ad.event_date) event_date,
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
    --ad.video_name_ga,
    --ad.title_name_ga,
    IFNULL(vi.unique_playlistId,cn.titleid) AS unique_playlistId,
    IFNULL(vi.playlistId,cn.playlistid) AS playlistId,
    IFNULL(vi.title,cn.video_name) AS title,
    vi.contentCategory,
    vi.contentSubCategory,
    IFNULL(vi.episodeNumber,CAST(cn.EpisodeNumber AS STRING)) AS episodeNumber,
    IFNULL(vi.video_duration_second,cn.videoduration) AS video_duration_second, 
    vi.pubdate,
    vi.modifiedAt,
    vi.is_local_content,
    sl.Season_Length,
    user_pseudo_id
  FROM ReportData ad
      LEFT JOIN VideosInfo vi ON ad.video_id = vi.videoid
      LEFT JOIN SeasonLength sl on vi.playlistId = sl.playlistId
      LEFT JOIN contents c on ad.video_id = c.video_id
      LEFT JOIN contentsnew cn on ad.video_id = cn.video_id
  where ad.video_id is not null
    UNION ALL
  select *  from `microgain-9f959.looker_report.content_report_V2` 
  where video_id is not null
  union all
  select *,null user_pseudo_id from `looker_report.content_report`
  where video_id is not null
