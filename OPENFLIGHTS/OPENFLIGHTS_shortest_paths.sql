/************************************/
-- This script demonstrates the use of SAP HANA Graph features, especially shortest path queries.
-- It was developed on SAP HANA Cloud version 4.00.000.00.1600157276 (2020 Q3).
-- You can run the example on a SAP HANA Cloud Trial using a SQL Editor, e.g. SAP HANA Database Explorer
-- For getting started with SAP HANA Cloud trial, see  https://developers.sap.com/tutorials/hana-trial-advanced-analytics.html

-- this script has 4 parts:
-- 1 create tables, graph workspace, and procedures
-- 2 load data from flat files into the tables (or just use some dummy data)
-- 3 data transformations, e.g. point geometries are created from LAT/LON coordinates
-- 4 run queries

/************************************/
-- 1 create tables
/************************************/
--DROP SCHEMA "HANA_GRAPH_1" CASCADE;
CREATE SCHEMA "HANA_GRAPH_1";
SET SCHEMA "HANA_GRAPH_1";

-- The "IMP_*" tables are used to import the OPENFLIGHTS data later in the script
CREATE COLUMN TABLE "IMP_AIRPORTS" (
	"ID" BIGINT,
	"NAME" NVARCHAR(5000),
	"CITY" NVARCHAR(5000),
	"COUNTRY" NVARCHAR(5000),
	"IATA" NVARCHAR(5000),
	"ICAO" NVARCHAR(5000),
	"LAT" DOUBLE,
	"LON" DOUBLE,
	"ALT" INT,
	"TIMEZONE" NVARCHAR(5000),
	"DST" NVARCHAR(5000),
	"TZ" NVARCHAR(5000),
	"TYPE" NVARCHAR(5000),
	"SOURCE" NVARCHAR(5000),
	PRIMARY KEY ("ID")
);

CREATE COLUMN TABLE "IMP_ROUTES" (
	"AIRLINE" NVARCHAR(5000),
	"AIRLINE_ID" NVARCHAR(5000),
	"SOURCE_AIRPORT" NVARCHAR(5000),
	"SOURCE_AIRPORT_ID" NVARCHAR(5000) NOT NULL ,
	"DESTINATION_AIRPORT" NVARCHAR(5000),
	"DESTINATION_AIRPORT_ID" NVARCHAR(5000) NOT NULL ,
	"CODESHARE" NVARCHAR(5000),
	"STOPS" INTEGER,
	"EQUIPMENT" NVARCHAR(5000)
);

-- During the data transformation step (3) we will copy the data from the IMP_* tables into the OPENFLIGHTS_* tables
CREATE COLUMN TABLE "OPENFLIGHTS_VERTICES" (
	"ID" BIGINT,
	"NAME" NVARCHAR(5000),
	"CITY" NVARCHAR(5000),
	"COUNTRY" NVARCHAR(5000),
	"IATA" NVARCHAR(5000),
	"ICAO" NVARCHAR(5000),
	"LAT" DOUBLE,
	"LON" DOUBLE,
	"ALT" INT,
	"TIMEZONE" NVARCHAR(5000),
	"DST" NVARCHAR(5000),
	"TZ" NVARCHAR(5000),
	"TYPE" NVARCHAR(5000),
	"SOURCE" NVARCHAR(5000),
	"SHAPE_4326" ST_GEOMETRY(4326),
	PRIMARY KEY ("ID")
);

CREATE COLUMN TABLE "OPENFLIGHTS_EDGES" (
	"ID" BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
	"SOURCE_AIRPORT" NVARCHAR(5000),
	"SOURCE_AIRPORT_ID" BIGINT NOT NULL ,
	"DESTINATION_AIRPORT" NVARCHAR(5000),
	"DESTINATION_AIRPORT_ID" BIGINT NOT NULL ,
	"SHAPE_4326" ST_GEOMETRY(4326),
	"DIST_KM" DOUBLE,
	"NUMBER_OF_AIRLINES" INT
);


/************************************/
-- Create the graph workspace. The workspace exposes you data to the Graph engine. You can think of it as a "view".
CREATE GRAPH WORKSPACE "OPENFLIGHTS_GRAPH"
	EDGE TABLE "OPENFLIGHTS_EDGES"
		SOURCE COLUMN "SOURCE_AIRPORT_ID"
		TARGET COLUMN "DESTINATION_AIRPORT_ID"
		KEY COLUMN "ID"
	VERTEX TABLE "OPENFLIGHTS_VERTICES"
		KEY COLUMN "ID";

/************************************/
-- Create the table types for the procedures
CREATE TYPE "TT_OPENFLIGHTS_VERTICES_SPOO" AS TABLE ("ID" BIGINT, "NAME" NVARCHAR(5000), "VERTEX_ORDER" BIGINT);
CREATE TYPE "TT_OPENFLIGHTS_EDGES_SPOO" AS TABLE("ID" BIGINT,"SOURCE_AIRPORT_ID" BIGINT,"DESTINATION_AIRPORT_ID" BIGINT, "DIST_KM" DOUBLE,"ORD" BIGINT);
CREATE TYPE "TT_OPENFLIGHTS_VERTICES_SPOA" AS TABLE ("ID" BIGINT, "SUM_DIST_KM" DOUBLE);
CREATE TYPE "TT_OPENFLIGHTS_EDGES_SPOA" AS TABLE("ID" BIGINT,"SOURCE_AIRPORT_ID" BIGINT,"DESTINATION_AIRPORT_ID" BIGINT,"DIST_KM" DOUBLE);
CREATE TYPE "TT_OPENFLIGHTS_PATHS_TKSP" AS TABLE ("PATH_ID" INT,"PATH_LENGTH" BIGINT,"PATH_WEIGHT" DOUBLE,"EDGE_ID" BIGINT, "EDGE_ORDER" INT);

/************************************/
-- Create the procedures - there are three of them:
-- A Shortest Path One-to-One (with four variants)
-- B Shortest Path One-to-All
-- C Top K Shortest Paths

-- (A) Shortest Path One-to-One
-- The procedure contains four usage variants of the built-in shortest path function - see lines 129-146.
-- Just add/remove the comments -- or /* */
CREATE OR REPLACE PROCEDURE "OPENFLIGHTS_SHORTEST_PATH_ONE_TO_ONE"(
	IN i_startVertex BIGINT, 		-- the ID of the start vertex
	IN i_endVertex BIGINT, 			-- the ID of the end vertex
	IN i_direction NVARCHAR(10), 	-- the direction of the edge traversal: OUTGOING (default), INCOMING, ANY
	IN i_maxSegmentDistance DOUBLE,	-- optional, for variant 3 it defines th max distance of a single route segment
	OUT o_path_length BIGINT,		-- the hop distance between start and end
	OUT o_path_weight DOUBLE,		-- the path weight based on the DIST_KM attribute
	OUT o_vertices "TT_OPENFLIGHTS_VERTICES_SPOO",
	OUT o_edges "TT_OPENFLIGHTS_EDGES_SPOO"
	)
LANGUAGE GRAPH READS SQL DATA AS
BEGIN
	-- Create an instance of the graph, refering to the graph workspace object
	GRAPH g = Graph("OPENFLIGHTS_GRAPH");
	-- Check if vertices exist
	IF (NOT VERTEX_EXISTS(:g, :i_startVertex) OR NOT VERTEX_EXISTS(:g, :i_endVertex)) {
		o_path_length = 0L;
		o_path_weight = 0.0;
		return;
	}
	-- Create an instance of the start/end vertex
	VERTEX v_start = Vertex(:g, :i_startVertex);
	VERTEX v_end = Vertex(:g, :i_endVertex);

	-- Variant 1 - Running shortest path using hop distance
	--WeightedPath<BIGINT> p = Shortest_Path(:g, :v_start, :v_end, :i_direction);

	-- Variant 2 - Running shortest path using the DIST_KM column as cost
	WeightedPath<DOUBLE> p = Shortest_Path(:g, :v_start, :v_end, (Edge e) => DOUBLE{ return :e."DIST_KM"; }, :i_direction);

	-- Variant 3 - Running shortest path using the DIST_KM column as cost and an additional stop condition: only take routes which are <= i_max_SegmentDistance
	/*WeightedPath<DOUBLE> p = Shortest_Path(:g, :v_start, :v_end,
		(EDGE e)=> DOUBLE{
  			IF(:e."DIST_KM" <= :i_maxSegmentDistance) { return :e."DIST_KM"; }
            ELSE { END TRAVERSE; }
  		},
	:i_direction);*/

	-- Variant 4 - Running shortest path using the DIST_KM column as cost and an additional stop condition based on the current/partial path length
	/*WeightedPath<DOUBLE> p = Shortest_Path(:g, :v_start, :v_end,
		(EDGE e, DOUBLE current_path_length)=> DOUBLE{
  			IF(:e."DIST_KM" > :current_path_length) { return :e."DIST_KM"; }
            ELSE { END TRAVERSE; }
  		},
	:i_direction);*/

	-- Project the results from the path
	o_path_length = LENGTH(:p);
	o_path_weight = DOUBLE(WEIGHT(:p));
	o_vertices = SELECT :v."ID", :v."NAME", :VERTEX_ORDER FOREACH v IN Vertices(:p) WITH ORDINALITY AS VERTEX_ORDER;
	o_edges = SELECT :e."ID", :e."SOURCE_AIRPORT_ID", :e."DESTINATION_AIRPORT_ID", :e."DIST_KM", :EDGE_ORDER FOREACH e IN Edges(:p) WITH ORDINALITY AS EDGE_ORDER;
END;

-- (B) Shortest Path One-to-All
CREATE OR REPLACE PROCEDURE "OPENFLIGHTS_SHORTEST_PATH_ONE_TO_ALL"(
	IN i_startVertex BIGINT, 		-- the key of the start vertex
	IN i_direction NVARCHAR(10), 	-- the direction of the edge traversal: OUTGOING (default), INCOMING, ANY
	OUT o_vertices "TT_OPENFLIGHTS_VERTICES_SPOA",
	OUT o_edges "TT_OPENFLIGHTS_EDGES_SPOA"
	)
LANGUAGE GRAPH READS SQL DATA AS
BEGIN
	-- Create an instance of the graph, refering to the graph workspace object
	GRAPH g = Graph("OPENFLIGHTS_GRAPH");
	-- Create an instance of the start vertex
	VERTEX v_start = Vertex(:g, :i_startVertex);
	-- Running shortest paths one to all, which returns a subgraph. The WEIGHT based path length to a vertex is stored in the attribute SUM_DIST_KM
	GRAPH g_spoa = SHORTEST_PATHS_ONE_TO_ALL(:g, :v_start, "SUM_DIST_KM", (Edge e) => DOUBLE{ return :e."DIST_KM"; }, :i_direction);
	o_vertices = SELECT :v."ID", :v."SUM_DIST_KM" FOREACH v IN Vertices(:g_spoa);
	o_edges = SELECT :e."ID", :e."SOURCE_AIRPORT_ID", :e."DESTINATION_AIRPORT_ID", :e."DIST_KM" FOREACH e IN Edges(:g_spoa);
END;

-- (C) Top k Shortest Path
CREATE PROCEDURE "OPENFLIGHTS_TOP_K_SHORTEST_PATH"(
	IN i_startVertex BIGINT, 	-- the key of the start vertex
	IN i_endVertex BIGINT, 		-- the key of the end vertex
	IN i_k INT, 				-- the number of paths to be returned
	OUT o_paths "TT_OPENFLIGHTS_PATHS_TKSP"
	)
LANGUAGE GRAPH READS SQL DATA AS
BEGIN
	-- Create an instance of the graph, refering to the graph workspace object
	GRAPH g = Graph("OPENFLIGHTS_GRAPH");
	-- Create an instance of the start/end vertex
	VERTEX v_start = Vertex(:g, :i_startVertex);
	VERTEX v_end = Vertex(:g, :i_endVertex);
	-- Running top k shortest paths using the WEIGHT column as cost
	SEQUENCE<WeightedPath<DOUBLE>> s_paths = K_Shortest_Paths(:g, :v_start, :v_end, :i_k, (Edge e) => DOUBLE{ return :e."DIST_KM"; });
	-- Project result paths into a table
	BIGINT currentResultRow = 1L;
	FOREACH result_path IN (:s_paths) WITH ORDINALITY AS path_id {
		FOREACH path_edge in EDGES(:result_path) WITH ORDINALITY AS edge_order {
			o_paths."PATH_ID"[:currentResultRow] = INTEGER(:path_id);
			o_paths."PATH_LENGTH"[:currentResultRow] = Length(:result_path);
			o_paths."PATH_WEIGHT"[:currentResultRow] = Weight(:result_path);
			o_paths."EDGE_ID"[:currentResultRow] = :path_edge."ID";
			o_paths."EDGE_ORDER"[:currentResultRow] = INTEGER(:edge_order);
			currentResultRow = :currentResultRow + 1L;
		}
	}
END;

/************************************/
-- 2 load data
/************************************/
-- You can either import the data from flat files (A) or just work with some minimum dummy data (B)

-- (A) You can download the airports and routes data from https://openflights.org/data.html
-- Rename the .dat files to .csv
-- Import the data with the flat file import wizard in SAP HANA Database Explorer
-- https://help.sap.com/viewer/a2cea64fa3ac4f90a52405d07600047b/cloud/en-US/ee0e1389fde345fa8ccf937f19c99c30.html
-- Right-click the IMP_AIRPORTS/IMP_ROUTES table and choose "import data", point to the appropriate flat file and complete the wizard.
-- In step 1 of the wizard, uncheck "files has header in the first row".
-- In setp 2, just map the columns one-by-on. The order of columns in the flat file is the same as in the database table.

-- (B) if you don't want to import the OPENFLIGHTS data, you can also create some dummy data:
INSERT INTO "OPENFLIGHTS_VERTICES" ("ID","NAME","CITY","COUNTRY") VALUES (999998,'Walldorf Airport','Walldorf','Germany');
INSERT INTO "OPENFLIGHTS_VERTICES" ("ID","NAME","CITY","COUNTRY") VALUES (999999,'Wiesloch Airport','Wiesloch','Germany');
INSERT INTO "OPENFLIGHTS_EDGES" ("ID","SOURCE_AIRPORT","SOURCE_AIRPORT_ID","DESTINATION_AIRPORT","DESTINATION_AIRPORT_ID","SHAPE_4326","DIST_KM","NUMBER_OF_AIRLINES")
	VALUES (999999,NULL,999999,NULL,999998,NULL,5,0);




/************************************/
-- 3 data transformation
/************************************/
-- The airports data contains LON/LAT values to describe the locations of the airports.
-- We'll make a geometry out of it.
SELECT *, ST_GEOMFROMTEXT('POINT('|| LON ||' '|| LAT ||')', 4326) AS SHAPE_4326
	FROM "IMP_AIRPORTS"
	INTO "OPENFLIGHTS_VERTICES";

-- We'll enrich the routes data by a line geometry and the length of this line which is later used as a distance measure to calculate shortest paths.
SELECT "SOURCE_AIRPORT", A1."ID" AS "SOURCE_AIRPORT_ID", "DESTINATION_AIRPORT", A2."ID" AS "DESTINATION_AIRPORT_ID",
	ST_MAKELINE(A1.SHAPE_4326, A2.SHAPE_4326) AS SHAPE_4326, ST_MAKELINE(A1.SHAPE_4326, A2.SHAPE_4326).ST_LENGTH('kilometer') AS "DIST_KM", "NUMBER_OF_AIRLINES"
	FROM (
		SELECT "SOURCE_AIRPORT", "DESTINATION_AIRPORT", COUNT(DISTINCT AIRLINE_ID) AS "NUMBER_OF_AIRLINES"
		FROM "IMP_ROUTES" AS R
		GROUP BY "SOURCE_AIRPORT", "SOURCE_AIRPORT_ID", "DESTINATION_AIRPORT", "DESTINATION_AIRPORT_ID"
	) AS R
	INNER JOIN "OPENFLIGHTS_VERTICES" AS A1 ON R.SOURCE_AIRPORT = A1.IATA
	INNER JOIN "OPENFLIGHTS_VERTICES" AS A2 ON R.DESTINATION_AIRPORT = A2.IATA
	WHERE A1.IATA != A2.IATA
	INTO "OPENFLIGHTS_EDGES"("SOURCE_AIRPORT", "SOURCE_AIRPORT_ID", "DESTINATION_AIRPORT", "DESTINATION_AIRPORT_ID", "SHAPE_4326", "DIST_KM", "NUMBER_OF_AIRLINES");

/************************************/
-- 4 calling the procedures
/************************************/
-- If you have imported the OPENFLIGHTS data (step 2A), run the following statements.
-- If you work with the minimal dummy data (step 2B), see the very end of this script.

-- Shortest Path One-to-One
-- Input: source airport id, target airport id, edge traversal direction OUTGOING/INCOMING/ANY, optional: the maximum segment length)
-- Output: table with the vertices that make up the path, table with the paths' edges, the number of hops, the distance (km) of the path
-- Let's go from Goroka Airport (1) to Barcelona (1218) via the shortest route.
CALL "OPENFLIGHTS_SHORTEST_PATH_ONE_TO_ONE"(1, 1218, 'ANY', 1500, ?, ?, ?, ?);
-- Make sure to try out the other variants - go back to the definition of the OPENFLIGHTS_SHORTEST_PATH_ONE_TO_ONE procedure (line 106)
-- and comment out the line below "Variant 2" (line 132), comment in the multiple lines below "Variant 3" or "Variant 4" be removing /* */
-- Re-create the procedure and run the CALL statement above.
-- Variant 3 returns a route in which each segment is shorter than 1500 (km).
-- Variant 4 returns a route in which each segment is longer than the sum of its predecessors.

-- Shortest Path One-to-All
-- Returns the distances from Barcelona (1218) to all other airports, as well as all edges that are in at least one shortest path.
CALL "OPENFLIGHTS_SHORTEST_PATH_ONE_TO_ALL"(1218, 'ANY', ?, ?);

-- Top k Shortest Paths
-- Returns multiple paths identified by PATH_ID
CALL "OPENFLIGHTS_TOP_K_SHORTEST_PATH"(i_startVertex => 1, i_endVertex => 1218, i_k => 3, o_paths => ?);


-- If you are working with the minimal dummy data (step 2B), you can run these queries
CALL "OPENFLIGHTS_SHORTEST_PATH_ONE_TO_ONE"(999999, 999998, 'ANY', NULL, ?, ?, ?, ?);
CALL "OPENFLIGHTS_SHORTEST_PATH_ONE_TO_ALL"(999999, 'ANY', ?, ?);
CALL "OPENFLIGHTS_TOP_K_SHORTEST_PATH"(i_startVertex => 999999, i_endVertex => 999998, i_k => 2, o_paths => ?);
