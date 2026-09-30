"""
MedLogTrack dashboard — a read-only Streamlit front end over the analytical
views/functions defined in queries/. No writes, no business logic duplicated
here: every number on screen comes straight from a view or function that
already exists in the database, so this file is presentation only.

Run:
    streamlit run dashboard/app.py

Configure the connection with environment variables (all optional, shown
with their defaults):
    MEDLOGTRACK_HOST=localhost
    MEDLOGTRACK_PORT=5432
    MEDLOGTRACK_DB=medlogtrack
    MEDLOGTRACK_USER=postgres
    MEDLOGTRACK_PASSWORD=(empty)
"""

import os

import pandas as pd
import plotly.express as px
import psycopg2
import streamlit as st

st.set_page_config(page_title="MedLogTrack", layout="wide")


@st.cache_resource
def get_connection():
    return psycopg2.connect(
        host=os.environ.get("MEDLOGTRACK_HOST", "localhost"),
        port=os.environ.get("MEDLOGTRACK_PORT", "5432"),
        dbname=os.environ.get("MEDLOGTRACK_DB", "medlogtrack"),
        user=os.environ.get("MEDLOGTRACK_USER", "postgres"),
        password=os.environ.get("MEDLOGTRACK_PASSWORD", ""),
    )


@st.cache_data(ttl=60)
def run_query(sql, params=None):
    with get_connection() as conn:
        return pd.read_sql(sql, conn, params=params)


st.title("MedLogTrack")
st.caption(
    "Read-only dashboard over the MedLogTrack PostgreSQL schema — every "
    "number below comes directly from a view or function in queries/."
)

facilities = run_query("SELECT facility_id, name FROM facilities WHERE is_active ORDER BY name")
facility_options = ["All facilities"] + facilities["name"].tolist()

tab_overview, tab_low_stock, tab_expiration, tab_vendors, tab_trends, tab_waste = st.tabs(
    ["Overview", "Low Stock", "Expiration Risk", "Vendor Scorecard", "Demand Trends", "Waste Analysis"]
)

# -----------------------------------------------------------------------------
# Overview
# -----------------------------------------------------------------------------
with tab_overview:
    col1, col2, col3, col4 = st.columns(4)

    low_stock_count = run_query("SELECT COUNT(*) AS n FROM vw_low_stock_alert")["n"][0]
    expiring_count = run_query(
        "SELECT COUNT(*) AS n FROM inventory_lots WHERE expiration_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 30"
    )["n"][0]
    open_requisitions = run_query(
        "SELECT COUNT(*) AS n FROM requisitions WHERE status IN ('submitted', 'approved', 'partially_fulfilled')"
    )["n"][0]
    total_waste_value = run_query("SELECT COALESCE(SUM(total_waste_value), 0) AS v FROM vw_waste_analysis")["v"][0]

    col1.metric("Items below reorder point", int(low_stock_count))
    col2.metric("Lots expiring in 30 days", int(expiring_count))
    col3.metric("Open requisitions", int(open_requisitions))
    col4.metric("Total waste value (lifetime)", f"${total_waste_value:,.0f}")

    st.subheader("Spend by category")
    rollup = run_query(
        "SELECT category_name, depth, total_spend_incl_subcategories "
        "FROM vw_category_spend_rollup WHERE depth = 0 ORDER BY total_spend_incl_subcategories DESC"
    )
    fig = px.bar(rollup, x="category_name", y="total_spend_incl_subcategories",
                 labels={"category_name": "Category", "total_spend_incl_subcategories": "Total spend ($)"})
    st.plotly_chart(fig, use_container_width=True)

# -----------------------------------------------------------------------------
# Low stock
# -----------------------------------------------------------------------------
with tab_low_stock:
    st.subheader("Items below reorder point")
    chosen = st.selectbox("Facility", facility_options, key="low_stock_facility")
    query = "SELECT facility_name, item_name, quantity_on_hand, reorder_point, days_of_supply_30, recommended_reorder_qty FROM vw_low_stock_alert"
    if chosen != "All facilities":
        query += " WHERE facility_name = %(facility)s"
        df = run_query(query + " ORDER BY days_of_supply_30 NULLS LAST", {"facility": chosen})
    else:
        df = run_query(query + " ORDER BY days_of_supply_30 NULLS LAST")
    st.dataframe(df, use_container_width=True, hide_index=True)

# -----------------------------------------------------------------------------
# Expiration risk
# -----------------------------------------------------------------------------
with tab_expiration:
    st.subheader("Expiration risk")
    window = st.slider("Window (days)", min_value=7, max_value=120, value=30, step=7)
    df = run_query(f"SELECT * FROM fn_expiration_risk({int(window)})")
    st.dataframe(
        df[["facility_name", "item_name", "quantity_on_hand", "expiration_date",
            "days_until_expiration", "fefo_rank", "recommended_action"]],
        use_container_width=True, hide_index=True,
    )

# -----------------------------------------------------------------------------
# Vendor scorecard
# -----------------------------------------------------------------------------
with tab_vendors:
    st.subheader("Vendor performance scorecard")
    df = run_query("SELECT * FROM vw_vendor_scorecard ORDER BY rank_by_on_time_pct")
    fig = px.bar(df.sort_values("on_time_fulfillment_pct"), x="on_time_fulfillment_pct", y="supplier_name",
                 orientation="h", labels={"on_time_fulfillment_pct": "On-time fulfillment %", "supplier_name": "Supplier"},
                 color="on_time_fulfillment_pct", color_continuous_scale="RdYlGn")
    st.plotly_chart(fig, use_container_width=True)
    st.dataframe(
        df[["supplier_name", "contracted_lead_time_days", "avg_actual_lead_time_days",
            "on_time_fulfillment_pct", "fill_rate_pct", "rank_by_on_time_pct"]],
        use_container_width=True, hide_index=True,
    )

# -----------------------------------------------------------------------------
# Demand trends
# -----------------------------------------------------------------------------
with tab_trends:
    st.subheader("Demand trend for an item")
    items = run_query("SELECT DISTINCT item_name FROM vw_demand_trend ORDER BY item_name")
    default_idx = (
        items["item_name"].tolist().index("Influenza Vaccine, Quadrivalent Single-Dose Vial")
        if "Influenza Vaccine, Quadrivalent Single-Dose Vial" in items["item_name"].tolist() else 0
    )
    item_name = st.selectbox("Item", items["item_name"], index=default_idx)
    df = run_query(
        "SELECT usage_month, total_quantity, moving_avg_3mo FROM vw_demand_trend "
        "WHERE item_name = %(item)s ORDER BY usage_month",
        {"item": item_name},
    )
    fig = px.line(df, x="usage_month", y=["total_quantity", "moving_avg_3mo"],
                  labels={"usage_month": "Month", "value": "Units", "variable": "Series"})
    st.plotly_chart(fig, use_container_width=True)

    st.subheader("Items trending up sharply (reorder-point increase candidates)")
    alerts = run_query("SELECT * FROM vw_demand_trend_alerts")
    st.dataframe(alerts, use_container_width=True, hide_index=True)

# -----------------------------------------------------------------------------
# Waste analysis
# -----------------------------------------------------------------------------
with tab_waste:
    st.subheader("Waste value by facility and category")
    df = run_query("SELECT * FROM vw_waste_analysis")
    fig = px.treemap(df, path=["facility_name", "category_name"], values="total_waste_value",
                      title="Waste value ($) by facility -> category")
    st.plotly_chart(fig, use_container_width=True)

    st.subheader("Top wasted items")
    by_item = run_query("SELECT * FROM vw_waste_by_item LIMIT 20")
    st.dataframe(by_item, use_container_width=True, hide_index=True)
