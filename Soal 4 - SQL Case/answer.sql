-- Test Case 1

SELECT CAST(DATE_TRUNC('month', CAST(OrderDate as Date)) AS Date) AS order_month, --Read OrderDate as a date; change all of it to the first day of every month.
        COUNT (*) AS total_orders, --Assuming one header row represents one order
        COUNT(DISTINCT (CustomerID)) AS unique_customers, --Each CustomerID identifies each customer.
        ROUND(SUM (SubTotal), 2) AS total_revenue, --SubTotal column as total revenue
        ROUND(AVG (SubTotal), 2) AS avg_order_value, --The average SubTotal per order.
        ROUND(100 * AVG(CASE WHEN OnlineOrderFlag THEN 1 ELSE 0 END), 2) AS online_order_pct --TRUE OR 1 means online; NULL values (if any) will be considered as offline.
FROM sales_order_header
WHERE CAST(OrderDate AS DATE) >= '2013-01-01' AND CAST(OrderDate AS DATE) < '2014-01-01' --Only includes 2013 year.
GROUP BY order_month --Produce one row per month.
ORDER BY order_month; --Order it by the order months.

--Business Insights:
--June had the highest revenue in 2013 (5.081.069,13) with 719 orders.
--November had the most orders (2.103), but revenue was lower than June (3.312.130,25).
--The lower revenue in November was caused by the lower average order value (1.574,95 in November versus 7.066,86 in June)

-- Test Case 2

WITH subcategory_sales AS ( --Create a CTE
    SELECT pc.Name AS category, --Get the category name from product_category table. Sales without a matching category will show NULL.
        ps.Name as subcategory, --Get the subcategory name from product_subcategory table. Sales without a matching subcategory will show NULL.
        COUNT(DISTINCT(d.ProductID)) AS products_sold, --Count different products sold in the group from the sales_detail table.
        SUM(d.OrderQTY) as units_sold, --Add the quantities sold from the sales_detail table.
        SUM(d.LineTotal) as total_revenue --Add revenue from the sales_detail table.
    FROM sales_order_detail d --Start with the sales_detail table.
    LEFT JOIN production_product p ON d.ProductID = p.ProductID --Joining the sales_detail table with production_product table. Assume one product row per ProductID; keep unmatched sales.
    LEFT JOIN production_subcategory ps ON p.ProductSubcategoryID = ps.ProductSubcategoryID --Joining the production_product table with the production_subcategory table. Assume one row per subcategory ID.
    LEFT JOIN production_category pc ON ps.ProductCategoryID = pc.ProductCategoryID --Joining the production_subcategory table with the production_category table. Assume one row per category ID.
    GROUP BY category, subcategory --Make one row per category/subcategory pair.
)

SELECT category, subcategory, products_sold, units_sold, ROUND(total_revenue, 2) AS total_revenue,
    ROUND(100 * total_revenue / SUM(total_revenue) OVER (PARTITION BY category), 2) as pct_of_category_revenue --Calculating contribution percentage for each category's total revenue.
FROM subcategory_sales --Use the CTE
ORDER BY category, total_revenue DESC; --Sort subcategories by revenue within each category

--Business Insights:
-- Road Bikes had the highest subcategory revenue overall: 43,909,437.51, or 46.39% of Bikes revenue.
-- Road Bikes and Mountain Bikes together generated 84.90% of Bikes revenue, showing that revenue in this category is concentrated in these two subcategories.

-- Test Case 3

WITH months AS ( --Create the months needed for the comparison.
    SELECT CAST(month_value AS DATE) AS order_month --Use the first day of each month.
    FROM generate_series(DATE '2012-12-01', DATE '2013-12-01', INTERVAL '1 month')
        AS month_list(month_value) --Include December 2012 for January's comparison.
),

monthly_sales AS ( --Calculate actual monthly revenue.
    SELECT h.TerritoryID, --Use the territory recorded on each order.
        CAST(DATE_TRUNC('month', CAST(h.OrderDate AS DATE)) AS DATE) AS order_month, --Group orders by month.
        SUM(h.SubTotal) AS revenue --Assume SubTotal is order revenue, as in Test Case 1.
    FROM sales_order_header h --Start with one row per order.
    WHERE CAST(h.OrderDate AS DATE) >= DATE '2012-12-01' --Include December 2012.
        AND CAST(h.OrderDate AS DATE) < DATE '2014-01-01' --Include all of 2013.
    GROUP BY h.TerritoryID, order_month --Make one row per territory and month.
),

all_months AS ( --Include months even when a territory had no orders.
    SELECT t.TerritoryID, --Assume each TerritoryID appears once in sales_territory.
        t.Name AS territory, --Get the territory name.
        m.order_month, --Get the month from the month list.
        COALESCE(s.revenue, 0) AS revenue --Assume a month without orders has zero revenue.
    FROM sales_territory t --Report listed territories; exclude orders with NULL or unmatched TerritoryID.
    CROSS JOIN months m --Make one row for every territory and month.
    LEFT JOIN monthly_sales s ON t.TerritoryID = s.TerritoryID --Keep months without matching sales.
        AND m.order_month = s.order_month --Match sales from the same month.
),

previous_month AS ( --Find the previous month's revenue.
    SELECT TerritoryID, territory, order_month, revenue, --Keep the values calculated above.
        LAG(revenue) OVER (
            PARTITION BY TerritoryID ORDER BY order_month
        ) AS prev_month_revenue --Look at the preceding month within the same territory.
    FROM all_months --December 2012 is still included here.
)

SELECT territory, --Show the territory name.
    order_month, --Show the first day of the month.
    ROUND(revenue, 2) AS revenue, --Show this month's revenue.
    ROUND(prev_month_revenue, 2) AS prev_month_revenue, --Show the previous month's revenue.
    CASE WHEN prev_month_revenue = 0 THEN NULL --Growth from zero is undefined.
        ELSE ROUND(100.0 * (revenue - prev_month_revenue) / prev_month_revenue, 2) --Calculate percentage change.
    END AS mom_growth_pct,
    ROUND(SUM(revenue) OVER (
        PARTITION BY TerritoryID ORDER BY order_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), 2) AS running_total --2013 year-to-date: add revenue from January through this month.
FROM previous_month --Use the monthly revenue and previous-month values.
WHERE order_month >= DATE '2013-01-01' --Show 2013 only; January already has December's previous value.
    AND order_month < DATE '2014-01-01' --Stop after December 2013.
ORDER BY territory, order_month; --Sort by territory and month.

-- Business Insights:
-- Southwest had the highest 2013 territory revenue at 9,116,540.31.
-- Its highest-revenue month was July, at 967,044.60.
-- France's monthly revenue rose from 151,472.53 in May to 800,815.33 in June (+428.69%), then fell to 281,399.89 in July (-64.86%).

-- Test Case 4

WITH customer_orders AS ( --Create one row for each customer before grouping them into cohorts.
    SELECT h.CustomerID, --Identify the customer.
        YEAR(MIN(CAST(h.OrderDate AS DATE))) AS cohort_year, --Use the year of their first recorded order.
        CASE WHEN c.StoreID IS NOT NULL THEN 'Store'
             ELSE 'Individual' END AS customer_type, --A customer linked to a store is a Store.
        COUNT(*) AS order_count, --Assume each header row is one order.
        SUM(h.SubTotal) AS lifetime_revenue --Add all orders available for this customer in the dataset.
    FROM sales_order_header h --Start with customers who have at least one recorded order.
    JOIN sales_customer c ON h.CustomerID = c.CustomerID --Assume each CustomerID appears once in sales_customer.
    GROUP BY h.CustomerID, c.StoreID --Produce one row per customer.
)

SELECT cohort_year, --Group customers by their first-order year.
    customer_type, --Separate Store and Individual customers.
    COUNT(*) AS customers, --Count customers in this cohort and type.
    SUM(CASE WHEN order_count >= 2 THEN 1 ELSE 0 END) AS repeat_customers, --Count customers with at least two orders.
    ROUND(100.0 * SUM(CASE WHEN order_count >= 2 THEN 1 ELSE 0 END) / COUNT(*), 2) AS repeat_rate_pct, --Repeat customers as a percentage of customers.
    ROUND(AVG(order_count), 2) AS avg_orders_per_customer, --Average recorded orders per customer.
    ROUND(AVG(lifetime_revenue), 2) AS avg_lifetime_revenue --Average recorded revenue per customer.
FROM customer_orders --Use the one-row-per-customer results.
GROUP BY cohort_year, customer_type --Produce one row for each cohort and customer type.
ORDER BY cohort_year, customer_type; --Show cohorts in year order.

-- Business Insights:
-- Stores were 635 of 19,119 purchasing customers (3.3%) but generated approximately 73% of observed lifetime revenue.
-- In the 2013 cohort, Stores had a 93.27% repeat rate versus 33.92% for Individuals; their average lifetime revenue was 71,681.81 versus 981.22.
-- The 2014 cohort has had less time to place repeat orders, and it contains only four Stores. Its 0% Store repeat rate should not be treated as a retention trend.