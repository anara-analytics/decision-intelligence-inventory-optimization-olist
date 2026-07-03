# Decision Intelligence System for Inventory & Profit Optimization in E-commerce SMEs (Olist Dataset)

## Executive Summary

This project presents an end-to-end Decision Intelligence System designed to optimize inventory management and profitability for e-commerce SMEs using the Olist dataset.

Unlike traditional business intelligence dashboards that focus only on historical reporting, this system integrates forecasting, optimization, and rule-based decision-making to generate actionable operational recommendations.

The system answers critical business questions such as:
- What products should be reordered?
- Which SKUs should be reduced or discontinued?
- Where is revenue at risk due to stockouts?
- How much working capital can be optimized?

The goal is to demonstrate how data-driven decision systems can improve operational efficiency, reduce inventory waste, and increase profitability in small and medium-sized e-commerce businesses.

---

## Business Problem

E-commerce SMEs often face inefficiencies in inventory management due to:

- Lack of demand forecasting capabilities
- Overstocking of low-performing SKUs
- Stockouts of high-demand products
- Poor visibility into SKU-level profitability
- Reactive rather than proactive decision-making

These inefficiencies lead to:
- Lost sales due to stockouts
- Excess inventory holding costs
- Reduced cash flow efficiency
- Suboptimal product portfolio management

This project addresses these challenges by building a structured analytical system that transforms transactional data into forward-looking inventory decisions.

---

## Solution Overview

The system is designed as a multi-layer analytical architecture:

### 1. Data Layer
- Olist e-commerce dataset (orders, products, customers, reviews)
- Structured into relational and analytical tables

### 2. Forecasting Layer
- SKU-level demand forecasting
- Trend analysis and seasonality detection
- Forecast accuracy evaluation (MAE, MAPE)
- Confidence scoring for predictions

### 3. Decision Engine Layer
A rule-based system that classifies each SKU into:

- Reorder Now
- Hold
- Reduce Stock
- Discontinue

Based on:
- Forecast demand
- Safety stock levels
- Reorder points
- Profitability thresholds
- Demand variability

### 4. Business Intelligence Layer
- Power BI dashboards for executive decision-making
- KPI tracking (revenue, profit, risk, opportunity)
- Scenario analysis and what-if parameters

---

## Data Sources

The project uses the publicly available **Olist e-commerce dataset**, which includes:

- Orders and order items
- Product catalog
- Customer data
- Review scores
- Shipping and delivery information

---

## Methodology

### Data Engineering Layer
- Data cleaning and transformation using SQL
- Dimensional modeling (star schema design)
- Creation of fact and dimension tables

### Forecasting Layer
- Time-series based demand forecasting at SKU level
- Error metrics:
  - MAE (Mean Absolute Error)
  - MAPE (Mean Absolute Percentage Error)
- Confidence scoring for forecast reliability

### Inventory Optimization Layer
- Safety stock calculation
- Lead time demand estimation
- Reorder point modeling:
  > Reorder Point = Lead Time Demand + Safety Stock

### Decision Engine Layer
Rule-based classification system:
- Discontinue: low demand + low margin
- Reorder: stock below reorder point
- Reduce Stock: excess inventory above threshold
- Hold: stable SKUs within optimal range

---

## Key Features

- SKU-level demand forecasting system
- Inventory optimization using safety stock modeling
- Automated decision engine for inventory actions
- Financial risk quantification (sales at risk, capital at risk)
- Interactive scenario simulation (what-if analysis)
- Business impact measurement framework

---

## Business Impact

The system provides measurable insights including:

- $358K+ in estimated sales protected
- $375K+ total identified opportunity
- Inventory optimization across 596 SKUs
- Reduction of stockout risk through predictive ordering
- Identification of non-performing SKUs for discontinuation

These insights demonstrate how data-driven decision systems can improve operational efficiency in e-commerce businesses.

---

## Technical Stack

- SQL (Data modeling & transformation)
- PostgreSQL
- Power BI
- DAX (business logic & KPIs)
- Excel (support modeling)
- Forecasting techniques (time-series analysis)
- Dimensional data modeling (star schema)

---

## Data Model

The system follows a star schema design:

- Fact tables:
  - monthly_sku_performance
  - forecast_results
  - decision_input

- Dimension tables:
  - dim_product
  - dim_category
  - dim_date

---

## Decision Logic

Inventory decisions are based on structured business rules:

- Discontinue:
  Forecast demand < threshold AND margin < minimum margin

- Reorder:
  Current stock ≤ Reorder Point

- Reduce Stock:
  Current stock > Overstock threshold

- Hold:
  All other conditions

---

## Screenshots

### Executive Dashboard


### Forecasting & Accuracy


### Decision Engine


### Reorder Worklist


### Business Impact


### Data Model


---

## How to Run This Project

1. Clone repository
2. Load Olist dataset into PostgreSQL
3. Run SQL scripts for data modeling
4. Open Power BI file (.pbix)
5. Refresh data source connection
6. Explore dashboards and decision engine

---

## Key Learnings

- Translating raw transactional data into decision systems
- Designing inventory optimization logic using forecasting outputs
- Building scalable analytical architecture
- Connecting analytics with financial and operational impact
- Communicating complex models in business-friendly dashboards

---

## Future Enhancements

This system is designed as a scalable Decision Intelligence framework for SME inventory optimization and can be extended in the following directions:

- Integration of machine learning-based forecasting models (e.g., XGBoost, Prophet, LSTM) to improve demand prediction accuracy
- Real-time inventory tracking and monitoring system for dynamic stock updates
- Supplier lead time variability modeling and optimization for improved reorder planning
- Profit maximization engine integrating pricing, demand elasticity, and margin optimization
- API-based deployment of the decision engine for integration with ERP and e-commerce platforms
