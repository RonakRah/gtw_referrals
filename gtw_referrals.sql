WITH tac_referral AS (
SELECT
		LOWER(Departure_Station) AS Departure_Station,
		LOWER(Arrival_Station) AS Arrival_Station,
		CAST(Departure_Stop_Id AS STRING) AS Departure_Stop_Id,
		CAST(arrival_Stop_Id AS STRING) AS arrival_Stop_Id,
		SUM(Referrals) AS Referrals,
		MAX(__Priced_Referrals) AS Priced_Referrals_percentage,
FROM  omio-dsi.sandbox.tac_referrals
WHERE Departure_stop_id IS NOT NULL AND arrival_Stop_Id IS NOT NULL
GROUP BY ALL
)
,tac_referral_with_priced_list_tag AS (

   SELECT tac.*,
          CASE WHEN EXISTS(SELECT 1
                        FROM `centered-radius-89610`.dwh_raw.gtw_priced_routes AS p
                        WHERE TRUE
                              AND p.from_id  = tac.Departure_Stop_Id 
                              AND p.to_id = tac.arrival_Stop_Id  )
                THEN "inside priced list tool"
                ELSE "outside of priced list tool"
          END AS cachefiller_flag

          
   FROM tac_referral AS tac
) 
-------------| bookings
,bookings AS (
	SELECT CAST(departure_place_id AS STRING) AS departure_place_id,
	       CAST(arrival_place_id AS STRING) AS arrival_place_id ,
				 COUNT(DISTINCT booking_uuid) AS number_of_booking
	FROM 	centered-radius-89610.dwh_aggregate.enriched_bookings
	WHERE transaction_ymd >= '2026-03-01'
	GROUP BY ALL
)
-------------| scheduels
,master_reply AS (
  SELECT
      event_uuid,
      SAFE_CAST(event_date AS DATE) AS event_date,
      SAFE_CAST(departure_date AS DATE) AS departure_date,
      CAST(departure_pos AS STRING) AS departure_pos,
      CAST(arrival_pos AS STRING) AS arrival_pos,
      request_id,
      CASE
         WHEN integration IN ('uk_omio_nationalrail') THEN COALESCE(NULLIF(provider_id,'unknown'),'assertis')
         ELSE provider_id
      END AS provider_id,
      integration,
      'valid sche' AS sche_type,
      'no error'  AS error_message,
  FROM `centered-radius-89610.dwh_raw.b2b_discovery_schedule_reply_v1`
  WHERE TRUE
    AND integration = 'uk_omio_nationalrail'
    AND partner_id = 'google'
    AND is_sold_out = FALSE
    AND availability = 'AVAILABLE'
    AND departure_pos IS NOT NULL
    AND arrival_pos IS NOT NULL
    AND event_date >= TIMESTAMP('2026-03-01')
  UNION ALL

  SELECT
      event_uuid,
      SAFE_CAST(event_date AS DATE) AS event_date,
      SAFE_CAST(departure_date AS DATE) AS departure_date,
      CAST(departure_pos AS STRING),
      CAST(arrival_pos AS STRING),
      request_id,
      CASE
         WHEN integration IN ('uk_omio_nationalrail') THEN COALESCE(NULLIF(provider_id,'unknown'),'assertis')
         ELSE provider_id
      END AS provider_id,
      integration,
      error_type ,
      error_message
  FROM `centered-radius-89610.dwh_raw.b2b_discovery_schedule_reply_errors_v1`
   WHERE TRUE
    AND integration  = 'uk_omio_nationalrail'
    AND partner_id = 'google'
    AND departure_pos IS NOT NULL
    AND arrival_pos IS NOT NULL
    AND event_date >= TIMESTAMP('2026-03-01')
)
------------- | aggregation
,aggregation_on_schedules AS (
SELECT
          
          departure_pos,
          arrival_pos,
          COUNT( DISTINCT request_id) total_num_of_requests,
          COUNT( DISTINCT CASE WHEN DATE_DIFF(departure_date, event_date, DAY) BETWEEN 0 AND 15 THEN  request_id END ) AS num_req_within_15_days,
          COUNT( DISTINCT CASE WHEN DATE_DIFF(departure_date, event_date, DAY) BETWEEN 16 AND 30 THEN  request_id END ) AS num_re_between_16_to_30_days,
          COUNT( DISTINCT event_uuid) AS num_of_sche_per_road,
          COUNT( DISTINCT CASE WHEN sche_type = 'valid sche' THEN event_uuid END) AS num_valid_options,
          COUNT( DISTINCT CASE WHEN sche_type != 'valid sche' AND NOT (sche_type= 'TRIP_OPTIONS_ERROR_TYPE_UNSPECIFIED' AND error_message LIKE 'search disabled%') THEN request_id END ) AS num_of_requests_with_error,


          COUNT( DISTINCT CASE WHEN sche_type != 'valid sche' AND sche_type='SEGMENT_KEY_NOT_FOUND' THEN request_id END) AS num_of_SEGMENT_KEY_NOT_FOUND,
          COUNT( DISTINCT CASE WHEN sche_type != 'valid sche' AND sche_type='SEGMENT_KEY_NOT_FOUND' AND error_message LIKE 'search disabled%' THEN request_id END) AS num_of_segment_key_error_with_search_disabled,


          COUNT( DISTINCT CASE WHEN sche_type != 'valid sche' AND sche_type= 'TRIP_OPTIONS_ERROR_TYPE_UNSPECIFIED' AND error_message NOT LIKE 'search disabled%' THEN request_id END) AS num_of_TRIP_OPTIONS_ERROR_TYPE_UNSPECIFIED,
          COUNT( DISTINCT CASE WHEN sche_type != 'valid sche' AND sche_type= 'TRIP_OPTIONS_ERROR_TYPE_UNSPECIFIED' AND error_message LIKE "distance between%" THEN request_id END) AS num_of_trip_option_error_with_low_distance,


          COUNT( DISTINCT CASE WHEN sche_type != 'valid sche' AND sche_type= 'TRIP_OPTION_CACHE_STALE' THEN request_id END) AS num_of_TRIP_OPTION_CACHE_STALE,
          COUNT( DISTINCT CASE WHEN sche_type != 'valid sche' AND sche_type= 'TICKETING_PROHIBITED' THEN request_id END) AS num_of_TICKETING_PROHIBITED
FROM master_reply
GROUP BY ALL

)
----------- | join aggregation of scheduels with tac referral

SELECT tac_ref.Departure_Station,
       tac_ref.arrival_station,
       tac_ref.Departure_Stop_Id,
		   tac_ref.arrival_Stop_Id,
       tac_ref.cachefiller_flag,
       tac_ref.referrals,
       tac_ref.Priced_Referrals_percentage,
       COALESCE(omio.total_num_of_requests,0) AS total_num_of_requests,
       COALESCE(omio.num_of_sche_per_road,0) AS num_of_sche_per_road,
       COALESCE(omio.num_valid_options,0) AS num_valid_options,
       COALESCE(omio.num_of_requests_with_error,0) AS num_of_requests_with_error,
       COALESCE(omio.num_of_SEGMENT_KEY_NOT_FOUND,0) AS num_of_SEGMENT_KEY_NOT_FOUND,
       COALESCE(omio.num_of_segment_key_error_with_search_disabled,0) AS num_of_segment_key_error_with_search_disabled,
       COALESCE(omio.num_of_TRIP_OPTIONS_ERROR_TYPE_UNSPECIFIED,0) AS num_of_TRIP_OPTIONS_ERROR_TYPE_UNSPECIFIED,
       COALESCE(omio.num_of_trip_option_error_with_low_distance,0) AS num_of_trip_option_error_with_low_distance,
       COALESCE(omio.num_of_TRIP_OPTION_CACHE_STALE,0) AS num_of_TRIP_OPTION_CACHE_STALE,
       COALESCE(omio.num_of_TICKETING_PROHIBITED,0) AS num_of_TICKETING_PROHIBITED,
			 COALESCE(booking.number_of_booking,0) AS number_of_booking,

      ------ upriced link flag
      CASE
          WHEN tac_ref.Priced_Referrals_percentage = 1 THEN 'all the time priced'
          WHEN tac_ref.Priced_Referrals_percentage = 0 THEN 'all the time unpriced'
          ELSE 'mixed'
      END AS priced_unpriced_flag,
      
      ------- flag if there was and call for the road
      CASE
          WHEN COALESCE(omio.total_num_of_requests,0) = 0 THEN 'no request'
          WHEN COALESCE(omio.total_num_of_requests,0) > 0  AND COALESCE(omio.total_num_of_requests,0) < 1000 THEN 'low request'
          ELSE 'high request'
      END AS request_demand_flag,

      ----- flag for error status
      CASE
          WHEN COALESCE(omio.total_num_of_requests,0) > 0 AND COALESCE(omio.num_valid_options) = 0 THEN '100%  errored'
          WHEN COALESCE(omio.total_num_of_requests,0) > 0 AND ( (COALESCE(omio.num_of_sche_per_road) - COALESCE(omio.num_valid_options)) / COALESCE(omio.num_of_sche_per_road )) >= 0.8 THEN '80% or more errored'
          WHEN COALESCE(omio.total_num_of_requests,0) > 0 AND ( (COALESCE(omio.num_of_sche_per_road) - COALESCE(omio.num_valid_options)) / COALESCE(omio.num_of_sche_per_road )) < 0.8 THEN 'less than 80% errored'
      END AS sche_error_flag,




      CASE
          WHEN COALESCE(omio.total_num_of_requests,0) > 0 AND (( COALESCE(omio.num_of_requests_with_error,0)) / COALESCE(omio.total_num_of_requests,0)) >= 0.8 THEN '80% or more of the request faced error'
          WHEN COALESCE(omio.total_num_of_requests,0) > 0 AND (( COALESCE(omio.num_of_requests_with_error,0)) / COALESCE(omio.total_num_of_requests,0)) < 0.8 THEN   'less than 80% of requests faced error'
          
      END req_error_flag,
       
      CONCAT(tac_ref.Departure_Station,' to ',tac_ref.arrival_station,' train') AS search_query
FROM tac_referral_with_priced_list_tag AS tac_ref 
LEFT JOIN aggregation_on_schedules AS omio ON omio.departure_pos = tac_ref.departure_Stop_Id  AND omio.arrival_pos = tac_ref.arrival_Stop_Id 
LEFT JOIN bookings AS booking ON booking.departure_place_id = tac_ref.departure_Stop_Id  AND booking.arrival_place_id = tac_ref.arrival_Stop_Id 
WHERE tac_ref.departure_Stop_Id IS NOT NULL AND tac_ref.arrival_Stop_Id IS NOT NULL 
