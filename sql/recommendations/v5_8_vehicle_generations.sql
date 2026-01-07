-- v5.8 Vehicle Generation Mappings
-- Purpose: Define year ranges where parts are interchangeable for pooling segment data
-- Created: 2026-01-06
-- Linear Ticket: AUX-11434
--
-- Usage: Join users to this table to expand sparse vehicle segments to generation peers
-- Example: A 1968 Camaro user gets segment data from all 1967-1969 Camaro owners

CREATE OR REPLACE TABLE `auxia-reporting.temp_holley_v5_8.vehicle_generations` AS

SELECT * FROM UNNEST([
  -- =========================================================================
  -- FORD MUSTANG (52,476 users) - America's pony car
  -- =========================================================================
  STRUCT('FORD' as make, 'MUSTANG' as model, 1964 as year_start, 1973 as year_end, '1st Gen (Classic)' as generation),
  STRUCT('FORD', 'MUSTANG', 1974, 1978, '2nd Gen (Mustang II)'),
  STRUCT('FORD', 'MUSTANG', 1979, 1993, '3rd Gen (Fox Body)'),
  STRUCT('FORD', 'MUSTANG', 1994, 2004, '4th Gen (SN-95)'),
  STRUCT('FORD', 'MUSTANG', 2005, 2014, '5th Gen (S-197)'),
  STRUCT('FORD', 'MUSTANG', 2015, 2024, '6th Gen (S-550)'),

  -- =========================================================================
  -- CHEVROLET CAMARO (33,801 users) - The F-body legend
  -- =========================================================================
  STRUCT('CHEVROLET', 'CAMARO', 1967, 1969, '1st Gen'),
  STRUCT('CHEVROLET', 'CAMARO', 1970, 1981, '2nd Gen'),
  STRUCT('CHEVROLET', 'CAMARO', 1982, 1992, '3rd Gen'),
  STRUCT('CHEVROLET', 'CAMARO', 1993, 2002, '4th Gen'),
  STRUCT('CHEVROLET', 'CAMARO', 2010, 2015, '5th Gen'),
  STRUCT('CHEVROLET', 'CAMARO', 2016, 2024, '6th Gen'),

  -- =========================================================================
  -- CHEVROLET SILVERADO 1500 (19,450 users) - Modern full-size truck
  -- =========================================================================
  STRUCT('CHEVROLET', 'SILVERADO 1500', 1999, 2006, '1st Gen (GMT800)'),
  STRUCT('CHEVROLET', 'SILVERADO 1500', 2007, 2013, '2nd Gen (GMT900)'),
  STRUCT('CHEVROLET', 'SILVERADO 1500', 2014, 2018, '3rd Gen (K2XX)'),
  STRUCT('CHEVROLET', 'SILVERADO 1500', 2019, 2024, '4th Gen (T1XX)'),

  -- =========================================================================
  -- FORD F-150 (17,636 users) - Best-selling truck
  -- =========================================================================
  STRUCT('FORD', 'F-150', 1948, 1952, '1st Gen (F-Series Bonus Built)'),
  STRUCT('FORD', 'F-150', 1953, 1956, '2nd Gen'),
  STRUCT('FORD', 'F-150', 1957, 1960, '3rd Gen'),
  STRUCT('FORD', 'F-150', 1961, 1966, '4th Gen'),
  STRUCT('FORD', 'F-150', 1967, 1972, '5th Gen (Bumpsides)'),
  STRUCT('FORD', 'F-150', 1973, 1979, '6th Gen (Dentside)'),
  STRUCT('FORD', 'F-150', 1980, 1986, '7th Gen (Bullnose)'),
  STRUCT('FORD', 'F-150', 1987, 1991, '8th Gen (Brick Nose)'),
  STRUCT('FORD', 'F-150', 1992, 1996, '9th Gen (OBS)'),
  STRUCT('FORD', 'F-150', 1997, 2003, '10th Gen'),
  STRUCT('FORD', 'F-150', 2004, 2008, '11th Gen'),
  STRUCT('FORD', 'F-150', 2009, 2014, '12th Gen'),
  STRUCT('FORD', 'F-150', 2015, 2020, '13th Gen'),
  STRUCT('FORD', 'F-150', 2021, 2024, '14th Gen'),

  -- =========================================================================
  -- CHEVROLET C10 / C10 PICKUP (25,030 users combined) - Classic truck
  -- =========================================================================
  STRUCT('CHEVROLET', 'C10', 1960, 1966, '1st Gen (C/K)'),
  STRUCT('CHEVROLET', 'C10', 1967, 1972, '2nd Gen (C/K)'),
  STRUCT('CHEVROLET', 'C10', 1973, 1987, '3rd Gen (Square Body)'),
  STRUCT('CHEVROLET', 'C10 PICKUP', 1960, 1966, '1st Gen (C/K)'),
  STRUCT('CHEVROLET', 'C10 PICKUP', 1967, 1972, '2nd Gen (C/K)'),
  STRUCT('CHEVROLET', 'C10 PICKUP', 1973, 1987, '3rd Gen (Square Body)'),

  -- =========================================================================
  -- CHEVROLET CORVETTE (13,810 users) - America's sports car
  -- =========================================================================
  STRUCT('CHEVROLET', 'CORVETTE', 1953, 1962, 'C1'),
  STRUCT('CHEVROLET', 'CORVETTE', 1963, 1967, 'C2 (Sting Ray)'),
  STRUCT('CHEVROLET', 'CORVETTE', 1968, 1982, 'C3'),
  STRUCT('CHEVROLET', 'CORVETTE', 1984, 1996, 'C4'),
  STRUCT('CHEVROLET', 'CORVETTE', 1997, 2004, 'C5'),
  STRUCT('CHEVROLET', 'CORVETTE', 2005, 2013, 'C6'),
  STRUCT('CHEVROLET', 'CORVETTE', 2014, 2019, 'C7'),
  STRUCT('CHEVROLET', 'CORVETTE', 2020, 2024, 'C8'),

  -- =========================================================================
  -- CHEVROLET CHEVELLE (11,948 users) - A-body muscle car
  -- =========================================================================
  STRUCT('CHEVROLET', 'CHEVELLE', 1964, 1967, '1st Gen (A-body)'),
  STRUCT('CHEVROLET', 'CHEVELLE', 1968, 1972, '2nd Gen (A-body)'),
  STRUCT('CHEVROLET', 'CHEVELLE', 1973, 1977, '3rd Gen (A-body/Laguna)'),

  -- =========================================================================
  -- DODGE CHARGER (8,719 users) - Mopar muscle
  -- =========================================================================
  STRUCT('DODGE', 'CHARGER', 1966, 1967, '1st Gen'),
  STRUCT('DODGE', 'CHARGER', 1968, 1970, '2nd Gen (B-body)'),
  STRUCT('DODGE', 'CHARGER', 1971, 1974, '3rd Gen (B-body)'),
  STRUCT('DODGE', 'CHARGER', 1975, 1978, '4th Gen (B-body)'),
  STRUCT('DODGE', 'CHARGER', 1982, 1987, '5th Gen (L-body)'),
  STRUCT('DODGE', 'CHARGER', 2006, 2010, '6th Gen (LX)'),
  STRUCT('DODGE', 'CHARGER', 2011, 2024, '7th Gen (LD)'),

  -- =========================================================================
  -- PONTIAC FIREBIRD (8,368 users) - F-body sibling
  -- =========================================================================
  STRUCT('PONTIAC', 'FIREBIRD', 1967, 1969, '1st Gen'),
  STRUCT('PONTIAC', 'FIREBIRD', 1970, 1981, '2nd Gen'),
  STRUCT('PONTIAC', 'FIREBIRD', 1982, 1992, '3rd Gen'),
  STRUCT('PONTIAC', 'FIREBIRD', 1993, 2002, '4th Gen'),

  -- =========================================================================
  -- DODGE CHALLENGER (8,201 users) - E-body muscle
  -- =========================================================================
  STRUCT('DODGE', 'CHALLENGER', 1970, 1974, '1st Gen (E-body)'),
  STRUCT('DODGE', 'CHALLENGER', 1978, 1983, '2nd Gen (Mitsubishi)'),
  STRUCT('DODGE', 'CHALLENGER', 2008, 2024, '3rd Gen (LC)'),

  -- =========================================================================
  -- FORD F-100 (7,151 users) - Classic Ford truck
  -- =========================================================================
  STRUCT('FORD', 'F-100', 1948, 1952, '1st Gen'),
  STRUCT('FORD', 'F-100', 1953, 1956, '2nd Gen'),
  STRUCT('FORD', 'F-100', 1957, 1960, '3rd Gen'),
  STRUCT('FORD', 'F-100', 1961, 1966, '4th Gen'),
  STRUCT('FORD', 'F-100', 1967, 1972, '5th Gen (Bumpsides)'),
  STRUCT('FORD', 'F-100', 1973, 1979, '6th Gen (Dentside)'),

  -- =========================================================================
  -- RAM 1500 (6,723 users) - Modern Ram truck
  -- =========================================================================
  STRUCT('RAM', '1500', 2009, 2012, '4th Gen (DS)'),
  STRUCT('RAM', '1500', 2013, 2018, '4th Gen (DS Refresh)'),
  STRUCT('RAM', '1500', 2019, 2024, '5th Gen (DT)'),

  -- =========================================================================
  -- JEEP WRANGLER (6,614 users) - Off-road icon
  -- =========================================================================
  STRUCT('JEEP', 'WRANGLER', 1987, 1995, 'YJ'),
  STRUCT('JEEP', 'WRANGLER', 1997, 2006, 'TJ'),
  STRUCT('JEEP', 'WRANGLER', 2007, 2018, 'JK'),
  STRUCT('JEEP', 'WRANGLER', 2018, 2024, 'JL'),

  -- =========================================================================
  -- CHEVROLET C1500 (6,336 users) - GMT400 truck
  -- =========================================================================
  STRUCT('CHEVROLET', 'C1500', 1988, 1998, 'GMT400'),
  STRUCT('CHEVROLET', 'C1500', 1999, 2000, 'GMT400 (Final)'),

  -- =========================================================================
  -- GMC SIERRA 1500 (6,187 users) - GMC truck
  -- =========================================================================
  STRUCT('GMC', 'SIERRA 1500', 1999, 2006, '1st Gen (GMT800)'),
  STRUCT('GMC', 'SIERRA 1500', 2007, 2013, '2nd Gen (GMT900)'),
  STRUCT('GMC', 'SIERRA 1500', 2014, 2018, '3rd Gen (K2XX)'),
  STRUCT('GMC', 'SIERRA 1500', 2019, 2024, '4th Gen (T1XX)'),

  -- =========================================================================
  -- CHEVROLET NOVA (6,138 users) - Compact classic
  -- =========================================================================
  STRUCT('CHEVROLET', 'NOVA', 1962, 1965, '1st Gen (X-body)'),
  STRUCT('CHEVROLET', 'NOVA', 1966, 1967, '2nd Gen (X-body)'),
  STRUCT('CHEVROLET', 'NOVA', 1968, 1974, '3rd Gen (X-body)'),
  STRUCT('CHEVROLET', 'NOVA', 1975, 1979, '4th Gen (X-body)'),

  -- =========================================================================
  -- CHEVROLET S10 (5,993 users) - Compact truck
  -- =========================================================================
  STRUCT('CHEVROLET', 'S10', 1982, 1993, '1st Gen'),
  STRUCT('CHEVROLET', 'S10', 1994, 2004, '2nd Gen'),

  -- =========================================================================
  -- CHEVROLET SILVERADO 2500 HD (5,145 users) - Heavy duty
  -- =========================================================================
  STRUCT('CHEVROLET', 'SILVERADO 2500 HD', 2001, 2006, '1st Gen'),
  STRUCT('CHEVROLET', 'SILVERADO 2500 HD', 2007, 2014, '2nd Gen'),
  STRUCT('CHEVROLET', 'SILVERADO 2500 HD', 2015, 2019, '3rd Gen'),
  STRUCT('CHEVROLET', 'SILVERADO 2500 HD', 2020, 2024, '4th Gen'),

  -- =========================================================================
  -- CHEVROLET MONTE CARLO (4,933 users) - Personal luxury
  -- =========================================================================
  STRUCT('CHEVROLET', 'MONTE CARLO', 1970, 1972, '1st Gen'),
  STRUCT('CHEVROLET', 'MONTE CARLO', 1973, 1977, '2nd Gen'),
  STRUCT('CHEVROLET', 'MONTE CARLO', 1978, 1988, '3rd Gen (G-body)'),
  STRUCT('CHEVROLET', 'MONTE CARLO', 1995, 1999, '5th Gen'),
  STRUCT('CHEVROLET', 'MONTE CARLO', 2000, 2007, '6th Gen'),

  -- =========================================================================
  -- DODGE RAM 1500 (4,680 users) - Legacy naming
  -- =========================================================================
  STRUCT('DODGE', 'RAM 1500', 1994, 2001, '2nd Gen'),
  STRUCT('DODGE', 'RAM 1500', 2002, 2008, '3rd Gen'),
  STRUCT('DODGE', 'RAM 1500', 2009, 2018, '4th Gen (DS)'),

  -- =========================================================================
  -- CHEVROLET EL CAMINO (4,520 users) - Car-truck hybrid
  -- =========================================================================
  STRUCT('CHEVROLET', 'EL CAMINO', 1959, 1960, '1st Gen'),
  STRUCT('CHEVROLET', 'EL CAMINO', 1964, 1967, '2nd Gen'),
  STRUCT('CHEVROLET', 'EL CAMINO', 1968, 1972, '3rd Gen'),
  STRUCT('CHEVROLET', 'EL CAMINO', 1973, 1977, '4th Gen'),
  STRUCT('CHEVROLET', 'EL CAMINO', 1978, 1987, '5th Gen (G-body)'),

  -- =========================================================================
  -- CHEVROLET IMPALA (4,506 users) - Full-size icon
  -- =========================================================================
  STRUCT('CHEVROLET', 'IMPALA', 1958, 1958, '1st Gen'),
  STRUCT('CHEVROLET', 'IMPALA', 1959, 1960, '2nd Gen'),
  STRUCT('CHEVROLET', 'IMPALA', 1961, 1964, '3rd Gen'),
  STRUCT('CHEVROLET', 'IMPALA', 1965, 1970, '4th Gen'),
  STRUCT('CHEVROLET', 'IMPALA', 1971, 1976, '5th Gen'),
  STRUCT('CHEVROLET', 'IMPALA', 1977, 1985, '6th Gen'),
  STRUCT('CHEVROLET', 'IMPALA', 1994, 1996, '7th Gen (SS)'),
  STRUCT('CHEVROLET', 'IMPALA', 2000, 2005, '8th Gen'),
  STRUCT('CHEVROLET', 'IMPALA', 2006, 2016, '9th Gen'),
  STRUCT('CHEVROLET', 'IMPALA', 2014, 2020, '10th Gen'),

  -- =========================================================================
  -- CHEVROLET BEL AIR (3,936 users) - 1950s classic
  -- =========================================================================
  STRUCT('CHEVROLET', 'BEL AIR', 1950, 1952, '1st Gen'),
  STRUCT('CHEVROLET', 'BEL AIR', 1953, 1954, '2nd Gen'),
  STRUCT('CHEVROLET', 'BEL AIR', 1955, 1957, '3rd Gen (Tri-Five)'),
  STRUCT('CHEVROLET', 'BEL AIR', 1958, 1958, '4th Gen'),
  STRUCT('CHEVROLET', 'BEL AIR', 1959, 1960, '5th Gen'),
  STRUCT('CHEVROLET', 'BEL AIR', 1961, 1964, '6th Gen'),
  STRUCT('CHEVROLET', 'BEL AIR', 1965, 1970, '7th Gen'),
  STRUCT('CHEVROLET', 'BEL AIR', 1971, 1975, '8th Gen'),

  -- =========================================================================
  -- FORD BRONCO (3,909 users) - Off-road legend
  -- =========================================================================
  STRUCT('FORD', 'BRONCO', 1966, 1977, '1st Gen (Early)'),
  STRUCT('FORD', 'BRONCO', 1978, 1979, '2nd Gen'),
  STRUCT('FORD', 'BRONCO', 1980, 1986, '3rd Gen'),
  STRUCT('FORD', 'BRONCO', 1987, 1991, '4th Gen'),
  STRUCT('FORD', 'BRONCO', 1992, 1996, '5th Gen'),
  STRUCT('FORD', 'BRONCO', 2021, 2024, '6th Gen'),

  -- =========================================================================
  -- FORD F-250 (3,492 users) - Heavy duty truck
  -- =========================================================================
  STRUCT('FORD', 'F-250', 1967, 1972, '5th Gen'),
  STRUCT('FORD', 'F-250', 1973, 1979, '6th Gen'),
  STRUCT('FORD', 'F-250', 1980, 1986, '7th Gen'),
  STRUCT('FORD', 'F-250', 1987, 1991, '8th Gen'),
  STRUCT('FORD', 'F-250', 1992, 1997, '9th Gen'),

  -- =========================================================================
  -- FORD F-250 SUPER DUTY (2,876 users)
  -- =========================================================================
  STRUCT('FORD', 'F-250 SUPER DUTY', 1999, 2007, '1st Gen'),
  STRUCT('FORD', 'F-250 SUPER DUTY', 2008, 2010, '2nd Gen'),
  STRUCT('FORD', 'F-250 SUPER DUTY', 2011, 2016, '3rd Gen'),
  STRUCT('FORD', 'F-250 SUPER DUTY', 2017, 2024, '4th Gen'),

  -- =========================================================================
  -- CHEVROLET TAHOE (3,359 users) - Full-size SUV
  -- =========================================================================
  STRUCT('CHEVROLET', 'TAHOE', 1995, 1999, '1st Gen (GMT400)'),
  STRUCT('CHEVROLET', 'TAHOE', 2000, 2006, '2nd Gen (GMT800)'),
  STRUCT('CHEVROLET', 'TAHOE', 2007, 2014, '3rd Gen (GMT900)'),
  STRUCT('CHEVROLET', 'TAHOE', 2015, 2020, '4th Gen (K2XX)'),
  STRUCT('CHEVROLET', 'TAHOE', 2021, 2024, '5th Gen (T1XX)'),

  -- =========================================================================
  -- CHEVROLET CHEVY II (3,281 users) - Pre-Nova
  -- =========================================================================
  STRUCT('CHEVROLET', 'CHEVY II', 1962, 1965, '1st Gen (X-body)'),
  STRUCT('CHEVROLET', 'CHEVY II', 1966, 1967, '2nd Gen (X-body)'),

  -- =========================================================================
  -- CHEVROLET TRUCK (3,224 users) - Generic truck
  -- =========================================================================
  STRUCT('CHEVROLET', 'TRUCK', 1947, 1955, 'Advance Design'),
  STRUCT('CHEVROLET', 'TRUCK', 1955, 1959, 'Task Force'),
  STRUCT('CHEVROLET', 'TRUCK', 1960, 1966, '1st Gen C/K'),
  STRUCT('CHEVROLET', 'TRUCK', 1967, 1972, '2nd Gen C/K'),
  STRUCT('CHEVROLET', 'TRUCK', 1973, 1991, '3rd Gen C/K'),

  -- =========================================================================
  -- CHEVROLET MALIBU (3,198 users)
  -- =========================================================================
  STRUCT('CHEVROLET', 'MALIBU', 1964, 1967, '1st Gen (Chevelle)'),
  STRUCT('CHEVROLET', 'MALIBU', 1968, 1972, '2nd Gen (Chevelle)'),
  STRUCT('CHEVROLET', 'MALIBU', 1973, 1977, '3rd Gen (Chevelle)'),
  STRUCT('CHEVROLET', 'MALIBU', 1978, 1983, '4th Gen (G-body)'),
  STRUCT('CHEVROLET', 'MALIBU', 1997, 2003, '5th Gen'),
  STRUCT('CHEVROLET', 'MALIBU', 2004, 2007, '6th Gen'),
  STRUCT('CHEVROLET', 'MALIBU', 2008, 2012, '7th Gen'),
  STRUCT('CHEVROLET', 'MALIBU', 2013, 2015, '8th Gen'),
  STRUCT('CHEVROLET', 'MALIBU', 2016, 2024, '9th Gen'),

  -- =========================================================================
  -- DODGE RAM 2500 (3,173 users)
  -- =========================================================================
  STRUCT('DODGE', 'RAM 2500', 1994, 2002, '2nd Gen'),
  STRUCT('DODGE', 'RAM 2500', 2003, 2009, '3rd Gen'),
  STRUCT('DODGE', 'RAM 2500', 2010, 2018, '4th Gen'),

  -- =========================================================================
  -- PONTIAC GTO (2,878 users) - The original muscle car
  -- =========================================================================
  STRUCT('PONTIAC', 'GTO', 1964, 1967, '1st Gen (A-body)'),
  STRUCT('PONTIAC', 'GTO', 1968, 1972, '2nd Gen (A-body)'),
  STRUCT('PONTIAC', 'GTO', 1973, 1974, '3rd Gen'),
  STRUCT('PONTIAC', 'GTO', 2004, 2006, '4th Gen (Holden)'),

  -- =========================================================================
  -- FORD RANGER (2,626 users)
  -- =========================================================================
  STRUCT('FORD', 'RANGER', 1983, 1992, '1st Gen'),
  STRUCT('FORD', 'RANGER', 1993, 1997, '2nd Gen'),
  STRUCT('FORD', 'RANGER', 1998, 2012, '3rd Gen'),
  STRUCT('FORD', 'RANGER', 2019, 2024, '4th Gen'),

  -- =========================================================================
  -- CHEVROLET K10 (2,625 users) - 4WD C10
  -- =========================================================================
  STRUCT('CHEVROLET', 'K10', 1960, 1966, '1st Gen'),
  STRUCT('CHEVROLET', 'K10', 1967, 1972, '2nd Gen'),
  STRUCT('CHEVROLET', 'K10', 1973, 1987, '3rd Gen (Square Body)'),

  -- =========================================================================
  -- JEEP GRAND CHEROKEE (2,594 users)
  -- =========================================================================
  STRUCT('JEEP', 'GRAND CHEROKEE', 1993, 1998, 'ZJ'),
  STRUCT('JEEP', 'GRAND CHEROKEE', 1999, 2004, 'WJ'),
  STRUCT('JEEP', 'GRAND CHEROKEE', 2005, 2010, 'WK'),
  STRUCT('JEEP', 'GRAND CHEROKEE', 2011, 2021, 'WK2'),
  STRUCT('JEEP', 'GRAND CHEROKEE', 2022, 2024, 'WL'),

  -- =========================================================================
  -- GMC C1500 (2,545 users)
  -- =========================================================================
  STRUCT('GMC', 'C1500', 1988, 1998, 'GMT400'),
  STRUCT('GMC', 'C1500', 1999, 2000, 'GMT400 (Final)'),

  -- =========================================================================
  -- GMC SIERRA 2500 HD (2,519 users)
  -- =========================================================================
  STRUCT('GMC', 'SIERRA 2500 HD', 2001, 2006, '1st Gen'),
  STRUCT('GMC', 'SIERRA 2500 HD', 2007, 2014, '2nd Gen'),
  STRUCT('GMC', 'SIERRA 2500 HD', 2015, 2019, '3rd Gen'),
  STRUCT('GMC', 'SIERRA 2500 HD', 2020, 2024, '4th Gen'),

  -- =========================================================================
  -- FORD F-350 SUPER DUTY (2,198 users)
  -- =========================================================================
  STRUCT('FORD', 'F-350 SUPER DUTY', 1999, 2007, '1st Gen'),
  STRUCT('FORD', 'F-350 SUPER DUTY', 2008, 2010, '2nd Gen'),
  STRUCT('FORD', 'F-350 SUPER DUTY', 2011, 2016, '3rd Gen'),
  STRUCT('FORD', 'F-350 SUPER DUTY', 2017, 2024, '4th Gen'),

  -- =========================================================================
  -- CHEVROLET K1500 (2,180 users)
  -- =========================================================================
  STRUCT('CHEVROLET', 'K1500', 1988, 1998, 'GMT400'),
  STRUCT('CHEVROLET', 'K1500', 1999, 2000, 'GMT400 (Final)'),

  -- =========================================================================
  -- CHRYSLER 300 (2,169 users)
  -- =========================================================================
  STRUCT('CHRYSLER', '300', 2005, 2010, '1st Gen (LX)'),
  STRUCT('CHRYSLER', '300', 2011, 2024, '2nd Gen (LD)'),

  -- =========================================================================
  -- CHEVROLET BLAZER (2,012 users)
  -- =========================================================================
  STRUCT('CHEVROLET', 'BLAZER', 1969, 1972, '1st Gen (K5)'),
  STRUCT('CHEVROLET', 'BLAZER', 1973, 1991, '2nd Gen (K5)'),
  STRUCT('CHEVROLET', 'BLAZER', 1983, 1994, 'S-10 Blazer'),
  STRUCT('CHEVROLET', 'BLAZER', 1995, 2005, '2nd Gen S-10'),
  STRUCT('CHEVROLET', 'BLAZER', 2019, 2024, '3rd Gen'),

  -- =========================================================================
  -- FORD FAIRLANE (1,956 users)
  -- =========================================================================
  STRUCT('FORD', 'FAIRLANE', 1955, 1956, '1st Gen'),
  STRUCT('FORD', 'FAIRLANE', 1957, 1959, '2nd Gen'),
  STRUCT('FORD', 'FAIRLANE', 1960, 1961, '3rd Gen'),
  STRUCT('FORD', 'FAIRLANE', 1962, 1965, '4th Gen (Intermediate)'),
  STRUCT('FORD', 'FAIRLANE', 1966, 1967, '5th Gen'),
  STRUCT('FORD', 'FAIRLANE', 1968, 1969, '6th Gen'),
  STRUCT('FORD', 'FAIRLANE', 1970, 1970, '7th Gen'),

  -- =========================================================================
  -- GMC SIERRA (1,856 users) - Generic
  -- =========================================================================
  STRUCT('GMC', 'SIERRA', 1988, 1998, 'GMT400'),
  STRUCT('GMC', 'SIERRA', 1999, 2006, 'GMT800'),
  STRUCT('GMC', 'SIERRA', 2007, 2013, 'GMT900'),
  STRUCT('GMC', 'SIERRA', 2014, 2018, 'K2XX'),
  STRUCT('GMC', 'SIERRA', 2019, 2024, 'T1XX'),

  -- =========================================================================
  -- DODGE DAKOTA (1,796 users)
  -- =========================================================================
  STRUCT('DODGE', 'DAKOTA', 1987, 1996, '1st Gen'),
  STRUCT('DODGE', 'DAKOTA', 1997, 2004, '2nd Gen'),
  STRUCT('DODGE', 'DAKOTA', 2005, 2011, '3rd Gen'),

  -- =========================================================================
  -- FORD FALCON (1,794 users)
  -- =========================================================================
  STRUCT('FORD', 'FALCON', 1960, 1963, '1st Gen'),
  STRUCT('FORD', 'FALCON', 1964, 1965, '2nd Gen'),
  STRUCT('FORD', 'FALCON', 1966, 1970, '3rd Gen'),

  -- =========================================================================
  -- RAM 2500 (1,791 users)
  -- =========================================================================
  STRUCT('RAM', '2500', 2009, 2018, '4th Gen'),
  STRUCT('RAM', '2500', 2019, 2024, '5th Gen'),

  -- =========================================================================
  -- DODGE DART (1,740 users)
  -- =========================================================================
  STRUCT('DODGE', 'DART', 1960, 1961, '1st Gen'),
  STRUCT('DODGE', 'DART', 1963, 1966, '2nd Gen (A-body)'),
  STRUCT('DODGE', 'DART', 1967, 1976, '3rd Gen (A-body)'),
  STRUCT('DODGE', 'DART', 2013, 2016, '4th Gen (PF)'),

  -- =========================================================================
  -- DODGE DURANGO (1,672 users)
  -- =========================================================================
  STRUCT('DODGE', 'DURANGO', 1998, 2003, '1st Gen'),
  STRUCT('DODGE', 'DURANGO', 2004, 2009, '2nd Gen'),
  STRUCT('DODGE', 'DURANGO', 2011, 2024, '3rd Gen'),

  -- =========================================================================
  -- CHEVROLET CAPRICE (1,617 users)
  -- =========================================================================
  STRUCT('CHEVROLET', 'CAPRICE', 1965, 1970, '1st Gen'),
  STRUCT('CHEVROLET', 'CAPRICE', 1971, 1976, '2nd Gen'),
  STRUCT('CHEVROLET', 'CAPRICE', 1977, 1990, '3rd Gen'),
  STRUCT('CHEVROLET', 'CAPRICE', 1991, 1996, '4th Gen'),

  -- =========================================================================
  -- OLDSMOBILE CUTLASS SUPREME (1,598 users)
  -- =========================================================================
  STRUCT('OLDSMOBILE', 'CUTLASS SUPREME', 1966, 1972, '1st Gen (A-body)'),
  STRUCT('OLDSMOBILE', 'CUTLASS SUPREME', 1973, 1977, '2nd Gen (A-body)'),
  STRUCT('OLDSMOBILE', 'CUTLASS SUPREME', 1978, 1988, '3rd Gen (G-body)'),
  STRUCT('OLDSMOBILE', 'CUTLASS SUPREME', 1988, 1997, '4th Gen (W-body)'),

  -- =========================================================================
  -- TOYOTA TACOMA (1,497 users)
  -- =========================================================================
  STRUCT('TOYOTA', 'TACOMA', 1995, 2004, '1st Gen'),
  STRUCT('TOYOTA', 'TACOMA', 2005, 2015, '2nd Gen'),
  STRUCT('TOYOTA', 'TACOMA', 2016, 2024, '3rd Gen'),

  -- =========================================================================
  -- FORD THUNDERBIRD (1,473 users)
  -- =========================================================================
  STRUCT('FORD', 'THUNDERBIRD', 1955, 1957, '1st Gen'),
  STRUCT('FORD', 'THUNDERBIRD', 1958, 1960, '2nd Gen'),
  STRUCT('FORD', 'THUNDERBIRD', 1961, 1963, '3rd Gen'),
  STRUCT('FORD', 'THUNDERBIRD', 1964, 1966, '4th Gen'),
  STRUCT('FORD', 'THUNDERBIRD', 1967, 1971, '5th Gen'),
  STRUCT('FORD', 'THUNDERBIRD', 1972, 1976, '6th Gen'),
  STRUCT('FORD', 'THUNDERBIRD', 1977, 1979, '7th Gen'),
  STRUCT('FORD', 'THUNDERBIRD', 1980, 1982, '8th Gen'),
  STRUCT('FORD', 'THUNDERBIRD', 1983, 1988, '9th Gen'),
  STRUCT('FORD', 'THUNDERBIRD', 1989, 1997, '10th Gen'),
  STRUCT('FORD', 'THUNDERBIRD', 2002, 2005, '11th Gen (Retro)'),

  -- =========================================================================
  -- MERCURY COUGAR (1,472 users)
  -- =========================================================================
  STRUCT('MERCURY', 'COUGAR', 1967, 1970, '1st Gen'),
  STRUCT('MERCURY', 'COUGAR', 1971, 1973, '2nd Gen'),
  STRUCT('MERCURY', 'COUGAR', 1974, 1976, '3rd Gen'),
  STRUCT('MERCURY', 'COUGAR', 1977, 1979, '4th Gen'),
  STRUCT('MERCURY', 'COUGAR', 1980, 1982, '5th Gen'),
  STRUCT('MERCURY', 'COUGAR', 1983, 1988, '6th Gen'),
  STRUCT('MERCURY', 'COUGAR', 1989, 1997, '7th Gen'),
  STRUCT('MERCURY', 'COUGAR', 1999, 2002, '8th Gen'),

  -- =========================================================================
  -- GMC YUKON (1,426 users)
  -- =========================================================================
  STRUCT('GMC', 'YUKON', 1992, 1999, '1st Gen (GMT400)'),
  STRUCT('GMC', 'YUKON', 2000, 2006, '2nd Gen (GMT800)'),
  STRUCT('GMC', 'YUKON', 2007, 2014, '3rd Gen (GMT900)'),
  STRUCT('GMC', 'YUKON', 2015, 2020, '4th Gen (K2XX)'),
  STRUCT('GMC', 'YUKON', 2021, 2024, '5th Gen (T1XX)'),

  -- =========================================================================
  -- BUICK REGAL (1,334 users)
  -- =========================================================================
  STRUCT('BUICK', 'REGAL', 1973, 1977, '1st Gen (A-body)'),
  STRUCT('BUICK', 'REGAL', 1978, 1987, '2nd Gen (G-body)'),
  STRUCT('BUICK', 'REGAL', 1988, 1996, '3rd Gen (W-body)'),
  STRUCT('BUICK', 'REGAL', 1997, 2004, '4th Gen (W-body)'),
  STRUCT('BUICK', 'REGAL', 2011, 2017, '5th Gen'),
  STRUCT('BUICK', 'REGAL', 2018, 2020, '6th Gen'),

  -- =========================================================================
  -- JEEP CJ7 (1,317 users)
  -- =========================================================================
  STRUCT('JEEP', 'CJ7', 1976, 1986, 'CJ7'),

  -- =========================================================================
  -- JEEP CHEROKEE (1,312 users)
  -- =========================================================================
  STRUCT('JEEP', 'CHEROKEE', 1974, 1983, 'SJ'),
  STRUCT('JEEP', 'CHEROKEE', 1984, 2001, 'XJ'),
  STRUCT('JEEP', 'CHEROKEE', 2002, 2007, 'KJ Liberty'),
  STRUCT('JEEP', 'CHEROKEE', 2008, 2012, 'KK Liberty'),
  STRUCT('JEEP', 'CHEROKEE', 2014, 2024, 'KL'),

  -- =========================================================================
  -- FORD EXPLORER (1,266 users)
  -- =========================================================================
  STRUCT('FORD', 'EXPLORER', 1991, 1994, '1st Gen'),
  STRUCT('FORD', 'EXPLORER', 1995, 2001, '2nd Gen'),
  STRUCT('FORD', 'EXPLORER', 2002, 2005, '3rd Gen'),
  STRUCT('FORD', 'EXPLORER', 2006, 2010, '4th Gen'),
  STRUCT('FORD', 'EXPLORER', 2011, 2019, '5th Gen'),
  STRUCT('FORD', 'EXPLORER', 2020, 2024, '6th Gen'),

  -- =========================================================================
  -- CHEVROLET TWO-TEN SERIES (1,253 users) - 1950s classic
  -- =========================================================================
  STRUCT('CHEVROLET', 'TWO-TEN SERIES', 1953, 1954, '1st Gen'),
  STRUCT('CHEVROLET', 'TWO-TEN SERIES', 1955, 1957, '2nd Gen (Tri-Five)')

]) AS gen
;

-- Verify table creation
SELECT make, model, COUNT(*) as generations
FROM `auxia-reporting.temp_holley_v5_8.vehicle_generations`
GROUP BY 1, 2
ORDER BY 2 DESC
LIMIT 20;
