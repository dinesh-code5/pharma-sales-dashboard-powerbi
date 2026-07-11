-- ============================================================
-- PHARMA SALES DASHBOARD — STAR SCHEMA BUILD SCRIPT (MySQL)
-- Source: pharma-data.csv (Datamatrix pharma, distributor sales)
-- ============================================================

CREATE DATABASE IF NOT EXISTS pharma_sales;
USE pharma_sales;

-- ------------------------------------------------------------
-- STEP 1: STAGING TABLE — mirrors the raw CSV exactly
-- ------------------------------------------------------------
DROP TABLE IF EXISTS staging_sales;
CREATE TABLE staging_sales (
    row_id            INT AUTO_INCREMENT PRIMARY KEY,
    distributor       VARCHAR(100),
    customer_name     VARCHAR(150),
    city              VARCHAR(100),
    country           VARCHAR(100),
    latitude          DECIMAL(9,6),
    longitude         DECIMAL(9,6),
    channel           VARCHAR(50),
    sub_channel       VARCHAR(50),
    product_name      VARCHAR(150),
    product_class     VARCHAR(100),
    quantity          INT,
    price             DECIMAL(10,2),
    sales             DECIMAL(12,2),
    sales_month       INT,
    sales_year        INT,
    sales_rep_name    VARCHAR(100),
    manager_name      VARCHAR(100),
    sales_team        VARCHAR(100)
);

-- ------------------------------------------------------------
-- STEP 2: LOAD THE CSV
-- Adjust the file path to wherever you saved pharma-data.csv.
-- On Windows use double backslashes or forward slashes.
-- 'LOCAL' requires --local-infile=1 enabled on your MySQL client.
-- ------------------------------------------------------------
-- LOAD DATA LOCAL INFILE 'C:/Users/YOU/Desktop/placement-dashboard/pharma-data.csv'
-- INTO TABLE staging_sales
-- FIELDS TERMINATED BY ','
-- OPTIONALLY ENCLOSED BY '"'
-- LINES TERMINATED BY '\n'
-- IGNORE 1 ROWS
-- (distributor, customer_name, city, country, latitude, longitude, channel,
--  sub_channel, product_name, product_class, quantity, price, sales,
--  sales_month, sales_year, sales_rep_name, manager_name, sales_team);

-- If LOAD DATA is blocked by your MySQL security settings, use
-- MySQL Workbench's "Table Data Import Wizard" instead — same result, GUI-based.

-- ------------------------------------------------------------
-- STEP 3: DATA QUALITY CHECKS (run these before building dims)
-- ------------------------------------------------------------
SELECT COUNT(*) AS total_rows FROM staging_sales;
SELECT COUNT(*) AS null_sales FROM staging_sales WHERE sales IS NULL;
SELECT COUNT(*) AS negative_sales FROM staging_sales WHERE sales < 0;
SELECT MIN(sales_year) AS min_year, MAX(sales_year) AS max_year FROM staging_sales;

-- Negative sales usually represent returns/reversals in pharma distributor data.
-- Decision: keep them (they're valid business events) but flag with a transaction_type
-- column so KPIs can choose to include/exclude returns. Handled in fact table below.

-- ------------------------------------------------------------
-- STEP 4: DIMENSION TABLES
-- ------------------------------------------------------------

DROP TABLE IF EXISTS dim_date;
CREATE TABLE dim_date (
    date_id     INT PRIMARY KEY AUTO_INCREMENT,
    sales_year  INT,
    sales_month INT,
    month_name  VARCHAR(15),
    quarter     INT,
    UNIQUE KEY uq_year_month (sales_year, sales_month)
);

INSERT INTO dim_date (sales_year, sales_month, month_name, quarter)
SELECT DISTINCT
    sales_year,
    sales_month,
    MONTHNAME(STR_TO_DATE(sales_month, '%m')),
    QUARTER(STR_TO_DATE(sales_month, '%m'))
FROM staging_sales
WHERE sales_year IS NOT NULL AND sales_month IS NOT NULL;

DROP TABLE IF EXISTS dim_product;
CREATE TABLE dim_product (
    product_id     INT PRIMARY KEY AUTO_INCREMENT,
    product_name   VARCHAR(150),
    product_class  VARCHAR(100),
    UNIQUE KEY uq_product (product_name)
);

INSERT INTO dim_product (product_name, product_class)
SELECT DISTINCT product_name, product_class
FROM staging_sales
WHERE product_name IS NOT NULL;

DROP TABLE IF EXISTS dim_customer;
CREATE TABLE dim_customer (
    customer_id   INT PRIMARY KEY AUTO_INCREMENT,
    customer_name VARCHAR(150),
    city          VARCHAR(100),
    country       VARCHAR(100),
    latitude      DECIMAL(9,6),
    longitude     DECIMAL(9,6),
    channel       VARCHAR(50),
    sub_channel   VARCHAR(50),
    distributor   VARCHAR(100),
    UNIQUE KEY uq_customer (customer_name, city)
);

INSERT INTO dim_customer (customer_name, city, country, latitude, longitude, channel, sub_channel, distributor)
SELECT DISTINCT customer_name, city, country, latitude, longitude, channel, sub_channel, distributor
FROM staging_sales
WHERE customer_name IS NOT NULL;

DROP TABLE IF EXISTS dim_salesrep;
CREATE TABLE dim_salesrep (
    rep_id       INT PRIMARY KEY AUTO_INCREMENT,
    rep_name     VARCHAR(100),
    manager_name VARCHAR(100),
    sales_team   VARCHAR(100),
    UNIQUE KEY uq_rep (rep_name)
);

INSERT INTO dim_salesrep (rep_name, manager_name, sales_team)
SELECT DISTINCT sales_rep_name, manager_name, sales_team
FROM staging_sales
WHERE sales_rep_name IS NOT NULL;

-- ------------------------------------------------------------
-- STEP 5: FACT TABLE — one row per transaction, all FKs resolved
-- ------------------------------------------------------------
DROP TABLE IF EXISTS fact_sales;
CREATE TABLE fact_sales (
    sales_id        INT PRIMARY KEY AUTO_INCREMENT,
    date_id         INT,
    product_id      INT,
    customer_id     INT,
    rep_id          INT,
    quantity        INT,
    price           DECIMAL(10,2),
    sales_value     DECIMAL(12,2),
    transaction_type VARCHAR(10),
    FOREIGN KEY (date_id) REFERENCES dim_date(date_id),
    FOREIGN KEY (product_id) REFERENCES dim_product(product_id),
    FOREIGN KEY (customer_id) REFERENCES dim_customer(customer_id),
    FOREIGN KEY (rep_id) REFERENCES dim_salesrep(rep_id)
);

INSERT INTO fact_sales (date_id, product_id, customer_id, rep_id, quantity, price, sales_value, transaction_type)
SELECT
    d.date_id,
    p.product_id,
    c.customer_id,
    r.rep_id,
    s.quantity,
    s.price,
    s.sales,
    CASE WHEN s.sales < 0 THEN 'Return' ELSE 'Sale' END
FROM staging_sales s
JOIN dim_date d      ON s.sales_year = d.sales_year AND s.sales_month = d.sales_month
JOIN dim_product p   ON s.product_name = p.product_name
JOIN dim_customer c  ON s.customer_name = c.customer_name AND s.city = c.city
JOIN dim_salesrep r  ON s.sales_rep_name = r.rep_name;

-- ------------------------------------------------------------
-- STEP 6: SANITY CHECK — row counts should roughly match
-- ------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM staging_sales) AS staging_rows,
    (SELECT COUNT(*) FROM fact_sales)    AS fact_rows;

-- ------------------------------------------------------------
-- STEP 7: A FEW QUERIES YOU CAN QUOTE IN INTERVIEWS
-- (these mirror the DAX measures we'll build in Power BI next)
-- ------------------------------------------------------------

-- Total sales and YoY growth by year
SELECT
    d.sales_year,
    SUM(f.sales_value) AS total_sales
FROM fact_sales f
JOIN dim_date d ON f.date_id = d.date_id
GROUP BY d.sales_year
ORDER BY d.sales_year;

-- Top 5 sales reps by achievement (needs a target table later — placeholder using rank by sales)
SELECT
    r.rep_name,
    r.sales_team,
    SUM(f.sales_value) AS total_sales
FROM fact_sales f
JOIN dim_salesrep r ON f.rep_id = r.rep_id
GROUP BY r.rep_name, r.sales_team
ORDER BY total_sales DESC
LIMIT 5;

-- Sales by channel and sub-channel
SELECT
    c.channel,
    c.sub_channel,
    SUM(f.sales_value) AS total_sales,
    COUNT(*) AS transaction_count
FROM fact_sales f
JOIN dim_customer c ON f.customer_id = c.customer_id
GROUP BY c.channel, c.sub_channel
ORDER BY total_sales DESC;
