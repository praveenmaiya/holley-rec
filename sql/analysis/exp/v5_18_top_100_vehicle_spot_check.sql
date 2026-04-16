-- ====================================================================================
-- V5.18 Top 100 Vehicle Spot Check Output
-- ------------------------------------------------------------------------------------
-- Purpose:
--   Produce spot-check recommendations for the client-provided Top 100 vehicle list,
--   preserving EXACT vehicle order (rank 1..100) for side-by-side Holley comparison.
--
-- Source list:
--   /Users/praveenm/Desktop/Auxia/holley/doc/TOP_100_VEHICLES_SPOT_CHECK - TOP_100_VEHICLES_list.pdf
--
-- Notes:
--   - One representative v5.18 recommendation row is selected per vehicle (YMM).
--   - Representative row is deterministic: prefer 4-rec rows, then highest total score.
--   - Includes source_user_count from the PDF list for quick drift comparison.
--
-- Usage:
--   bq query --use_legacy_sql=false < sql/validation/v5_18_top_100_vehicle_spot_check.sql
-- ====================================================================================

CREATE TEMP TABLE ordered_vehicles AS
SELECT *
FROM UNNEST([
  STRUCT(1 AS rank, 1965 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 3098 AS source_user_count),
  STRUCT(2 AS rank, 1967 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 2554 AS source_user_count),
  STRUCT(3 AS rank, 1970 AS v1_year, 'CHEVROLET' AS v1_make, 'CHEVELLE' AS v1_model, 2326 AS source_user_count),
  STRUCT(4 AS rank, 1966 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 2321 AS source_user_count),
  STRUCT(5 AS rank, 1969 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 2145 AS source_user_count),
  STRUCT(6 AS rank, 1990 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 1956 AS source_user_count),
  STRUCT(7 AS rank, 1969 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 1914 AS source_user_count),
  STRUCT(8 AS rank, 1972 AS v1_year, 'CHEVROLET' AS v1_make, 'C10 PICKUP' AS v1_model, 1890 AS source_user_count),
  STRUCT(9 AS rank, 1968 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 1889 AS source_user_count),
  STRUCT(10 AS rank, 1967 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 1835 AS source_user_count),
  STRUCT(11 AS rank, 1968 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 1795 AS source_user_count),
  STRUCT(12 AS rank, 1985 AS v1_year, 'CHEVROLET' AS v1_make, 'C10' AS v1_model, 1542 AS source_user_count),
  STRUCT(13 AS rank, 1988 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 1514 AS source_user_count),
  STRUCT(14 AS rank, 1989 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 1511 AS source_user_count),
  STRUCT(15 AS rank, 1986 AS v1_year, 'CHEVROLET' AS v1_make, 'C10' AS v1_model, 1487 AS source_user_count),
  STRUCT(16 AS rank, 1966 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 1458 AS source_user_count),
  STRUCT(17 AS rank, 1993 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 1374 AS source_user_count),
  STRUCT(18 AS rank, 1967 AS v1_year, 'CHEVROLET' AS v1_make, 'CHEVELLE' AS v1_model, 1301 AS source_user_count),
  STRUCT(19 AS rank, 1971 AS v1_year, 'CHEVROLET' AS v1_make, 'CHEVELLE' AS v1_model, 1248 AS source_user_count),
  STRUCT(20 AS rank, 1970 AS v1_year, 'CHEVROLET' AS v1_make, 'C10 PICKUP' AS v1_model, 1222 AS source_user_count),
  STRUCT(21 AS rank, 1966 AS v1_year, 'CHEVROLET' AS v1_make, 'CHEVELLE' AS v1_model, 1216 AS source_user_count),
  STRUCT(22 AS rank, 1968 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 1204 AS source_user_count),
  STRUCT(23 AS rank, 1969 AS v1_year, 'CHEVROLET' AS v1_make, 'CHEVELLE' AS v1_model, 1200 AS source_user_count),
  STRUCT(24 AS rank, 1955 AS v1_year, 'CHEVROLET' AS v1_make, 'BEL AIR' AS v1_model, 1158 AS source_user_count),
  STRUCT(25 AS rank, 1972 AS v1_year, 'CHEVROLET' AS v1_make, 'CHEVELLE' AS v1_model, 1156 AS source_user_count),
  STRUCT(26 AS rank, 1957 AS v1_year, 'CHEVROLET' AS v1_make, 'BEL AIR' AS v1_model, 1148 AS source_user_count),
  STRUCT(27 AS rank, 1968 AS v1_year, 'CHEVROLET' AS v1_make, 'C10 PICKUP' AS v1_model, 1135 AS source_user_count),
  STRUCT(28 AS rank, 1968 AS v1_year, 'CHEVROLET' AS v1_make, 'CHEVELLE' AS v1_model, 1131 AS source_user_count),
  STRUCT(29 AS rank, 1971 AS v1_year, 'CHEVROLET' AS v1_make, 'C10 PICKUP' AS v1_model, 1106 AS source_user_count),
  STRUCT(30 AS rank, 2004 AS v1_year, 'CHEVROLET' AS v1_make, 'SILVERADO 1500' AS v1_model, 1098 AS source_user_count),
  STRUCT(31 AS rank, 1989 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 1096 AS source_user_count),
  STRUCT(32 AS rank, 1970 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 1083 AS source_user_count),
  STRUCT(33 AS rank, 1984 AS v1_year, 'CHEVROLET' AS v1_make, 'C10' AS v1_model, 1065 AS source_user_count),
  STRUCT(34 AS rank, 2015 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 1060 AS source_user_count),
  STRUCT(35 AS rank, 1966 AS v1_year, 'CHEVROLET' AS v1_make, 'C10 PICKUP' AS v1_model, 1037 AS source_user_count),
  STRUCT(36 AS rank, 1970 AS v1_year, 'CHEVROLET' AS v1_make, 'NOVA' AS v1_model, 1029 AS source_user_count),
  STRUCT(37 AS rank, 1969 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 1027 AS source_user_count),
  STRUCT(38 AS rank, 1967 AS v1_year, 'CHEVROLET' AS v1_make, 'C10 PICKUP' AS v1_model, 1022 AS source_user_count),
  STRUCT(39 AS rank, 1969 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 1021 AS source_user_count),
  STRUCT(40 AS rank, 2000 AS v1_year, 'CHEVROLET' AS v1_make, 'SILVERADO 1500' AS v1_model, 1021 AS source_user_count),
  STRUCT(41 AS rank, 1979 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 1001 AS source_user_count),
  STRUCT(42 AS rank, 1986 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 991 AS source_user_count),
  STRUCT(43 AS rank, 1987 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 984 AS source_user_count),
  STRUCT(44 AS rank, 2013 AS v1_year, 'DODGE' AS v1_make, 'CHARGER' AS v1_model, 975 AS source_user_count),
  STRUCT(45 AS rank, 2014 AS v1_year, 'DODGE' AS v1_make, 'CHARGER' AS v1_model, 953 AS source_user_count),
  STRUCT(46 AS rank, 1995 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 937 AS source_user_count),
  STRUCT(47 AS rank, 2010 AS v1_year, 'DODGE' AS v1_make, 'CHALLENGER' AS v1_model, 923 AS source_user_count),
  STRUCT(48 AS rank, 1969 AS v1_year, 'CHEVROLET' AS v1_make, 'C10 PICKUP' AS v1_model, 916 AS source_user_count),
  STRUCT(49 AS rank, 1965 AS v1_year, 'CHEVROLET' AS v1_make, 'C10 PICKUP' AS v1_model, 909 AS source_user_count),
  STRUCT(50 AS rank, 2006 AS v1_year, 'CHEVROLET' AS v1_make, 'SILVERADO 1500' AS v1_model, 900 AS source_user_count),
  STRUCT(51 AS rank, 2012 AS v1_year, 'DODGE' AS v1_make, 'CHARGER' AS v1_model, 895 AS source_user_count),
  STRUCT(52 AS rank, 1967 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 888 AS source_user_count),
  STRUCT(53 AS rank, 1992 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 878 AS source_user_count),
  STRUCT(54 AS rank, 1991 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 840 AS source_user_count),
  STRUCT(55 AS rank, 1993 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 833 AS source_user_count),
  STRUCT(56 AS rank, 1978 AS v1_year, 'CHEVROLET' AS v1_make, 'C10' AS v1_model, 833 AS source_user_count),
  STRUCT(57 AS rank, 2007 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 827 AS source_user_count),
  STRUCT(58 AS rank, 2003 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 823 AS source_user_count),
  STRUCT(59 AS rank, 2014 AS v1_year, 'CHEVROLET' AS v1_make, 'SILVERADO 1500' AS v1_model, 809 AS source_user_count),
  STRUCT(60 AS rank, 2017 AS v1_year, 'CHEVROLET' AS v1_make, 'SILVERADO 1500' AS v1_model, 774 AS source_user_count),
  STRUCT(61 AS rank, 1991 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 759 AS source_user_count),
  STRUCT(62 AS rank, 1969 AS v1_year, 'CHEVROLET' AS v1_make, 'C10 PICKUP' AS v1_model, 749 AS source_user_count),
  STRUCT(63 AS rank, 1987 AS v1_year, 'CHEVROLET' AS v1_make, 'MONTE CARLO' AS v1_model, 740 AS source_user_count),
  STRUCT(64 AS rank, 2004 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 737 AS source_user_count),
  STRUCT(65 AS rank, 2010 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 725 AS source_user_count),
  STRUCT(66 AS rank, 1966 AS v1_year, 'CHEVROLET' AS v1_make, 'CHEVY II' AS v1_model, 709 AS source_user_count),
  STRUCT(67 AS rank, 1991 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 707 AS source_user_count),
  STRUCT(68 AS rank, 2002 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 706 AS source_user_count),
  STRUCT(69 AS rank, 1969 AS v1_year, 'CHEVROLET' AS v1_make, 'NOVA' AS v1_model, 703 AS source_user_count),
  STRUCT(70 AS rank, 2014 AS v1_year, 'FORD' AS v1_make, 'F-150' AS v1_model, 700 AS source_user_count),
  STRUCT(71 AS rank, 1983 AS v1_year, 'CHEVROLET' AS v1_make, 'C10' AS v1_model, 696 AS source_user_count),
  STRUCT(72 AS rank, 1994 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 694 AS source_user_count),
  STRUCT(73 AS rank, 2008 AS v1_year, 'CHEVROLET' AS v1_make, 'SILVERADO 1500' AS v1_model, 694 AS source_user_count),
  STRUCT(74 AS rank, 2012 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 689 AS source_user_count),
  STRUCT(75 AS rank, 1972 AS v1_year, 'CHEVROLET' AS v1_make, 'NOVA' AS v1_model, 688 AS source_user_count),
  STRUCT(76 AS rank, 1973 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 681 AS source_user_count),
  STRUCT(77 AS rank, 2014 AS v1_year, 'RAM' AS v1_make, '1500' AS v1_model, 679 AS source_user_count),
  STRUCT(78 AS rank, 1986 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 674 AS source_user_count),
  STRUCT(79 AS rank, 1979 AS v1_year, 'CHEVROLET' AS v1_make, 'C10' AS v1_model, 668 AS source_user_count),
  STRUCT(80 AS rank, 2010 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 663 AS source_user_count),
  STRUCT(81 AS rank, 2003 AS v1_year, 'CHEVROLET' AS v1_make, 'SILVERADO 1500' AS v1_model, 661 AS source_user_count),
  STRUCT(82 AS rank, 2000 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 660 AS source_user_count),
  STRUCT(83 AS rank, 1981 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 657 AS source_user_count),
  STRUCT(84 AS rank, 2011 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 655 AS source_user_count),
  STRUCT(85 AS rank, 2002 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 653 AS source_user_count),
  STRUCT(86 AS rank, 2018 AS v1_year, 'CHEVROLET' AS v1_make, 'SILVERADO 1500' AS v1_model, 651 AS source_user_count),
  STRUCT(87 AS rank, 2001 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 650 AS source_user_count),
  STRUCT(88 AS rank, 2008 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 648 AS source_user_count),
  STRUCT(89 AS rank, 2005 AS v1_year, 'CHEVROLET' AS v1_make, 'SILVERADO 1500' AS v1_model, 645 AS source_user_count),
  STRUCT(90 AS rank, 1981 AS v1_year, 'CHEVROLET' AS v1_make, 'C10' AS v1_model, 634 AS source_user_count),
  STRUCT(91 AS rank, 1971 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 634 AS source_user_count),
  STRUCT(92 AS rank, 2009 AS v1_year, 'DODGE' AS v1_make, 'CHALLENGER' AS v1_model, 631 AS source_user_count),
  STRUCT(93 AS rank, 1985 AS v1_year, 'CHEVROLET' AS v1_make, 'MONTE CARLO' AS v1_model, 627 AS source_user_count),
  STRUCT(94 AS rank, 2005 AS v1_year, 'FORD' AS v1_make, 'MUSTANG' AS v1_model, 625 AS source_user_count),
  STRUCT(95 AS rank, 1967 AS v1_year, 'CHEVROLET' AS v1_make, 'CHEVY II' AS v1_model, 622 AS source_user_count),
  STRUCT(96 AS rank, 1993 AS v1_year, 'CHEVROLET' AS v1_make, 'C1500' AS v1_model, 621 AS source_user_count),
  STRUCT(97 AS rank, 2016 AS v1_year, 'RAM' AS v1_make, '1500' AS v1_model, 620 AS source_user_count),
  STRUCT(98 AS rank, 1982 AS v1_year, 'CHEVROLET' AS v1_make, 'C10' AS v1_model, 617 AS source_user_count),
  STRUCT(99 AS rank, 2003 AS v1_year, 'CHEVROLET' AS v1_make, 'SILVERADO 1500' AS v1_model, 615 AS source_user_count),
  STRUCT(100 AS rank, 1985 AS v1_year, 'CHEVROLET' AS v1_make, 'CAMARO' AS v1_model, 613 AS source_user_count)
]);

CREATE TEMP TABLE final_norm AS
SELECT
  LOWER(TRIM(email_lower)) AS email_lower,
  SAFE_CAST(v1_year AS INT64) AS v1_year,
  UPPER(TRIM(v1_make)) AS v1_make,
  REGEXP_REPLACE(UPPER(TRIM(v1_model)), r'\s+', ' ') AS v1_model,
  rec_part_1,
  rec1_price,
  rec1_score,
  rec1_image,
  rec1_type,
  rec1_pop_source,
  rec_part_2,
  rec2_price,
  rec2_score,
  rec2_image,
  rec2_type,
  rec2_pop_source,
  rec_part_3,
  rec3_price,
  rec3_score,
  rec3_image,
  rec3_type,
  rec3_pop_source,
  rec_part_4,
  rec4_price,
  rec4_score,
  rec4_image,
  rec4_type,
  rec4_pop_source,
  fitment_count,
  engagement_tier,
  generated_at,
  pipeline_version
FROM `auxia-reporting.temp_holley_v5_18.final_vehicle_recommendations`
WHERE SAFE_CAST(v1_year AS INT64) IS NOT NULL;

CREATE TEMP TABLE vehicle_ranked AS
SELECT
  fn.*,
  COUNT(*) OVER (PARTITION BY fn.v1_year, fn.v1_make, fn.v1_model) AS v5_18_user_count,
  ROW_NUMBER() OVER (
    PARTITION BY fn.v1_year, fn.v1_make, fn.v1_model
    ORDER BY
      fitment_count DESC,
      (rec1_score + rec2_score + rec3_score + COALESCE(rec4_score, 0)) DESC,
      rec1_score DESC,
      email_lower
  ) AS vehicle_pick_rank
FROM final_norm fn;

-- 1) Detail output in exact client rank order
SELECT
  ov.rank,
  ov.v1_year,
  ov.v1_make,
  ov.v1_model,
  ov.source_user_count,
  vr.v5_18_user_count,
  CASE WHEN vr.email_lower IS NULL THEN 'MISSING_IN_V5_18' ELSE 'MATCHED' END AS match_status,
  vr.email_lower AS selected_email,
  vr.fitment_count,
  vr.engagement_tier,
  vr.pipeline_version,
  vr.generated_at,
  vr.rec_part_1,
  vr.rec1_price,
  vr.rec1_score,
  vr.rec1_type,
  vr.rec1_pop_source,
  vr.rec_part_2,
  vr.rec2_price,
  vr.rec2_score,
  vr.rec2_type,
  vr.rec2_pop_source,
  vr.rec_part_3,
  vr.rec3_price,
  vr.rec3_score,
  vr.rec3_type,
  vr.rec3_pop_source,
  vr.rec_part_4,
  vr.rec4_price,
  vr.rec4_score,
  vr.rec4_type,
  vr.rec4_pop_source
FROM ordered_vehicles ov
LEFT JOIN vehicle_ranked vr
  ON ov.v1_year = vr.v1_year
 AND ov.v1_make = vr.v1_make
 AND ov.v1_model = vr.v1_model
 AND vr.vehicle_pick_rank = 1
ORDER BY ov.rank;

-- 2) Summary
SELECT
  COUNT(*) AS total_vehicles_in_list,
  COUNTIF(vr.email_lower IS NOT NULL) AS matched_vehicles,
  COUNTIF(vr.email_lower IS NULL) AS missing_vehicles,
  ROUND(COUNTIF(vr.email_lower IS NOT NULL) * 100.0 / COUNT(*), 2) AS match_rate_pct
FROM ordered_vehicles ov
LEFT JOIN vehicle_ranked vr
  ON ov.v1_year = vr.v1_year
 AND ov.v1_make = vr.v1_make
 AND ov.v1_model = vr.v1_model
 AND vr.vehicle_pick_rank = 1;
