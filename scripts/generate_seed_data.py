#!/usr/bin/env python3
"""
MedLogTrack seed data generator.

Generates a realistic ~18-month history of facilities, suppliers, catalog
items, inventory lots, requisitions, and usage transactions, and writes it
out as a single seed_data.sql file of plain INSERT statements (no DB driver
required to generate or to load — just `psql -f seed_data.sql`).

Deterministic: re-running this script with the same SEED produces byte-
identical output, which matters for a portfolio repo (the committed
seed_data.sql should match what this script produces).

Usage:
    python scripts/generate_seed_data.py
"""

import random
from datetime import date, timedelta
from pathlib import Path

SEED = 42
random.seed(SEED)

TODAY = date(2026, 9, 30)  # generation anchor date; see README for why this matters
HISTORY_MONTHS = 18
HISTORY_START = date(TODAY.year, TODAY.month, 1) - timedelta(days=int(30.44 * HISTORY_MONTHS))

OUT_PATH = Path(__file__).resolve().parent.parent / "seed_data.sql"

# =============================================================================
# SQL helpers
# =============================================================================

def sql_str(v):
    if v is None:
        return "NULL"
    return "'" + str(v).replace("'", "''") + "'"


def sql_val(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, date):
        return f"'{v.isoformat()}'"
    return sql_str(v)


def insert_stmt(table, columns, rows, batch_size=500):
    """Yield multi-row INSERT statements for `rows` (list of tuples aligned to columns)."""
    if not rows:
        return
    col_list = ", ".join(columns)
    for i in range(0, len(rows), batch_size):
        chunk = rows[i:i + batch_size]
        values_lines = []
        for row in chunk:
            values_lines.append("  (" + ", ".join(sql_val(v) for v in row) + ")")
        yield f"INSERT INTO {table} ({col_list}) VALUES\n" + ",\n".join(values_lines) + ";\n"


def random_date(start: date, end: date) -> date:
    delta = (end - start).days
    if delta <= 0:
        return start
    return start + timedelta(days=random.randint(0, delta))


out = []  # list of SQL statement strings, in dependency order


def section(title):
    out.append(f"\n-- =============================================================================\n-- {title}\n-- =============================================================================\n")


# =============================================================================
# 1. Facilities
# =============================================================================
section("Facilities")

FACILITIES = [
    ("Wright-Patterson Medical Center", "Dayton, OH", "CONUS-Central", "Medical Center"),
    ("Wilford Hall Ambulatory Surgical Center", "JBSA-Lackland, TX", "CONUS-Central", "Ambulatory Care Clinic"),
    ("David Grant USAF Medical Center", "Travis AFB, CA", "CONUS-West", "Medical Center"),
    ("Malcolm Grow Medical Clinic", "JB Andrews, MD", "CONUS-East", "Medical Clinic"),
    ("Mike O'Callaghan Military Medical Center", "Nellis AFB, NV", "CONUS-West", "Hospital"),
    ("Eglin AFB Hospital", "Eglin AFB, FL", "CONUS-East", "Hospital"),
    ("Landstuhl Regional Medical Annex", "Ramstein AB, Germany", "USAFE", "Hospital"),
    ("Kadena AB Medical Clinic", "Kadena AB, Okinawa, Japan", "PACAF", "Medical Clinic"),
]
for _, _, _, ft in FACILITIES:
    assert ft in ("Medical Center", "Hospital", "Ambulatory Care Clinic", "Medical Clinic", "Dental Clinic")

out.extend(insert_stmt(
    "facilities", ["name", "location", "region", "facility_type"],
    [(n, l, r, t) for n, l, r, t in FACILITIES]
))
FACILITY_IDS = list(range(1, len(FACILITIES) + 1))

# =============================================================================
# 2. Suppliers
# =============================================================================
section("Suppliers")

# Fictional vendor names (deliberately not real distributors) — see README.
SUPPLIERS = [
    ("Apex Federal Medical Supply", 7, 4.3),
    ("Cardinal Point Distribution", 5, 4.6),
    ("Meridian Healthcare Logistics", 10, 3.8),
    ("Sentinel Medical-Surgical", 6, 4.1),
    ("Beacon Biomedical Supply", 12, 3.5),
    ("TrueNorth Pharma Distribution", 4, 4.7),
    ("Vanguard Medical Systems", 8, 4.0),
    ("Coastal Federal Health Supply", 9, 3.9),
    ("Summit Surgical & Medical", 6, 4.2),
    ("Ironbridge Government Solutions", 7, 2.4),   # deliberate edge case: chronically late (see below)
    ("Crestline Healthcare Distribution", 5, 4.4),
    ("Pinnacle Federal Pharma", 6, 4.3),
    ("Harborview Medical Logistics", 11, 3.6),
    ("Redstone Biomedical Supply", 8, 3.9),
    ("Whitfield Medical-Surgical Distribution", 7, 4.1),
]
out.extend(insert_stmt(
    "suppliers", ["name", "contracted_lead_time_days", "reliability_rating",
                  "contact_name", "contact_email", "contact_phone"],
    [(n, lt, rr,
      "Vendor Account Rep",
      n.lower().replace(" ", ".").replace("&", "and") + "@example-vendor.com",
      f"1-800-555-{1000 + i:04d}")
     for i, (n, lt, rr) in enumerate(SUPPLIERS)]
))
SUPPLIER_IDS = list(range(1, len(SUPPLIERS) + 1))
LATE_SUPPLIER_ID = 10  # Ironbridge Government Solutions
SUPPLIER_ROWS_BY_ID = {
    i + 1: {"name": n, "contracted_lead_time_days": lt, "reliability_rating": rr}
    for i, (n, lt, rr) in enumerate(SUPPLIERS)
}

# =============================================================================
# 3. Item categories (self-referencing hierarchy, 25 total)
# =============================================================================
section("Item categories")

# (name, parent_name_or_None)
CATEGORY_TREE = [
    ("Pharmaceuticals", None),
    ("Antibiotics", "Pharmaceuticals"),
    ("Analgesics & NSAIDs", "Pharmaceuticals"),
    ("Vaccines & Immunizations", "Pharmaceuticals"),
    ("Cardiovascular Medications", "Pharmaceuticals"),
    ("Respiratory Medications", "Pharmaceuticals"),
    ("IV Fluids & Electrolytes", "Pharmaceuticals"),

    ("Consumables", None),
    ("Wound Care & Dressings", "Consumables"),
    ("Syringes & Needles", "Consumables"),
    ("PPE & Barrier Protection", "Consumables"),
    ("Diagnostic Test Kits", "Consumables"),
    ("Sutures & Surgical Supplies", "Consumables"),
    ("Trauma & Hemorrhage Control", "Consumables"),
    ("Sterilization Supplies", "Consumables"),

    ("Durable Medical Equipment", None),
    ("Monitoring Equipment", "Durable Medical Equipment"),
    ("Diagnostic Imaging Accessories", "Durable Medical Equipment"),
    ("Mobility & Transport Equipment", "Durable Medical Equipment"),
    ("Resuscitation Equipment", "Durable Medical Equipment"),
    ("Sterilization Equipment", "Durable Medical Equipment"),

    ("Controlled Substances", None),
    ("Schedule II Analgesics", "Controlled Substances"),
    ("Schedule III-V Medications", "Controlled Substances"),
    ("Anesthetics", "Controlled Substances"),
]
assert len(CATEGORY_TREE) == 25, len(CATEGORY_TREE)

CATEGORY_ID = {}          # name -> id
_next_cat_id = 1
cat_rows = []
for name, parent in CATEGORY_TREE:
    CATEGORY_ID[name] = _next_cat_id
    parent_id = CATEGORY_ID[parent] if parent else None
    cat_rows.append((name, parent_id, f"{name} and related items"))
    _next_cat_id += 1

out.extend(insert_stmt(
    "item_categories", ["category_name", "parent_category_id", "description"],
    cat_rows
))

# =============================================================================
# 4. Supply items (150 total)
# =============================================================================
section("Supply items")

# Each template: (item_name, category, unit_of_issue, unit_cost, is_expiration_tracked,
#                  shelf_life_days or None, usage_tier)
# usage_tier drives both requisition demand and usage_transactions frequency:
#   'high'    -> fast-moving consumable, issued several times a week per facility
#   'medium'  -> issued roughly weekly per facility
#   'low'     -> issued a few times a month per facility
#   'rare'    -> durable equipment / low-turnover, a handful of events over 18 months
ITEM_TEMPLATES = []

def add_items(category, base_name, unit, cost, expiration_tracked, shelf_life_days, tier, variants):
    for suffix in variants:
        ITEM_TEMPLATES.append((f"{base_name} {suffix}".strip(), category, unit, cost,
                                expiration_tracked, shelf_life_days, tier))

# --- Antibiotics ---
add_items("Antibiotics", "Amoxicillin 500mg", "BT", 9.75, True, 540, "high", ["Capsule Bottle-100ct"])
add_items("Antibiotics", "Azithromycin 250mg", "BT", 14.20, True, 540, "medium", ["Tablet Bottle-30ct"])
add_items("Antibiotics", "Ciprofloxacin 500mg", "BT", 11.10, True, 540, "medium", ["Tablet Bottle-30ct"])
add_items("Antibiotics", "Doxycycline 100mg", "BT", 8.60, True, 730, "medium", ["Capsule Bottle-60ct"])
add_items("Antibiotics", "Cephalexin 500mg", "BT", 10.40, True, 540, "low", ["Capsule Bottle-30ct"])
add_items("Antibiotics", "Clindamycin 300mg", "BT", 16.75, True, 540, "low", ["Capsule Bottle-30ct"])
add_items("Antibiotics", "Vancomycin 1g Injection", "VI", 22.50, True, 365, "low", ["Vial"])

# --- Analgesics & NSAIDs ---
add_items("Analgesics & NSAIDs", "Ibuprofen 200mg", "BT", 4.25, True, 900, "high", ["Tablet Bottle-100ct"])
add_items("Analgesics & NSAIDs", "Acetaminophen 500mg", "BT", 3.90, True, 900, "high", ["Tablet Bottle-100ct"])
add_items("Analgesics & NSAIDs", "Naproxen 500mg", "BT", 6.15, True, 900, "medium", ["Tablet Bottle-60ct"])
add_items("Analgesics & NSAIDs", "Meloxicam 15mg", "BT", 7.40, True, 730, "low", ["Tablet Bottle-30ct"])
add_items("Analgesics & NSAIDs", "Diclofenac Gel 1%", "TU", 9.85, True, 730, "low", ["Tube-100g"])

# --- Vaccines & Immunizations ---
add_items("Vaccines & Immunizations", "Influenza Vaccine, Quadrivalent", "VI", 18.90, True, 240, "seasonal", ["Single-Dose Vial"])
add_items("Vaccines & Immunizations", "Tetanus-Diphtheria (Td) Vaccine", "VI", 21.30, True, 540, "low", ["Single-Dose Vial"])
add_items("Vaccines & Immunizations", "Hepatitis B Vaccine", "VI", 34.60, True, 540, "low", ["Single-Dose Vial"])
add_items("Vaccines & Immunizations", "MMR Vaccine", "VI", 28.75, True, 365, "low", ["Single-Dose Vial"])
add_items("Vaccines & Immunizations", "Meningococcal Vaccine", "VI", 112.00, True, 540, "rare", ["Single-Dose Vial"])

# --- Cardiovascular Medications ---
add_items("Cardiovascular Medications", "Lisinopril 10mg", "BT", 5.20, True, 730, "medium", ["Tablet Bottle-30ct"])
add_items("Cardiovascular Medications", "Atorvastatin 20mg", "BT", 6.80, True, 730, "medium", ["Tablet Bottle-30ct"])
add_items("Cardiovascular Medications", "Metoprolol 50mg", "BT", 5.95, True, 730, "low", ["Tablet Bottle-30ct"])
add_items("Cardiovascular Medications", "Aspirin 81mg", "BT", 2.75, True, 900, "high", ["Tablet Bottle-100ct"])
add_items("Cardiovascular Medications", "Epinephrine 1mg/mL Injection", "AM", 19.40, True, 450, "low", ["Ampule"])

# --- Respiratory Medications ---
add_items("Respiratory Medications", "Albuterol Inhaler 90mcg", "EA", 24.50, True, 450, "medium", ["Inhaler"])
add_items("Respiratory Medications", "Fluticasone Nasal Spray", "EA", 17.80, True, 450, "low", ["Spray Bottle"])
add_items("Respiratory Medications", "Diphenhydramine 25mg", "BT", 3.60, True, 900, "medium", ["Capsule Bottle-100ct"])
add_items("Respiratory Medications", "Oseltamivir (Tamiflu) 75mg", "BT", 62.00, True, 540, "seasonal", ["Capsule Bottle-10ct"])

# --- IV Fluids & Electrolytes ---
add_items("IV Fluids & Electrolytes", "Normal Saline 0.9% 1000mL", "BG", 4.10, True, 730, "high", ["IV Bag"])
add_items("IV Fluids & Electrolytes", "Lactated Ringer's 1000mL", "BG", 4.35, True, 730, "medium", ["IV Bag"])
add_items("IV Fluids & Electrolytes", "Dextrose 5% in Water 500mL", "BG", 3.95, True, 730, "low", ["IV Bag"])
add_items("IV Fluids & Electrolytes", "Potassium Chloride 20mEq Additive", "VI", 2.85, True, 900, "low", ["Vial"])

# --- Wound Care & Dressings ---
add_items("Wound Care & Dressings", "Gauze Pad 4x4in Sterile", "BX", 6.50, True, 1095, "high", ["Box-200ct"])
add_items("Wound Care & Dressings", "Elastic Bandage Wrap 4in", "EA", 2.10, True, 1095, "high", ["Roll"])
add_items("Wound Care & Dressings", "Adhesive Bandage Strips", "BX", 4.75, True, 1095, "medium", ["Box-100ct"])
add_items("Wound Care & Dressings", "Transparent Film Dressing", "BX", 12.90, True, 1095, "medium", ["Box-50ct"])
add_items("Wound Care & Dressings", "Non-Adherent Pad 3x4in", "BX", 8.20, True, 1095, "medium", ["Box-100ct"])
add_items("Wound Care & Dressings", "Occlusive Chest Seal", "EA", 14.60, False, None, "low", ["Vented Seal"])

# --- Syringes & Needles ---
add_items("Syringes & Needles", "Syringe 3mL Luer-Lock", "BX", 9.40, False, None, "high", ["Box-100ct"])
add_items("Syringes & Needles", "Syringe 10mL Luer-Lock", "BX", 11.75, False, None, "medium", ["Box-100ct"])
add_items("Syringes & Needles", "Hypodermic Needle 21G x 1in", "BX", 7.60, False, None, "high", ["Box-100ct"])
add_items("Syringes & Needles", "IV Catheter 18G", "BX", 22.30, False, None, "medium", ["Box-50ct"])
add_items("Syringes & Needles", "Blood Collection Tube, EDTA", "BX", 15.80, True, 730, "medium", ["Box-100ct"])

# --- PPE & Barrier Protection ---
add_items("PPE & Barrier Protection", "Nitrile Exam Gloves, Medium", "BX", 8.90, False, None, "high", ["Box-100ct"])
add_items("PPE & Barrier Protection", "Nitrile Exam Gloves, Large", "BX", 8.90, False, None, "high", ["Box-100ct"])
add_items("PPE & Barrier Protection", "Surgical Face Mask", "BX", 5.40, False, None, "high", ["Box-50ct"])
add_items("PPE & Barrier Protection", "N95 Respirator Mask", "BX", 24.90, False, None, "medium", ["Box-20ct"])
add_items("PPE & Barrier Protection", "Isolation Gown, Disposable", "BX", 32.50, False, None, "medium", ["Box-10ct"])
add_items("PPE & Barrier Protection", "Face Shield, Disposable", "BX", 18.70, False, None, "low", ["Box-25ct"])

# --- Diagnostic Test Kits ---
add_items("Diagnostic Test Kits", "Rapid Strep Test Kit", "BX", 45.00, True, 540, "medium", ["Box-25ct"])
add_items("Diagnostic Test Kits", "Rapid Influenza Test Kit", "BX", 58.00, True, 450, "seasonal", ["Box-25ct"])
add_items("Diagnostic Test Kits", "COVID-19 Antigen Test Kit", "BX", 62.50, True, 450, "medium", ["Box-25ct"])
add_items("Diagnostic Test Kits", "Urinalysis Reagent Strips", "BT", 19.20, True, 730, "low", ["Bottle-100ct"])
add_items("Diagnostic Test Kits", "Glucose Test Strips", "BX", 27.40, True, 730, "medium", ["Box-50ct"])

# --- Sutures & Surgical Supplies ---
add_items("Sutures & Surgical Supplies", "Suture Kit, Nylon 4-0", "BX", 6.30, True, 1095, "medium", ["Box-12ct"])
add_items("Sutures & Surgical Supplies", "Suture Kit, Vicryl 3-0", "BX", 7.85, True, 1095, "low", ["Box-12ct"])
add_items("Sutures & Surgical Supplies", "Scalpel, Disposable #10", "BX", 14.50, False, None, "low", ["Box-10ct"])
add_items("Sutures & Surgical Supplies", "Surgical Drape, Sterile", "BX", 28.90, True, 1460, "low", ["Box-25ct"])

# --- Trauma & Hemorrhage Control ---
add_items("Trauma & Hemorrhage Control", "Combat Application Tourniquet (CAT)", "EA", 32.00, False, None, "medium", ["Gen 7"])
add_items("Trauma & Hemorrhage Control", "Hemostatic Gauze, Combat Gauze", "EA", 45.50, True, 1095, "medium", ["Roll"])
add_items("Trauma & Hemorrhage Control", "Israeli Battle Dressing", "EA", 11.20, False, None, "medium", ["6in"])
add_items("Trauma & Hemorrhage Control", "Trauma Shears", "EA", 8.40, False, None, "low", ["7.25in"])

# --- Sterilization Supplies ---
add_items("Sterilization Supplies", "Sterilization Pouch, Self-Seal", "BX", 21.60, False, None, "medium", ["Box-200ct"])
add_items("Sterilization Supplies", "Chemical Indicator Strips", "BX", 16.40, True, 1095, "low", ["Box-100ct"])
add_items("Sterilization Supplies", "Enzymatic Instrument Cleaner", "BT", 23.80, True, 1095, "low", ["Bottle-1L"])

# --- Monitoring Equipment (durable, non-expiring) ---
add_items("Monitoring Equipment", "Vital Signs Monitor, Portable", "EA", 2450.00, False, None, "rare", ["Multi-Parameter"])
add_items("Monitoring Equipment", "Pulse Oximeter, Handheld", "EA", 185.00, False, None, "rare", ["Fingertip"])
add_items("Monitoring Equipment", "Digital Blood Pressure Cuff", "EA", 95.00, False, None, "rare", ["Adult"])
add_items("Monitoring Equipment", "12-Lead ECG Machine", "EA", 4200.00, False, None, "rare", ["Portable"])
add_items("Monitoring Equipment", "Infusion Pump", "EA", 1850.00, False, None, "rare", ["Dual-Channel"])

# --- Diagnostic Imaging Accessories ---
add_items("Diagnostic Imaging Accessories", "Ultrasound Transducer Cover", "BX", 12.30, False, None, "low", ["Box-50ct"])
add_items("Diagnostic Imaging Accessories", "X-Ray Lead Apron", "EA", 320.00, False, None, "rare", ["Adult"])
add_items("Diagnostic Imaging Accessories", "Ultrasound Gel", "BT", 6.75, False, None, "medium", ["Bottle-250mL"])

# --- Mobility & Transport Equipment ---
add_items("Mobility & Transport Equipment", "Wheelchair, Standard", "EA", 210.00, False, None, "rare", ["Adult"])
add_items("Mobility & Transport Equipment", "Folding Litter", "EA", 165.00, False, None, "rare", ["NATO Standard"])
add_items("Mobility & Transport Equipment", "Cervical Collar, Adjustable", "EA", 28.50, False, None, "low", ["Adult"])
add_items("Mobility & Transport Equipment", "Crutches, Aluminum", "PR", 34.00, False, None, "low", ["Adult Pair"])

# --- Resuscitation Equipment ---
add_items("Resuscitation Equipment", "AED (Automated External Defibrillator)", "EA", 1650.00, False, None, "rare", ["Standard"])
add_items("Resuscitation Equipment", "Bag-Valve-Mask Resuscitator", "EA", 42.00, False, None, "low", ["Adult"])
add_items("Resuscitation Equipment", "Oropharyngeal Airway Set", "KT", 38.00, False, None, "low", ["Sizes 0-5"])
add_items("Resuscitation Equipment", "Portable Oxygen Tank, D-Cylinder", "EA", 78.00, False, None, "low", ["Empty/Refillable"])

# --- Sterilization Equipment ---
add_items("Sterilization Equipment", "Autoclave, Tabletop", "EA", 3200.00, False, None, "rare", ["22L"])
add_items("Sterilization Equipment", "Ultrasonic Cleaner", "EA", 890.00, False, None, "rare", ["Instrument"])

# --- Schedule II Analgesics (Controlled Substances) ---
add_items("Schedule II Analgesics", "Morphine Sulfate 10mg/mL Injection", "VI", 28.00, True, 540, "low", ["Vial"])
add_items("Schedule II Analgesics", "Fentanyl 100mcg/2mL Injection", "AM", 34.50, True, 540, "low", ["Ampule"])
add_items("Schedule II Analgesics", "Oxycodone 5mg", "BT", 19.75, True, 540, "low", ["Tablet Bottle-30ct"])
add_items("Schedule II Analgesics", "Hydromorphone 2mg/mL Injection", "VI", 31.20, True, 540, "rare", ["Vial"])

# --- Schedule III-V Medications ---
add_items("Schedule III-V Medications", "Tramadol 50mg", "BT", 9.90, True, 730, "low", ["Tablet Bottle-30ct"])
add_items("Schedule III-V Medications", "Codeine/Acetaminophen 30/300mg", "BT", 12.60, True, 730, "low", ["Tablet Bottle-30ct"])
add_items("Schedule III-V Medications", "Promethazine w/ Codeine Syrup", "BT", 16.00, True, 730, "rare", ["Bottle-120mL"])

# --- Anesthetics ---
add_items("Anesthetics", "Lidocaine 1% Injection", "VI", 6.40, True, 900, "low", ["Vial-50mL"])
add_items("Anesthetics", "Ketamine 50mg/mL Injection", "VI", 22.90, True, 730, "low", ["Vial"])
add_items("Anesthetics", "Bupivacaine 0.5% Injection", "VI", 14.30, True, 730, "rare", ["Vial-50mL"])

# --- Pad out to 150 with realistic pack-size / strength variants of existing lines ---
_variant_bases = [
    ("Antibiotics", "Amoxicillin 875mg", "BT", 10.90, True, 540, "medium"),
    ("Antibiotics", "Penicillin VK 500mg", "BT", 7.80, True, 540, "low"),
    ("Analgesics & NSAIDs", "Ketorolac 15mg/mL Injection", "VI", 8.95, True, 540, "low"),
    ("Cardiovascular Medications", "Amlodipine 5mg", "BT", 4.60, True, 730, "medium"),
    ("Cardiovascular Medications", "Clopidogrel 75mg", "BT", 15.20, True, 730, "low"),
    ("Respiratory Medications", "Montelukast 10mg", "BT", 11.40, True, 730, "low"),
    ("Respiratory Medications", "Prednisone 20mg", "BT", 5.10, True, 900, "medium"),
    ("IV Fluids & Electrolytes", "Normal Saline 0.9% 500mL", "BG", 3.20, True, 730, "high"),
    ("IV Fluids & Electrolytes", "Sodium Bicarbonate 8.4% Injection", "VI", 6.75, True, 900, "rare"),
    ("Wound Care & Dressings", "Petroleum Gauze Dressing 3x9in", "BX", 9.60, True, 1095, "low"),
    ("Wound Care & Dressings", "Abdominal Pad 5x9in", "BX", 11.30, True, 1095, "medium"),
    ("Syringes & Needles", "Syringe 1mL Tuberculin", "BX", 8.20, False, None, "medium"),
    ("Syringes & Needles", "IV Catheter 20G", "BX", 21.10, False, None, "medium"),
    ("PPE & Barrier Protection", "Nitrile Exam Gloves, Small", "BX", 8.90, False, None, "medium"),
    ("PPE & Barrier Protection", "Shoe Covers, Disposable", "BX", 9.40, False, None, "low"),
    ("Diagnostic Test Kits", "Rapid Mono Test Kit", "BX", 41.00, True, 540, "rare"),
    ("Diagnostic Test Kits", "Pregnancy Test Kit, Urine", "BX", 22.00, True, 730, "low"),
    ("Sutures & Surgical Supplies", "Suture Kit, Silk 3-0", "BX", 6.90, True, 1095, "low"),
    ("Trauma & Hemorrhage Control", "SAM Splint", "EA", 13.50, False, None, "low"),
    ("Sterilization Supplies", "Autoclave Tape", "RO", 4.10, False, None, "low"),
    ("Mobility & Transport Equipment", "Cane, Adjustable Aluminum", "EA", 24.00, False, None, "low"),
    ("Resuscitation Equipment", "Nasopharyngeal Airway Set", "KT", 29.00, False, None, "rare"),
    ("Diagnostic Imaging Accessories", "EKG Electrode Pads", "BX", 14.80, False, None, "medium"),
    ("Vaccines & Immunizations", "Pneumococcal Vaccine (PPSV23)", "VI", 68.00, True, 540, "rare"),
    ("Vaccines & Immunizations", "Varicella Vaccine", "VI", 92.00, True, 365, "rare"),
    ("Cardiovascular Medications", "Nitroglycerin Sublingual Tablet", "BT", 13.90, True, 540, "low"),
    ("Anesthetics", "Lidocaine 2% Injection", "VI", 6.80, True, 900, "low"),
]
for cat, name, unit, cost, exp, shelf, tier in _variant_bases:
    ITEM_TEMPLATES.append((name, cat, unit, cost, exp, shelf, tier))

assert len(ITEM_TEMPLATES) <= 150, f"have {len(ITEM_TEMPLATES)} hand-authored templates, need <=150"

# Fill any remainder up to exactly 150 with additional pack-size variants of
# already-defined consumables (keeps the catalog internally consistent rather
# than inventing filler categories).
_pad_pool = [
    ("Wound Care & Dressings", "Gauze Pad 2x2in Sterile", "BX", 5.20, True, 1095, "high"),
    ("PPE & Barrier Protection", "Bouffant Cap, Disposable", "BX", 6.10, False, None, "low"),
    ("Syringes & Needles", "Hypodermic Needle 25G x 5/8in", "BX", 7.10, False, None, "medium"),
    ("Sterilization Supplies", "Sterilization Wrap, 24x24in", "BX", 19.50, False, None, "low"),
    ("Diagnostic Test Kits", "Hemoglobin A1C Test Kit", "BX", 33.00, True, 540, "rare"),
]
i = 0
while len(ITEM_TEMPLATES) < 150:
    cat, name, unit, cost, exp, shelf, tier = _pad_pool[i % len(_pad_pool)]
    ITEM_TEMPLATES.append((name, cat, unit, cost, exp, shelf, tier))
    i += 1

ITEM_TEMPLATES = ITEM_TEMPLATES[:150]
assert len(ITEM_TEMPLATES) == 150

def make_nsn(i):
    fsc = 6505 if i % 3 != 2 else 6515
    return f"{fsc}-{(i * 37) % 99:02d}-{(i * 211) % 999:03d}-{(i * 733) % 9999:04d}"

item_rows = []
ITEMS = []  # parallel list of dicts with resolved item_id and metadata
for idx, (name, cat, unit, cost, exp_tracked, shelf, tier) in enumerate(ITEM_TEMPLATES, start=1):
    nsn = make_nsn(idx)
    # reorder point / safety stock scaled loosely by usage tier and unit cost
    if tier == "high":
        reorder, safety = random.randint(300, 600), random.randint(80, 180)
    elif tier == "seasonal":
        reorder, safety = random.randint(150, 300), random.randint(40, 90)
    elif tier == "medium":
        reorder, safety = random.randint(80, 200), random.randint(20, 60)
    elif tier == "low":
        reorder, safety = random.randint(20, 80), random.randint(5, 20)
    else:  # rare / durable
        reorder, safety = random.randint(2, 10), random.randint(1, 3)

    item_rows.append((nsn, name, CATEGORY_ID[cat], unit, reorder, safety, cost, exp_tracked))
    ITEMS.append({
        "item_id": idx, "name": name, "category": cat, "unit": unit,
        "reorder_point": reorder, "safety_stock": safety, "unit_cost": cost,
        "exp_tracked": exp_tracked, "shelf_life": shelf, "tier": tier,
    })

out.extend(insert_stmt(
    "supply_items",
    ["nsn_code", "item_name", "category_id", "unit_of_issue", "reorder_point",
     "safety_stock_level", "unit_cost", "is_expiration_tracked"],
    item_rows
))

ITEM_BY_NAME = {it["name"]: it for it in ITEMS}

# =============================================================================
# 5. Kit components (bill-of-materials demo for the recursive CTE)
# =============================================================================
section("Kit components (bill-of-materials)")

# We reuse existing catalog items as kit "parents" — e.g. the CAT tourniquet
# item doubles as a loose component, while these two items represent
# assembled kits built from other catalog items. quantity_per_kit is the
# count of each component needed to build one of the parent kit.
kit_component_rows = []
KIT_PARENT_NAME = "Combat Application Tourniquet (CAT) Gen 7"
ifak_components = [
    ("Hemostatic Gauze, Combat Gauze Roll", 1),
    ("Israeli Battle Dressing 6in", 1),
    ("Occlusive Chest Seal Vented Seal", 2),
    ("Nitrile Exam Gloves, Medium Box-100ct", 2),
    ("Trauma Shears 7.25in", 1),
]
for comp_name, qty in ifak_components:
    kit_component_rows.append((ITEM_BY_NAME[KIT_PARENT_NAME]["item_id"],
                                ITEM_BY_NAME[comp_name]["item_id"], qty))

# NOTE: kit_component_rows above intentionally reuses the CAT tourniquet item
# as a stand-in "kit parent" (an IFAK built around a CAT) rather than
# inventing a synthetic catalog item with no real usage/lot history — keeps
# every id in the demo joinable back to the same usage/inventory data
# reviewers already see.
out.extend(insert_stmt(
    "kit_components", ["parent_item_id", "component_item_id", "quantity_per_kit"],
    kit_component_rows
))

# =============================================================================
# 6. Personnel
# =============================================================================
section("Personnel")

FIRST_NAMES = ["James", "Maria", "Robert", "Linda", "Michael", "Patricia", "David", "Jennifer",
               "William", "Elizabeth", "Richard", "Susan", "Joseph", "Jessica", "Thomas", "Sarah",
               "Charles", "Karen", "Christopher", "Nancy", "Daniel", "Lisa", "Matthew", "Betty",
               "Anthony", "Sandra", "Mark", "Ashley", "Paul", "Kimberly", "Steven", "Emily",
               "Andrew", "Donna", "Kenneth", "Michelle"]
LAST_NAMES = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis",
              "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez", "Wilson", "Anderson",
              "Thomas", "Taylor", "Moore", "Jackson", "Martin", "Lee", "Perez", "Thompson",
              "White", "Harris", "Sanchez", "Clark", "Ramirez", "Lewis", "Robinson"]
RANKS = ["A1C", "SrA", "SSgt", "TSgt", "MSgt", "2Lt", "1Lt", "Capt", "Maj", "GS-9", "GS-11"]
ROLES = ["Medical Logistics Technician", "Medical Logistics Officer", "NCOIC", "Flight Commander",
         "Approving Official", "Pharmacy Technician", "Biomedical Equipment Technician"]

personnel_rows = []
personnel_id = 0
PERSONNEL_BY_FACILITY = {fid: [] for fid in FACILITY_IDS}
used_names = set()
for fid in FACILITY_IDS:
    n_staff = random.randint(4, 7)
    for _ in range(n_staff):
        while True:
            fn, ln = random.choice(FIRST_NAMES), random.choice(LAST_NAMES)
            if (fn, ln, fid) not in used_names:
                used_names.add((fn, ln, fid))
                break
        personnel_id += 1
        rank = random.choice(RANKS)
        role = random.choice(ROLES)
        email = f"{fn.lower()}.{ln.lower()}.{fid}@us.af.mil"
        personnel_rows.append((fid, fn, ln, rank, role, email))
        PERSONNEL_BY_FACILITY[fid].append(personnel_id)

out.extend(insert_stmt(
    "personnel", ["facility_id", "first_name", "last_name", "rank_or_title", "role", "email"],
    personnel_rows
))

print(f"Generated {len(FACILITIES)} facilities, {len(SUPPLIERS)} suppliers, "
      f"{len(CATEGORY_TREE)} categories, {len(ITEM_TEMPLATES)} items, "
      f"{len(kit_component_rows)} kit components, {len(personnel_rows)} personnel.")

# =============================================================================
# 7. Inventory lots, requisitions, and usage transactions
# -----------------------------------------------------------------------------
# Simulated jointly per (facility, item) pair over the full history window so
# reorder-driven requisitions, lot receipt, FEFO consumption, and expiration-
# driven waste all stay internally consistent with each other.
#
# IMPORTANT loading-order note: inventory_lots.quantity_on_hand is written
# out as the FULL originally-received quantity, not the depleted remainder.
# trg_apply_usage_transaction (see functions_triggers.sql) live-decrements it
# as the usage_transactions rows below are loaded, exactly as it would for
# real application traffic — so this generator's Python-side `remaining_qty`
# bookkeeping is a parallel simulation used only to decide *what* to generate
# (when to reorder, what to waste, when a pair goes below reorder point), and
# must never be written into the quantity_on_hand column itself.
# =============================================================================
section("Inventory lots, requisitions, and usage transactions")

# --- facility "carries this item" coverage, by usage tier ---
COVERAGE_BY_TIER = {"high": 0.90, "medium": 0.80, "low": 0.65, "seasonal": 0.85, "rare": 0.55}

# --- monthly baseline demand (units/month/facility), by tier ---
MONTHLY_BASELINE = {"high": 250, "medium": 60, "low": 15, "seasonal": 10, "rare": 0.6}
EVENTS_PER_MONTH = {"high": (3, 8), "medium": (1, 4), "low": (0, 2), "seasonal": (1, 3), "rare": (0, 1)}

# Primary supplier per item (consistent across facilities). Force a
# meaningful slice onto the chronically-late supplier so its scorecard
# numbers are backed by real volume, not a couple of outlier rows.
PRIMARY_SUPPLIER = {}
_late_supplier_items = random.sample(range(1, 151), 12)
for it in ITEMS:
    if it["item_id"] in _late_supplier_items:
        PRIMARY_SUPPLIER[it["item_id"]] = LATE_SUPPLIER_ID
    else:
        PRIMARY_SUPPLIER[it["item_id"]] = random.choice([s for s in SUPPLIER_IDS if s != LATE_SUPPLIER_ID])


def month_range(start: date, end: date):
    y, m = start.year, start.month
    while (y, m) <= (end.year, end.month):
        yield y, m
        m += 1
        if m > 12:
            m = 1
            y += 1


def month_bounds(y, m):
    first = date(y, m, 1)
    if m == 12:
        nxt = date(y + 1, 1, 1)
    else:
        nxt = date(y, m + 1, 1)
    last = nxt - timedelta(days=1)
    return first, min(last, TODAY)


def seasonal_multiplier(tier, month):
    if tier != "seasonal":
        return 1.0
    if month in (11, 12, 1):
        return 7.0
    if month in (10, 2):
        return 3.5
    return 0.3


next_lot_id = 1
next_requisition_id = 1
next_requisition_line_id = 1

inventory_lot_rows = []      # (lot_id placeholder via order, facility_id, item_id, supplier_id, lot_number,
                              #  quantity_on_hand, unit_cost_at_receipt, expiration_date, received_date)
requisition_rows = []         # keyed to requisition_id by insertion order
requisition_line_rows = []
usage_txn_events = []          # (date, facility_id, item_id, lot_id, performed_by, type, qty, note)

PAIR_STATE = {}   # (facility_id, item_id) -> dict with 'lots': [lot dict], 'reorder_point', 'safety_stock'
ALL_LOTS = {}      # lot_id -> lot dict (mutable remaining_qty)

MCI_ITEM_NAME = "Normal Saline 0.9% 1000mL IV Bag"  # deliberate "interesting usage pattern" item


def make_lot_number(item_id, seq):
    return f"L{item_id:03d}-{seq:04d}"


def new_lot(facility_id, item_id, supplier_id, qty, received_date, unit_cost):
    global next_lot_id
    item = ITEMS[item_id - 1]
    if item["exp_tracked"]:
        expiration_date = received_date + timedelta(days=item["shelf_life"])
    else:
        expiration_date = None
    lot_id = next_lot_id
    next_lot_id += 1
    pair_key = (facility_id, item_id)
    seq = len([l for l in ALL_LOTS.values() if l["facility_id"] == facility_id and l["item_id"] == item_id]) + 1
    lot = {
        "lot_id": lot_id, "facility_id": facility_id, "item_id": item_id, "supplier_id": supplier_id,
        "lot_number": make_lot_number(item_id, seq), "received_qty": qty, "remaining_qty": qty,
        "unit_cost": unit_cost, "expiration_date": expiration_date, "received_date": received_date,
    }
    ALL_LOTS[lot_id] = lot
    inventory_lot_rows.append(lot)
    return lot


def fefo_sorted(active_lots):
    return sorted(active_lots, key=lambda l: (l["expiration_date"] is None, l["expiration_date"] or date.max, l["received_date"]))


def consume(pair_lots, qty_needed, event_date):
    """Consume qty_needed across pair_lots in FEFO order. Returns actual qty consumed
    (may be less than requested if stock is insufficient -- i.e. a stockout)."""
    remaining_need = qty_needed
    consumed_total = 0
    consumption = []  # (lot, qty)
    for lot in fefo_sorted([l for l in pair_lots if l["remaining_qty"] > 0]):
        if remaining_need <= 0:
            break
        take = min(lot["remaining_qty"], remaining_need)
        if take <= 0:
            continue
        lot["remaining_qty"] -= take
        remaining_need -= take
        consumed_total += take
        consumption.append((lot, take))
    return consumption, consumed_total


def expire_due_lots(pair_lots, as_of_date, facility_id, item_id, performed_by):
    """Any lot whose expiration_date has passed as_of_date and still has stock
    generates a 'waste' transaction for its full remaining quantity."""
    for lot in pair_lots:
        if lot["expiration_date"] is not None and lot["expiration_date"] <= as_of_date and lot["remaining_qty"] > 0:
            qty = lot["remaining_qty"]
            lot["remaining_qty"] = 0
            usage_txn_events.append((min(lot["expiration_date"], TODAY), facility_id, item_id, lot["lot_id"],
                                      performed_by, "waste", qty, "expired, discarded"))


pairs_simulated = 0
for facility_id in FACILITY_IDS:
    staff = PERSONNEL_BY_FACILITY[facility_id]
    for item in ITEMS:
        item_id = item["item_id"]
        if random.random() > COVERAGE_BY_TIER[item["tier"]]:
            continue
        pairs_simulated += 1
        pair_key = (facility_id, item_id)
        supplier_id = PRIMARY_SUPPLIER[item_id]
        reorder_point = item["reorder_point"]
        safety_stock = item["safety_stock"]
        unit_cost = item["unit_cost"]

        pair_lots = []
        PAIR_STATE[pair_key] = {"lots": pair_lots, "reorder_point": reorder_point,
                                 "safety_stock": safety_stock, "item_id": item_id, "facility_id": facility_id,
                                 "supplier_id": supplier_id}

        # Initial stock, received shortly before the simulation window opens.
        initial_qty = max(reorder_point * random.uniform(1.5, 2.5), safety_stock * 2, 2)
        initial_qty = int(round(initial_qty))
        initial_received = HISTORY_START - timedelta(days=random.randint(0, 20))
        lot = new_lot(facility_id, item_id, supplier_id, initial_qty, initial_received, unit_cost)
        pair_lots.append(lot)

        pending_requisition = None   # dict: {'requisition_idx', 'expected_arrival', 'order_qty'}

        for y, m in month_range(HISTORY_START, TODAY):
            m_start, m_end = month_bounds(y, m)

            # --- receive any pending requisition whose lead time has elapsed ---
            if pending_requisition and pending_requisition["expected_arrival"] <= m_end:
                req_idx = pending_requisition["requisition_idx"]
                # A small slice of outstanding orders get cancelled outright
                # (item substituted, no-longer-needed, budget pulled) rather
                # than received — keeps the 'cancelled' status meaningfully
                # represented instead of every requisition resolving cleanly.
                if random.random() < 0.02:
                    requisition_rows[req_idx]["status"] = "cancelled"
                    pending_requisition = None
                else:
                    arrival = max(pending_requisition["expected_arrival"], m_start)
                    supplier = SUPPLIER_ROWS_BY_ID[supplier_id]
                    reliability = supplier["reliability_rating"]
                    is_late = supplier_id == LATE_SUPPLIER_ID
                    fill_ratio = 1.0
                    if is_late and random.random() < 0.35:
                        fill_ratio = random.uniform(0.5, 0.85)
                    elif reliability < 3.5 and random.random() < 0.15:
                        fill_ratio = random.uniform(0.7, 0.95)
                    received_qty = max(1, int(round(pending_requisition["order_qty"] * fill_ratio)))

                    cost_variance = unit_cost * random.uniform(0.97, 1.05)
                    new_l = new_lot(facility_id, item_id, supplier_id, received_qty, arrival, cost_variance)
                    pair_lots.append(new_l)

                    req = requisition_rows[req_idx]
                    line = requisition_line_rows[pending_requisition["line_idx"]]
                    line["quantity_fulfilled"] = received_qty
                    if received_qty >= line["quantity_requested"]:
                        req["status"] = "fulfilled"
                        req["date_fulfilled"] = arrival
                    else:
                        req["status"] = "partially_fulfilled"
                    pending_requisition = None

            # --- expire any lots that came due this month ---
            expire_due_lots(pair_lots, m_end, facility_id, item_id, random.choice(staff))

            # --- generate this month's usage events ---
            baseline = MONTHLY_BASELINE[item["tier"]]
            mult = seasonal_multiplier(item["tier"], m)
            monthly_target = baseline * mult * random.uniform(0.7, 1.3)

            if item["tier"] == "rare":
                monthly_qty = 1 if random.random() < 0.12 else 0
            else:
                monthly_qty = int(round(monthly_target))

            lo, hi = EVENTS_PER_MONTH[item["tier"]]
            n_events = random.randint(lo, hi) if monthly_qty > 0 else 0

            if n_events > 0 and monthly_qty > 0:
                # split monthly_qty across n_events, each >= 1
                splits = [1] * n_events
                remainder = monthly_qty - n_events
                for _ in range(max(remainder, 0)):
                    splits[random.randrange(n_events)] += 1
                event_days = sorted(random.randint(0, (m_end - m_start).days) for _ in range(n_events))
                for day_offset, qty in zip(event_days, splits):
                    event_date = m_start + timedelta(days=day_offset)
                    performed_by = random.choice(staff)
                    consumption, consumed = consume(pair_lots, qty, event_date)
                    for lot, take in consumption:
                        usage_txn_events.append((event_date, facility_id, item_id, lot["lot_id"],
                                                  performed_by, "issue", take, None))

            # --- deliberate "interesting usage pattern": occasional mass-casualty
            #     exercise surge on IV saline, layered on top of normal demand ---
            if item["name"] == MCI_ITEM_NAME and random.random() < 0.07:
                surge_qty = int(baseline * random.uniform(8, 15))
                surge_date = m_start + timedelta(days=random.randint(0, (m_end - m_start).days))
                performed_by = random.choice(staff)
                consumption, consumed = consume(pair_lots, surge_qty, surge_date)
                for lot, take in consumption:
                    usage_txn_events.append((surge_date, facility_id, item_id, lot["lot_id"],
                                              performed_by, "issue", take, "MCI exercise surge"))

            # --- occasional small inventory-count adjustment ---
            if random.random() < 0.02:
                active = [l for l in pair_lots if l["remaining_qty"] > 0]
                if active:
                    adj_lot = random.choice(active)
                    adj_qty = min(adj_lot["remaining_qty"], random.randint(1, max(1, int(reorder_point * 0.05) + 1)))
                    if adj_qty > 0:
                        adj_lot["remaining_qty"] -= adj_qty
                        adj_date = m_start + timedelta(days=random.randint(0, (m_end - m_start).days))
                        usage_txn_events.append((adj_date, facility_id, item_id, adj_lot["lot_id"],
                                                  random.choice(staff), "adjustment_decrease", adj_qty,
                                                  "physical count correction"))

            # --- check reorder point at month end, submit a requisition if needed ---
            total_on_hand = sum(l["remaining_qty"] for l in pair_lots)
            if total_on_hand < reorder_point and pending_requisition is None and m_end <= TODAY:
                supplier = SUPPLIER_ROWS_BY_ID[supplier_id]
                base_lead = supplier["contracted_lead_time_days"]
                if supplier_id == LATE_SUPPLIER_ID:
                    lead = base_lead + random.randint(4, 14)
                else:
                    # Higher-reliability suppliers cluster tighter around (and
                    # more often under) their contracted lead time; lower-
                    # reliability ones drift later — so on-time % in the
                    # scorecard actually tracks the reliability_rating column
                    # instead of being swamped by noise.
                    reliability = supplier["reliability_rating"]
                    center = (4.5 - reliability) * 1.2
                    jitter = round(random.uniform(-2, 1) + center)
                    lead = max(1, base_lead + jitter)

                order_qty = max(reorder_point * 2 - total_on_hand, safety_stock)
                order_qty = int(round(order_qty))
                submit_date = m_end
                approve_date = submit_date + timedelta(days=random.randint(0, 1))
                requester = random.choice(staff)
                approver = random.choice(staff)

                req_idx = len(requisition_rows)
                requisition_rows.append({
                    "requisition_id": next_requisition_id, "facility_id": facility_id, "supplier_id": supplier_id,
                    "requested_by": requester, "approved_by": approver, "status": "approved",
                    "date_submitted": submit_date, "date_approved": approve_date, "date_fulfilled": None,
                })
                next_requisition_id += 1

                line_idx = len(requisition_line_rows)
                requisition_line_rows.append({
                    "requisition_id": requisition_rows[req_idx]["requisition_id"], "item_id": item_id,
                    "quantity_requested": order_qty, "quantity_fulfilled": 0,
                    "unit_cost_at_order": round(unit_cost * random.uniform(0.98, 1.03), 2),
                })

                pending_requisition = {
                    "requisition_idx": req_idx, "line_idx": line_idx,
                    "expected_arrival": approve_date + timedelta(days=lead), "order_qty": order_qty,
                }

        # drop fully depleted lots from the active pointer list (keeps FEFO scans cheap);
        # ALL_LOTS / inventory_lot_rows already has the permanent record.
        PAIR_STATE[pair_key]["lots"] = [l for l in pair_lots]

print(f"Simulated {pairs_simulated} facility-item pairs; "
      f"{len(inventory_lot_rows)} lots, {len(requisition_rows)} requisitions, "
      f"{len(usage_txn_events)} usage events (pre-edge-case pass).")

# -----------------------------------------------------------------------------
# 7a. Deliberate edge cases (spec requirement): guarantee — regardless of how
# the randomized simulation above happened to land — that the dataset
# contains clear, demonstrable examples of:
#   (1) items currently below reorder point at a facility
#   (2) lots expiring within the next 30 days
# Both conditions almost certainly already occur somewhat naturally (stock-
# outs and short-dated lots fall out of the simulation on their own), but we
# force a guaranteed minimum set so the analytical queries always have
# non-empty, illustrative results to show a reviewer.
# -----------------------------------------------------------------------------
section("Deliberate edge cases: forced below-reorder-point and expiring-soon lots")

eligible_pairs = list(PAIR_STATE.keys())
random.shuffle(eligible_pairs)

forced_low_stock = 0
for (fid, iid) in eligible_pairs:
    if forced_low_stock >= 10:
        break
    state = PAIR_STATE[(fid, iid)]
    active = [l for l in state["lots"] if l["remaining_qty"] > 0]
    total = sum(l["remaining_qty"] for l in active)
    if total <= state["reorder_point"] or not active:
        continue  # already below, or nothing to draw down — skip
    # drive it below reorder_point with one final "physical inventory" adjustment
    target_remove = total - state["reorder_point"] + random.randint(1, max(1, state["safety_stock"]))
    staff = PERSONNEL_BY_FACILITY[fid]
    for lot in fefo_sorted(active):
        if target_remove <= 0:
            break
        take = min(lot["remaining_qty"], target_remove)
        lot["remaining_qty"] -= take
        target_remove -= take
        usage_txn_events.append((TODAY - timedelta(days=random.randint(1, 5)), fid, iid, lot["lot_id"],
                                  random.choice(staff), "adjustment_decrease", take,
                                  "forced demo edge case: below reorder point"))
    forced_low_stock += 1

forced_expiring = 0
for (fid, iid) in eligible_pairs:
    if forced_expiring >= 10:
        break
    item = ITEMS[iid - 1]
    if not item["exp_tracked"]:
        continue
    state = PAIR_STATE[(fid, iid)]
    active = [l for l in state["lots"] if l["remaining_qty"] > 0]
    if not active:
        continue
    lot = fefo_sorted(active)[0]
    lot["expiration_date"] = TODAY + timedelta(days=random.randint(4, 28))
    forced_expiring += 1

print(f"Forced {forced_low_stock} pairs below reorder point, {forced_expiring} lots into the 30-day expiration window.")

# =============================================================================
# 8. Emit inventory_lots, requisitions, requisition_lines, usage_transactions
# =============================================================================

out.extend(insert_stmt(
    "inventory_lots",
    ["facility_id", "item_id", "supplier_id", "lot_number", "quantity_on_hand",
     "unit_cost_at_receipt", "expiration_date", "received_date"],
    [(l["facility_id"], l["item_id"], l["supplier_id"], l["lot_number"], l["received_qty"],
      round(l["unit_cost"], 2), l["expiration_date"], l["received_date"])
     for l in inventory_lot_rows]
))

section("Requisitions")
out.extend(insert_stmt(
    "requisitions",
    ["facility_id", "supplier_id", "requested_by", "approved_by", "status",
     "date_submitted", "date_approved", "date_fulfilled"],
    [(r["facility_id"], r["supplier_id"], r["requested_by"], r["approved_by"], r["status"],
      r["date_submitted"], r["date_approved"], r["date_fulfilled"])
     for r in requisition_rows]
))

section("Requisition lines")
out.extend(insert_stmt(
    "requisition_lines",
    ["requisition_id", "item_id", "quantity_requested", "quantity_fulfilled", "unit_cost_at_order"],
    [(rl["requisition_id"], rl["item_id"], rl["quantity_requested"], rl["quantity_fulfilled"],
      rl["unit_cost_at_order"])
     for rl in requisition_line_rows]
))

section("Usage transactions")
# Stable sort by date only: two events against the *same* lot that share a
# date keep their original relative order (Python's sort is stable), which
# matters because trg_apply_usage_transaction decrements quantity_on_hand
# live as each row loads — consumption order must match how it was actually
# drawn down in the simulation above, or an early row could (correctly!) get
# rejected by the negative-stock guard for a lot that only looks
# over-consumed because of insert ordering.
usage_txn_events.sort(key=lambda e: e[0])

out.extend(insert_stmt(
    "usage_transactions",
    ["transaction_date", "facility_id", "item_id", "lot_id", "performed_by",
     "transaction_type", "quantity", "notes"],
    [(e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7]) for e in usage_txn_events]
))

print(f"Totals: {len(inventory_lot_rows)} lots, {len(requisition_rows)} requisitions, "
      f"{len(requisition_line_rows)} requisition lines, {len(usage_txn_events)} usage transactions.")

# =============================================================================
# Write the file
# =============================================================================
header = f"""-- =============================================================================
-- MedLogTrack — Seed data
-- Auto-generated by scripts/generate_seed_data.py (SEED={SEED}, anchor date={TODAY.isoformat()}).
-- Do not hand-edit — regenerate via `python scripts/generate_seed_data.py` instead.
--
-- Load order matters (FK dependencies): run this after schema.sql AND
-- functions_triggers.sql — usage_transactions rows rely on
-- trg_apply_usage_transaction to apply themselves to inventory_lots as they
-- load (each inventory_lots row below is inserted with its FULL originally-
-- received quantity; the usage_transactions further down decrement it live).
--
--   psql -U <user> -d medlogtrack -f schema.sql
--   psql -U <user> -d medlogtrack -f functions_triggers.sql
--   psql -U <user> -d medlogtrack -f seed_data.sql
-- =============================================================================

"""

OUT_PATH.write_text(header + "\n".join(out), encoding="utf-8")
print(f"Wrote {OUT_PATH}")
