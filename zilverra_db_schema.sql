-- =============================================================================
-- ZILVERRA JEWELRY MANUFACTURING ERP - COMPLETE POSTGRESQL DATABASE SCHEMA
-- Version: 1.0 | Based on PRD v1.0
-- =============================================================================
-- Design Principles:
--   * All dropdown/status values driven from DB lookup tables (no hardcoded enums)
--   * Full normalization with strategic denormalization for performance
--   * Comprehensive constraints, check constraints, and business rule enforcement
--   * Audit columns on every table (created_at, updated_at, created_by, updated_by)
--   * Append-only audit log (immutable by design)
--   * Partial indexes, composite indexes, and GIN indexes for JSONB fields
-- =============================================================================

-- ============================================================
-- EXTENSIONS
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- fuzzy search on names
CREATE EXTENSION IF NOT EXISTS "btree_gin"; -- GIN on scalar types

-- ============================================================
-- SCHEMAS
-- ============================================================
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS inventory;
CREATE SCHEMA IF NOT EXISTS production;
CREATE SCHEMA IF NOT EXISTS sales;
CREATE SCHEMA IF NOT EXISTS finance;
CREATE SCHEMA IF NOT EXISTS hr;
CREATE SCHEMA IF NOT EXISTS audit;

SET search_path = public, core, inventory, production, sales, finance, hr, audit;

-- =============================================================================
-- SECTION 1: LOOKUP / REFERENCE TABLES
-- All front-end dropdowns are powered from these tables.
-- =============================================================================

-- ------------------------------------------------------------
-- 1.1 Lookup Categories (meta-table grouping all lookup domains)
-- ------------------------------------------------------------
CREATE TABLE core.lookup_categories (
    id              SERIAL PRIMARY KEY,
    code            VARCHAR(60)  NOT NULL UNIQUE,
    name            VARCHAR(120) NOT NULL,
    description     TEXT,
    is_system       BOOLEAN      NOT NULL DEFAULT TRUE,   -- system-managed vs user-managed
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE core.lookup_categories IS 'Master registry of all lookup domains (dropdown groups).';

-- ------------------------------------------------------------
-- 1.2 Lookup Values (all dropdowns in one table)
-- ------------------------------------------------------------
CREATE TABLE core.lookup_values (
    id              SERIAL PRIMARY KEY,
    category_id     INT          NOT NULL REFERENCES core.lookup_categories(id),
    code            VARCHAR(80)  NOT NULL,
    name            VARCHAR(200) NOT NULL,
    description     TEXT,
    display_order   SMALLINT     NOT NULL DEFAULT 0,
    metadata        JSONB,                               -- extra attributes per domain
    is_default      BOOLEAN      NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    parent_id       INT          REFERENCES core.lookup_values(id),  -- for hierarchical lookups
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (category_id, code)
);

CREATE INDEX idx_lookup_values_category ON core.lookup_values(category_id) WHERE is_active;
CREATE INDEX idx_lookup_values_code     ON core.lookup_values(category_id, code);

COMMENT ON TABLE core.lookup_values IS
  'Single source of truth for ALL dropdown/status/type values shown in the UI.';

-- =============================================================================
-- SECTION 2: ORGANIZATION STRUCTURE
-- =============================================================================

CREATE TABLE core.organizations (
    id              UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    code            VARCHAR(20)  NOT NULL UNIQUE,
    name            VARCHAR(200) NOT NULL,
    legal_name      VARCHAR(300),
    pan             VARCHAR(10)  CHECK (pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
    gstin           VARCHAR(15)  CHECK (gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
    address_line1   VARCHAR(300),
    address_line2   VARCHAR(300),
    city            VARCHAR(100),
    state           VARCHAR(100),
    pincode         VARCHAR(10),
    country         VARCHAR(80)  NOT NULL DEFAULT 'India',
    phone           VARCHAR(20),
    email           VARCHAR(200) CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    website         VARCHAR(300),
    logo_url        TEXT,
    base_currency   VARCHAR(3)   NOT NULL DEFAULT 'INR',
    fiscal_year_start_month SMALLINT NOT NULL DEFAULT 4 CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    created_by      UUID,
    updated_by      UUID
);

CREATE TABLE core.branches (
    id              UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID         NOT NULL REFERENCES core.organizations(id),
    parent_branch_id UUID        REFERENCES core.branches(id),  -- for HO > Branch > Sub-unit hierarchy
    code            VARCHAR(30)  NOT NULL,
    name            VARCHAR(200) NOT NULL,
    branch_type_id  INT          NOT NULL REFERENCES core.lookup_values(id),  -- HEAD_OFFICE, BRANCH, MANUFACTURING_UNIT
    gstin           VARCHAR(15)  CHECK (gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
    address_line1   VARCHAR(300),
    address_line2   VARCHAR(300),
    city            VARCHAR(100),
    state           VARCHAR(100),
    pincode         VARCHAR(10),
    phone           VARCHAR(20),
    email           VARCHAR(200) CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    currency        VARCHAR(3)   NOT NULL DEFAULT 'INR',
    timezone        VARCHAR(60)  NOT NULL DEFAULT 'Asia/Kolkata',
    is_gst_registered BOOLEAN   NOT NULL DEFAULT TRUE,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    created_by      UUID,
    updated_by      UUID,
    UNIQUE (organization_id, code)
);

CREATE INDEX idx_branches_org      ON core.branches(organization_id);
CREATE INDEX idx_branches_parent   ON core.branches(parent_branch_id);

-- =============================================================================
-- SECTION 3: RBAC — ROLES, MODULES, PERMISSIONS, USERS
-- =============================================================================

CREATE TABLE core.modules (
    id              SERIAL       PRIMARY KEY,
    code            VARCHAR(60)  NOT NULL UNIQUE,
    name            VARCHAR(120) NOT NULL,
    description     TEXT,
    parent_module_id INT         REFERENCES core.modules(id),
    display_order   SMALLINT     NOT NULL DEFAULT 0,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE core.permission_actions (
    id              SERIAL       PRIMARY KEY,
    code            VARCHAR(30)  NOT NULL UNIQUE,  -- VIEW, ADD, EDIT, DELETE, APPROVE, EXPORT
    name            VARCHAR(80)  NOT NULL,
    display_order   SMALLINT     NOT NULL DEFAULT 0,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE core.roles (
    id              UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID         NOT NULL REFERENCES core.organizations(id),
    code            VARCHAR(60)  NOT NULL,
    name            VARCHAR(120) NOT NULL,
    description     TEXT,
    is_system_role  BOOLEAN      NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    created_by      UUID,
    updated_by      UUID,
    UNIQUE (organization_id, code)
);

CREATE TABLE core.role_permissions (
    id              BIGSERIAL    PRIMARY KEY,
    role_id         UUID         NOT NULL REFERENCES core.roles(id),
    module_id       INT          NOT NULL REFERENCES core.modules(id),
    action_id       INT          NOT NULL REFERENCES core.permission_actions(id),
    is_allowed      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    created_by      UUID,
    UNIQUE (role_id, module_id, action_id)
);

CREATE INDEX idx_role_permissions_role ON core.role_permissions(role_id);

CREATE TABLE core.users (
    id              UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID         NOT NULL REFERENCES core.organizations(id),
    employee_id     UUID,                              -- FK to hr.employees (set after employee creation)
    username        VARCHAR(80)  NOT NULL UNIQUE,
    email           VARCHAR(200) NOT NULL UNIQUE CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    phone           VARCHAR(20),
    password_hash   TEXT         NOT NULL,
    full_name       VARCHAR(200) NOT NULL,
    avatar_url      TEXT,
    is_mfa_enabled  BOOLEAN      NOT NULL DEFAULT FALSE,
    mfa_secret      TEXT,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    is_locked       BOOLEAN      NOT NULL DEFAULT FALSE,
    failed_attempts SMALLINT     NOT NULL DEFAULT 0 CHECK (failed_attempts >= 0),
    locked_at       TIMESTAMPTZ,
    last_login_at   TIMESTAMPTZ,
    last_login_ip   INET,
    password_changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    must_change_password BOOLEAN  NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    created_by      UUID,
    updated_by      UUID
);

CREATE INDEX idx_users_org       ON core.users(organization_id);
CREATE INDEX idx_users_email     ON core.users(email);

-- A user holds exactly one active role per branch (BR-ORG-04)
CREATE TABLE core.user_branch_roles (
    id              BIGSERIAL    PRIMARY KEY,
    user_id         UUID         NOT NULL REFERENCES core.users(id),
    branch_id       UUID         NOT NULL REFERENCES core.branches(id),
    role_id         UUID         NOT NULL REFERENCES core.roles(id),
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    assigned_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    assigned_by     UUID         NOT NULL REFERENCES core.users(id),
    revoked_at      TIMESTAMPTZ,
    revoked_by      UUID         REFERENCES core.users(id),
    UNIQUE (user_id, branch_id, role_id, is_active)   -- one active role per user per branch
);

CREATE INDEX idx_ubr_user   ON core.user_branch_roles(user_id) WHERE is_active;
CREATE INDEX idx_ubr_branch ON core.user_branch_roles(branch_id) WHERE is_active;

-- Feature flags (NFR-MNT-02)
CREATE TABLE core.feature_flags (
    id              SERIAL       PRIMARY KEY,
    organization_id UUID         REFERENCES core.organizations(id),  -- NULL = global
    branch_id       UUID         REFERENCES core.branches(id),
    role_id         UUID         REFERENCES core.roles(id),
    flag_key        VARCHAR(100) NOT NULL,
    flag_value      JSONB        NOT NULL DEFAULT 'true',
    description     TEXT,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (organization_id, branch_id, role_id, flag_key)
);

-- =============================================================================
-- SECTION 4: MASTER DATA — PARTIES (SUPPLIERS, VENDORS, CUSTOMERS)
-- =============================================================================

CREATE TABLE core.parties (
    id                  UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id     UUID        NOT NULL REFERENCES core.organizations(id),
    party_type_id       INT         NOT NULL REFERENCES core.lookup_values(id), -- SUPPLIER, VENDOR, CUSTOMER, BOTH
    code                VARCHAR(40) NOT NULL,
    name                VARCHAR(300) NOT NULL,
    trade_name          VARCHAR(300),
    gstin               VARCHAR(15)  CHECK (gstin IS NULL OR gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
    pan                 VARCHAR(10)  CHECK (pan IS NULL OR pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
    contact_person      VARCHAR(200),
    phone               VARCHAR(20),
    alternate_phone     VARCHAR(20),
    email               VARCHAR(200) CHECK (email IS NULL OR email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    address_line1       VARCHAR(300),
    address_line2       VARCHAR(300),
    city                VARCHAR(100),
    state               VARCHAR(100),
    pincode             VARCHAR(10),
    country             VARCHAR(80) NOT NULL DEFAULT 'India',
    bank_name           VARCHAR(200),
    bank_account_no     VARCHAR(30),  -- stored masked in UI (NFR-COM-03)
    bank_ifsc           VARCHAR(15)   CHECK (bank_ifsc IS NULL OR bank_ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
    credit_limit        NUMERIC(15,2) DEFAULT 0 CHECK (credit_limit >= 0),
    credit_days         SMALLINT      DEFAULT 0 CHECK (credit_days >= 0),
    payment_terms_id    INT           REFERENCES core.lookup_values(id),
    rating              SMALLINT      CHECK (rating BETWEEN 1 AND 5),
    status_id           INT           NOT NULL REFERENCES core.lookup_values(id), -- ACTIVE, INACTIVE, BLACKLISTED
    blacklisted_at      TIMESTAMPTZ,
    blacklisted_by      UUID         REFERENCES core.users(id),
    blacklist_reason    TEXT,
    is_gst_registered   BOOLEAN      NOT NULL DEFAULT TRUE,
    notes               TEXT,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    created_by          UUID         REFERENCES core.users(id),
    updated_by          UUID         REFERENCES core.users(id),
    UNIQUE (organization_id, code)
);

-- Uniqueness on GSTIN and PAN per entity type (BR-SVC-05)
CREATE UNIQUE INDEX idx_parties_gstin ON core.parties(organization_id, gstin, party_type_id) WHERE gstin IS NOT NULL;
CREATE UNIQUE INDEX idx_parties_pan   ON core.parties(organization_id, pan, party_type_id)   WHERE pan IS NOT NULL;
CREATE INDEX idx_parties_status       ON core.parties(status_id);
CREATE INDEX idx_parties_name_trgm    ON core.parties USING GIN (name gin_trgm_ops);

-- Party tags/categories (FR-SVC-02)
CREATE TABLE core.party_tags (
    id          BIGSERIAL   PRIMARY KEY,
    party_id    UUID        NOT NULL REFERENCES core.parties(id) ON DELETE CASCADE,
    tag_id      INT         NOT NULL REFERENCES core.lookup_values(id),  -- SILVER_SUPPLIER, B2B_CUSTOMER etc.
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by  UUID        REFERENCES core.users(id),
    UNIQUE (party_id, tag_id)
);

-- Party contact addresses (multiple addresses per party)
CREATE TABLE core.party_contacts (
    id              BIGSERIAL   PRIMARY KEY,
    party_id        UUID        NOT NULL REFERENCES core.parties(id) ON DELETE CASCADE,
    contact_type_id INT         NOT NULL REFERENCES core.lookup_values(id),  -- BILLING, SHIPPING, OTHER
    contact_name    VARCHAR(200),
    phone           VARCHAR(20),
    email           VARCHAR(200),
    address_line1   VARCHAR(300),
    address_line2   VARCHAR(300),
    city            VARCHAR(100),
    state           VARCHAR(100),
    pincode         VARCHAR(10),
    is_default      BOOLEAN     NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- SECTION 5: RAW MATERIAL & INVENTORY
-- =============================================================================

CREATE TABLE inventory.material_categories (
    id              SERIAL      PRIMARY KEY,
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    parent_id       INT         REFERENCES inventory.material_categories(id),
    code            VARCHAR(40) NOT NULL,
    name            VARCHAR(200) NOT NULL,
    description     TEXT,
    is_precious_metal BOOLEAN   NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (organization_id, code)
);

CREATE TABLE inventory.materials (
    id                  UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id     UUID        NOT NULL REFERENCES core.organizations(id),
    category_id         INT         NOT NULL REFERENCES inventory.material_categories(id),
    code                VARCHAR(40) NOT NULL,
    name                VARCHAR(200) NOT NULL,
    description         TEXT,
    uom_id              INT         NOT NULL REFERENCES core.lookup_values(id),  -- GRAM, KG, PIECE, CARAT
    uom_secondary_id    INT         REFERENCES core.lookup_values(id),           -- secondary UOM
    material_type_id    INT         NOT NULL REFERENCES core.lookup_values(id),  -- PRECIOUS_METAL, STONE, TOOL, CONSUMABLE, PACKAGING
    hsn_code            VARCHAR(10),
    gst_rate            NUMERIC(5,2) CHECK (gst_rate >= 0 AND gst_rate <= 100),
    min_purity          NUMERIC(6,4) CHECK (min_purity IS NULL OR (min_purity >= 0.001 AND min_purity <= 1.000)),
    max_purity          NUMERIC(6,4) CHECK (max_purity IS NULL OR (max_purity >= 0.001 AND max_purity <= 1.000)),
    reorder_level       NUMERIC(15,4) DEFAULT 0,
    barcode_prefix      VARCHAR(10),
    is_barcode_tracked  BOOLEAN     NOT NULL DEFAULT TRUE,
    is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by          UUID        REFERENCES core.users(id),
    updated_by          UUID        REFERENCES core.users(id),
    UNIQUE (organization_id, code),
    CHECK (min_purity IS NULL OR max_purity IS NULL OR min_purity <= max_purity)
);

CREATE INDEX idx_materials_category ON inventory.materials(category_id);
CREATE INDEX idx_materials_type     ON inventory.materials(material_type_id);

-- Stock lots — every inward shipment creates a lot
CREATE TABLE inventory.stock_lots (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    material_id     UUID        NOT NULL REFERENCES inventory.materials(id),
    supplier_id     UUID        REFERENCES core.parties(id),
    lot_number      VARCHAR(60) NOT NULL,
    batch_reference VARCHAR(100),
    barcode         VARCHAR(100) UNIQUE,
    qr_code_data    TEXT,
    purity          NUMERIC(6,4) CHECK (purity IS NULL OR (purity >= 0.001 AND purity <= 1.000)),
    gross_weight    NUMERIC(15,4) NOT NULL CHECK (gross_weight > 0),        -- grams
    net_weight      NUMERIC(15,4) NOT NULL CHECK (net_weight > 0),
    tare_weight     NUMERIC(15,4) NOT NULL DEFAULT 0 CHECK (tare_weight >= 0),
    unit_cost       NUMERIC(15,4) NOT NULL CHECK (unit_cost >= 0),
    total_cost      NUMERIC(18,4) GENERATED ALWAYS AS (net_weight * unit_cost) STORED,
    currency        VARCHAR(3)   NOT NULL DEFAULT 'INR',
    inward_date     DATE         NOT NULL DEFAULT CURRENT_DATE,
    expiry_date     DATE,
    storage_location VARCHAR(100),
    is_barter       BOOLEAN      NOT NULL DEFAULT FALSE,
    barter_value    NUMERIC(15,2),                                           -- value at time of barter
    inward_status_id INT         NOT NULL REFERENCES core.lookup_values(id), -- PENDING, APPROVED, REJECTED
    approved_by     UUID         REFERENCES core.users(id),
    approved_at     TIMESTAMPTZ,
    rejection_reason TEXT,
    weighing_machine_ref VARCHAR(100),                                        -- device serial / reading ID
    available_weight NUMERIC(15,4) NOT NULL CHECK (available_weight >= 0),   -- updated by triggers
    reserved_weight  NUMERIC(15,4) NOT NULL DEFAULT 0 CHECK (reserved_weight >= 0),
    consumed_weight  NUMERIC(15,4) NOT NULL DEFAULT 0 CHECK (consumed_weight >= 0),
    notes           TEXT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    created_by      UUID         REFERENCES core.users(id),
    updated_by      UUID         REFERENCES core.users(id),
    CONSTRAINT chk_lot_weight_balance CHECK (available_weight + reserved_weight + consumed_weight <= net_weight + 0.0001)
);

CREATE INDEX idx_lots_branch    ON inventory.stock_lots(branch_id);
CREATE INDEX idx_lots_material  ON inventory.stock_lots(material_id);
CREATE INDEX idx_lots_status    ON inventory.stock_lots(inward_status_id);
CREATE INDEX idx_lots_barcode   ON inventory.stock_lots(barcode);
CREATE INDEX idx_lots_lot_no    ON inventory.stock_lots(lot_number);

-- Real-time stock balance per branch + material + purity (denormalized for performance)
CREATE TABLE inventory.stock_balances (
    id              BIGSERIAL   PRIMARY KEY,
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    material_id     UUID        NOT NULL REFERENCES inventory.materials(id),
    purity          NUMERIC(6,4),
    total_weight    NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (total_weight >= 0),
    available_weight NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (available_weight >= 0),
    reserved_weight  NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (reserved_weight >= 0),
    wip_weight       NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (wip_weight >= 0),
    last_updated    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (branch_id, material_id, purity)
);

CREATE INDEX idx_stock_bal_branch   ON inventory.stock_balances(branch_id);
CREATE INDEX idx_stock_bal_material ON inventory.stock_balances(material_id);

-- Inter-branch material transfers
CREATE TABLE inventory.branch_transfers (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    transfer_number VARCHAR(40) NOT NULL UNIQUE,
    source_branch_id    UUID    NOT NULL REFERENCES core.branches(id),
    dest_branch_id      UUID    NOT NULL REFERENCES core.branches(id),
    material_id     UUID        NOT NULL REFERENCES inventory.materials(id),
    lot_id          UUID        REFERENCES inventory.stock_lots(id),
    purity          NUMERIC(6,4),
    quantity        NUMERIC(15,4) NOT NULL CHECK (quantity > 0),
    uom_id          INT         NOT NULL REFERENCES core.lookup_values(id),
    transfer_reason TEXT,
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- DRAFT, PENDING_SOURCE_APPROVAL, PENDING_DEST_APPROVAL, APPROVED, IN_TRANSIT, RECEIVED, CANCELLED
    source_approved_by  UUID    REFERENCES core.users(id),
    source_approved_at  TIMESTAMPTZ,
    dest_approved_by    UUID    REFERENCES core.users(id),
    dest_approved_at    TIMESTAMPTZ,
    dispatched_at   TIMESTAMPTZ,
    received_at     TIMESTAMPTZ,
    received_quantity NUMERIC(15,4) CHECK (received_quantity >= 0),
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id),
    updated_by      UUID        REFERENCES core.users(id),
    CHECK (source_branch_id <> dest_branch_id)
);

-- =============================================================================
-- SECTION 6: PRODUCT DESIGN MANAGEMENT
-- =============================================================================

CREATE TABLE production.design_categories (
    id              SERIAL      PRIMARY KEY,
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    parent_id       INT         REFERENCES production.design_categories(id),
    code            VARCHAR(40) NOT NULL,
    name            VARCHAR(200) NOT NULL,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    UNIQUE (organization_id, code)
);

CREATE TABLE production.designs (
    id                  UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id     UUID        NOT NULL REFERENCES core.organizations(id),
    branch_id           UUID        NOT NULL REFERENCES core.branches(id),
    category_id         INT         REFERENCES production.design_categories(id),
    code                VARCHAR(60) NOT NULL,
    name                VARCHAR(300) NOT NULL,
    description         TEXT,
    design_type_id      INT         NOT NULL REFERENCES core.lookup_values(id),  -- CATALOG, CUSTOM, BESPOKE
    status_id           INT         NOT NULL REFERENCES core.lookup_values(id),  -- DRAFT, UNDER_REVIEW, APPROVED, ARCHIVED
    current_version     SMALLINT    NOT NULL DEFAULT 1,
    approved_by         UUID        REFERENCES core.users(id),
    approved_at         TIMESTAMPTZ,
    is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by          UUID        REFERENCES core.users(id),
    updated_by          UUID        REFERENCES core.users(id),
    UNIQUE (organization_id, code)
);

CREATE INDEX idx_designs_branch  ON production.designs(branch_id);
CREATE INDEX idx_designs_status  ON production.designs(status_id);

-- Version history for designs (FR-DES-02)
CREATE TABLE production.design_versions (
    id              BIGSERIAL   PRIMARY KEY,
    design_id       UUID        NOT NULL REFERENCES production.designs(id),
    version_number  SMALLINT    NOT NULL,
    change_summary  TEXT        NOT NULL,
    file_urls       JSONB,       -- array of file URLs
    thumbnail_url   TEXT,
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- DRAFT, SUBMITTED, APPROVED, REJECTED
    approved_by     UUID        REFERENCES core.users(id),
    approved_at     TIMESTAMPTZ,
    rejection_reason TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id),
    UNIQUE (design_id, version_number)
);

-- =============================================================================
-- SECTION 7: BILL OF MATERIALS (BOM)
-- =============================================================================

CREATE TABLE production.bom_templates (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    design_version_id BIGINT    REFERENCES production.design_versions(id),
    code            VARCHAR(60) NOT NULL,
    name            VARCHAR(300) NOT NULL,
    version         SMALLINT    NOT NULL DEFAULT 1,
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- DRAFT, PENDING_APPROVAL, APPROVED, OBSOLETE
    approved_by     UUID        REFERENCES core.users(id),
    approved_at     TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id),
    updated_by      UUID        REFERENCES core.users(id),
    UNIQUE (organization_id, code, version)
);

CREATE TABLE production.bom_line_items (
    id              BIGSERIAL   PRIMARY KEY,
    bom_template_id UUID        NOT NULL REFERENCES production.bom_templates(id),
    parent_line_id  BIGINT      REFERENCES production.bom_line_items(id),  -- multi-level BOM
    material_id     UUID        NOT NULL REFERENCES inventory.materials(id),
    component_type_id INT       NOT NULL REFERENCES core.lookup_values(id), -- PRECIOUS_METAL, STONE, TOOL, LABOR, OTHER
    quantity        NUMERIC(15,4) NOT NULL CHECK (quantity > 0),
    uom_id          INT         NOT NULL REFERENCES core.lookup_values(id),
    purity_required NUMERIC(6,4) CHECK (purity_required IS NULL OR (purity_required >= 0.001 AND purity_required <= 1.000)),
    wastage_pct     NUMERIC(6,3) NOT NULL DEFAULT 0 CHECK (wastage_pct >= 0 AND wastage_pct <= 100),
    unit_cost       NUMERIC(15,4) DEFAULT 0,
    notes           TEXT,
    display_order   SMALLINT    NOT NULL DEFAULT 0
);

CREATE INDEX idx_bom_lines_template ON production.bom_line_items(bom_template_id);

-- =============================================================================
-- SECTION 8: PRODUCTION STAGE TEMPLATES
-- =============================================================================

CREATE TABLE production.stage_templates (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    code            VARCHAR(60) NOT NULL,
    name            VARCHAR(200) NOT NULL,
    description     TEXT,
    default_duration_hrs NUMERIC(8,2),
    requires_qc     BOOLEAN     NOT NULL DEFAULT TRUE,
    requires_wastage_entry BOOLEAN NOT NULL DEFAULT TRUE,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (organization_id, code)
);

CREATE TABLE production.stage_template_sequences (
    id              BIGSERIAL   PRIMARY KEY,
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    sequence_name   VARCHAR(200) NOT NULL,  -- e.g. "Standard Silver Ring Workflow"
    stage_template_id UUID      NOT NULL REFERENCES production.stage_templates(id),
    sequence_order  SMALLINT    NOT NULL,
    is_mandatory    BOOLEAN     NOT NULL DEFAULT TRUE,
    UNIQUE (organization_id, sequence_name, sequence_order)
);

-- =============================================================================
-- SECTION 9: QUOTATIONS
-- =============================================================================

CREATE TABLE sales.quotations (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    quotation_number VARCHAR(40) NOT NULL UNIQUE,
    customer_id     UUID        NOT NULL REFERENCES core.parties(id),
    design_id       UUID        REFERENCES production.designs(id),
    bom_template_id UUID        REFERENCES production.bom_templates(id),
    version         SMALLINT    NOT NULL DEFAULT 1,
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- DRAFT, SUBMITTED, APPROVED, REJECTED, EXPIRED, CONVERTED
    title           VARCHAR(300),
    description     TEXT,
    valid_until     DATE        NOT NULL,
    subtotal        NUMERIC(15,2) NOT NULL DEFAULT 0,
    discount_pct    NUMERIC(6,3) DEFAULT 0 CHECK (discount_pct >= 0 AND discount_pct <= 100),
    discount_amount NUMERIC(15,2) DEFAULT 0,
    tax_amount      NUMERIC(15,2) DEFAULT 0,
    making_charges  NUMERIC(15,2) DEFAULT 0,
    total_amount    NUMERIC(15,2) NOT NULL DEFAULT 0,
    currency        VARCHAR(3)   NOT NULL DEFAULT 'INR',
    notes           TEXT,
    customer_notes  TEXT,       -- visible to customer
    approved_by     UUID        REFERENCES core.users(id),
    approved_at     TIMESTAMPTZ,
    rejection_reason TEXT,
    converted_to_order_id UUID, -- set when converted
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id),
    updated_by      UUID        REFERENCES core.users(id)
);

CREATE INDEX idx_quotations_branch   ON sales.quotations(branch_id);
CREATE INDEX idx_quotations_customer ON sales.quotations(customer_id);
CREATE INDEX idx_quotations_status   ON sales.quotations(status_id);
CREATE INDEX idx_quotations_expiry   ON sales.quotations(valid_until) WHERE status_id IS NOT NULL;

CREATE TABLE sales.quotation_line_items (
    id              BIGSERIAL   PRIMARY KEY,
    quotation_id    UUID        NOT NULL REFERENCES sales.quotations(id),
    line_number     SMALLINT    NOT NULL,
    description     VARCHAR(500) NOT NULL,
    material_id     UUID        REFERENCES inventory.materials(id),
    quantity        NUMERIC(15,4) NOT NULL CHECK (quantity > 0),
    uom_id          INT         NOT NULL REFERENCES core.lookup_values(id),
    unit_price      NUMERIC(15,4) NOT NULL CHECK (unit_price >= 0),
    line_total      NUMERIC(15,4) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    tax_rate        NUMERIC(5,2) DEFAULT 0,
    hsn_code        VARCHAR(10),
    notes           TEXT,
    UNIQUE (quotation_id, line_number)
);

-- Version history (FR-QT-05)
CREATE TABLE sales.quotation_versions (
    id              BIGSERIAL   PRIMARY KEY,
    quotation_id    UUID        NOT NULL REFERENCES sales.quotations(id),
    version_number  SMALLINT    NOT NULL,
    snapshot        JSONB       NOT NULL,  -- full JSON snapshot of quotation at that version
    changed_by      UUID        REFERENCES core.users(id),
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    change_reason   TEXT,
    UNIQUE (quotation_id, version_number)
);

-- =============================================================================
-- SECTION 10: ORDERS
-- =============================================================================

CREATE TABLE sales.orders (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    order_number    VARCHAR(40) NOT NULL UNIQUE,
    customer_id     UUID        NOT NULL REFERENCES core.parties(id),
    quotation_id    UUID        REFERENCES sales.quotations(id),
    design_id       UUID        REFERENCES production.designs(id),
    order_type_id   INT         NOT NULL REFERENCES core.lookup_values(id),  -- CUSTOM, CATALOG, REPAIR, BULK
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- DRAFT, CONFIRMED, IN_PRODUCTION, READY, DELIVERED, CANCELLED, CLOSED
    priority_id     INT         REFERENCES core.lookup_values(id),           -- NORMAL, HIGH, URGENT
    order_date      DATE        NOT NULL DEFAULT CURRENT_DATE,
    expected_delivery_date DATE NOT NULL,
    actual_delivery_date DATE,
    subtotal        NUMERIC(15,2) NOT NULL DEFAULT 0,
    discount_amount NUMERIC(15,2) DEFAULT 0,
    making_charges  NUMERIC(15,2) DEFAULT 0,
    tax_amount      NUMERIC(15,2) DEFAULT 0,
    total_amount    NUMERIC(15,2) NOT NULL DEFAULT 0,
    advance_paid    NUMERIC(15,2) DEFAULT 0,
    balance_due     NUMERIC(15,2) GENERATED ALWAYS AS (total_amount - advance_paid) STORED,
    currency        VARCHAR(3)   NOT NULL DEFAULT 'INR',
    special_instructions TEXT,
    approved_by     UUID        REFERENCES core.users(id),
    approved_at     TIMESTAMPTZ,
    version         SMALLINT    NOT NULL DEFAULT 1,
    is_locked       BOOLEAN     NOT NULL DEFAULT FALSE,  -- locked once production starts (BR-ORD-01)
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id),
    updated_by      UUID        REFERENCES core.users(id)
);

CREATE INDEX idx_orders_branch     ON sales.orders(branch_id);
CREATE INDEX idx_orders_customer   ON sales.orders(customer_id);
CREATE INDEX idx_orders_status     ON sales.orders(status_id);
CREATE INDEX idx_orders_delivery   ON sales.orders(expected_delivery_date);

CREATE TABLE sales.order_versions (
    id              BIGSERIAL   PRIMARY KEY,
    order_id        UUID        NOT NULL REFERENCES sales.orders(id),
    version_number  SMALLINT    NOT NULL,
    snapshot        JSONB       NOT NULL,
    changed_by      UUID        REFERENCES core.users(id),
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    change_reason   TEXT        NOT NULL,
    approved_by     UUID        REFERENCES core.users(id),
    approved_at     TIMESTAMPTZ,
    UNIQUE (order_id, version_number)
);

-- =============================================================================
-- SECTION 11: JOB CARDS & PRODUCTION WORKFLOW
-- =============================================================================

CREATE TABLE production.job_cards (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    order_id        UUID        REFERENCES sales.orders(id),
    parent_job_card_id UUID     REFERENCES production.job_cards(id),  -- child job cards (FR-JC-02)
    bom_template_id UUID        REFERENCES production.bom_templates(id),
    job_card_number VARCHAR(40) NOT NULL UNIQUE,
    job_type_id     INT         NOT NULL REFERENCES core.lookup_values(id),  -- REGULAR, REWORK, VENDOR_OUTSOURCE, REPAIR
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- DRAFT, PENDING_BOM_APPROVAL, BOM_APPROVED, IN_PROGRESS, ON_HOLD, QUALITY_CHECK, COMPLETED, CANCELLED
    priority_id     INT         REFERENCES core.lookup_values(id),
    template_source_id UUID     REFERENCES production.stage_templates(id),  -- if created from template
    design_version_id BIGINT    REFERENCES production.design_versions(id),
    assigned_to     UUID        REFERENCES core.users(id),           -- production manager
    planned_start_date DATE,
    planned_end_date   DATE,
    actual_start_date  DATE,
    actual_end_date    DATE,
    estimated_cost  NUMERIC(15,2) DEFAULT 0,
    actual_cost     NUMERIC(15,2) DEFAULT 0,
    completion_pct  NUMERIC(5,2) DEFAULT 0 CHECK (completion_pct BETWEEN 0 AND 100),
    approved_by     UUID        REFERENCES core.users(id),
    approved_at     TIMESTAMPTZ,
    released_by     UUID        REFERENCES core.users(id),   -- final release (FR-JC-08)
    released_at     TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id),
    updated_by      UUID        REFERENCES core.users(id)
);

CREATE INDEX idx_jc_branch      ON production.job_cards(branch_id);
CREATE INDEX idx_jc_order       ON production.job_cards(order_id);
CREATE INDEX idx_jc_parent      ON production.job_cards(parent_job_card_id);
CREATE INDEX idx_jc_status      ON production.job_cards(status_id);
CREATE INDEX idx_jc_assigned    ON production.job_cards(assigned_to);

-- Production stages for each job card (FR-JC-03)
CREATE TABLE production.job_card_stages (
    id              BIGSERIAL   PRIMARY KEY,
    job_card_id     UUID        NOT NULL REFERENCES production.job_cards(id),
    stage_template_id UUID      REFERENCES production.stage_templates(id),
    stage_order     SMALLINT    NOT NULL,
    stage_name      VARCHAR(200) NOT NULL,
    description     TEXT,
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- PENDING, IN_PROGRESS, QC_PENDING, QC_PASSED, QC_FAILED, COMPLETED, SKIPPED
    assigned_worker_id UUID     REFERENCES core.users(id),
    vendor_id       UUID        REFERENCES core.parties(id),  -- if outsourced (FR-JC-09)
    vendor_cost     NUMERIC(15,2),
    vendor_deadline DATE,
    vendor_ref_no   VARCHAR(100),
    planned_hours   NUMERIC(8,2),
    actual_hours    NUMERIC(8,2),
    estimated_cost  NUMERIC(15,2) DEFAULT 0,
    actual_cost     NUMERIC(15,2) DEFAULT 0,
    allowable_wastage_pct   NUMERIC(6,3) CHECK (allowable_wastage_pct BETWEEN 0 AND 100),
    allowable_wastage_grams NUMERIC(15,4),
    actual_wastage_grams    NUMERIC(15,4) DEFAULT 0 CHECK (actual_wastage_grams >= 0),
    wastage_approved_by     UUID        REFERENCES core.users(id),
    wastage_approved_at     TIMESTAMPTZ,
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    approved_by     UUID        REFERENCES core.users(id),   -- stage transition approval
    approved_at     TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (job_card_id, stage_order),
    -- vendor fields are mandatory when vendor is set (BR-JC-05)
    CHECK (vendor_id IS NULL OR (vendor_cost IS NOT NULL AND vendor_deadline IS NOT NULL AND vendor_ref_no IS NOT NULL))
);

CREATE INDEX idx_jc_stages_jc     ON production.job_card_stages(job_card_id);
CREATE INDEX idx_jc_stages_status ON production.job_card_stages(status_id);
CREATE INDEX idx_jc_stages_worker ON production.job_card_stages(assigned_worker_id);

-- Material allocations per stage (BOM tracking)
CREATE TABLE production.stage_material_allocations (
    id              BIGSERIAL   PRIMARY KEY,
    job_card_stage_id BIGINT    NOT NULL REFERENCES production.job_card_stages(id),
    lot_id          UUID        NOT NULL REFERENCES inventory.stock_lots(id),
    material_id     UUID        NOT NULL REFERENCES inventory.materials(id),
    bom_line_item_id BIGINT     REFERENCES production.bom_line_items(id),
    allocated_weight NUMERIC(15,4) NOT NULL CHECK (allocated_weight > 0),
    consumed_weight  NUMERIC(15,4) DEFAULT 0 CHECK (consumed_weight >= 0),
    returned_weight  NUMERIC(15,4) DEFAULT 0 CHECK (returned_weight >= 0),
    wastage_weight   NUMERIC(15,4) DEFAULT 0 CHECK (wastage_weight >= 0),
    allocation_status_id INT    NOT NULL REFERENCES core.lookup_values(id),  -- ALLOCATED, PARTIALLY_CONSUMED, FULLY_CONSUMED, RETURNED
    allocated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    allocated_by    UUID        REFERENCES core.users(id),
    notes           TEXT
);

CREATE INDEX idx_sma_stage    ON production.stage_material_allocations(job_card_stage_id);
CREATE INDEX idx_sma_lot      ON production.stage_material_allocations(lot_id);

-- Wastage records per stage
CREATE TABLE production.wastage_records (
    id              BIGSERIAL   PRIMARY KEY,
    job_card_stage_id BIGINT    NOT NULL REFERENCES production.job_card_stages(id),
    material_id     UUID        NOT NULL REFERENCES inventory.materials(id),
    wastage_type_id INT         NOT NULL REFERENCES core.lookup_values(id),  -- NORMAL, EXCESS, SCRAP
    wastage_grams   NUMERIC(15,4) NOT NULL CHECK (wastage_grams >= 0),
    wastage_pct     NUMERIC(6,3) NOT NULL CHECK (wastage_pct BETWEEN 0 AND 100),
    threshold_pct   NUMERIC(6,3),
    is_within_threshold BOOLEAN NOT NULL DEFAULT TRUE,
    deviation_pct   NUMERIC(8,4),  -- actual - threshold
    requires_approval BOOLEAN   NOT NULL DEFAULT FALSE,
    approved_by     UUID        REFERENCES core.users(id),
    approved_at     TIMESTAMPTZ,
    approval_comments TEXT,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    recorded_by     UUID        REFERENCES core.users(id)
);

CREATE INDEX idx_wastage_stage ON production.wastage_records(job_card_stage_id);

-- =============================================================================
-- SECTION 12: QUALITY CONTROL
-- =============================================================================

CREATE TABLE production.qc_checks (
    id              BIGSERIAL   PRIMARY KEY,
    job_card_stage_id BIGINT    NOT NULL REFERENCES production.job_card_stages(id),
    check_type_id   INT         NOT NULL REFERENCES core.lookup_values(id),  -- VISUAL, WEIGHT, PURITY, DIMENSIONS, FINISH
    check_name      VARCHAR(200) NOT NULL,
    expected_value  VARCHAR(200),
    actual_value    VARCHAR(200),
    result_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- PASS, FAIL, CONDITIONAL
    notes           TEXT,
    checked_by      UUID        NOT NULL REFERENCES core.users(id),
    checked_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE production.qc_results (
    id              BIGSERIAL   PRIMARY KEY,
    job_card_stage_id BIGINT    NOT NULL REFERENCES production.job_card_stages(id),
    inspector_id    UUID        NOT NULL REFERENCES core.users(id),
    overall_result_id INT       NOT NULL REFERENCES core.lookup_values(id),  -- PASS, FAIL, REWORK_REQUIRED
    rejection_reason TEXT       CHECK (
        -- BR-QC-01: rejection reason min 20 chars when failed
        overall_result_id NOT IN (SELECT id FROM core.lookup_values WHERE code = 'FAIL')
        OR (rejection_reason IS NOT NULL AND length(rejection_reason) >= 20)
    ),
    evidence_urls   JSONB,       -- array of image/video URLs
    inspected_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    rework_job_card_id UUID     REFERENCES production.job_cards(id),  -- BR-QC-02
    notes           TEXT
);

CREATE INDEX idx_qc_results_stage ON production.qc_results(job_card_stage_id);

-- =============================================================================
-- SECTION 13: INVOICING & PAYMENTS
-- =============================================================================

CREATE TABLE finance.invoices (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    order_id        UUID        REFERENCES sales.orders(id),
    job_card_id     UUID        REFERENCES production.job_cards(id),
    invoice_number  VARCHAR(40) NOT NULL UNIQUE,
    invoice_type_id INT         NOT NULL REFERENCES core.lookup_values(id),   -- GST, NON_GST, PROFORMA, CREDIT_NOTE, DEBIT_NOTE
    customer_id     UUID        NOT NULL REFERENCES core.parties(id),
    billing_address JSONB,
    shipping_address JSONB,
    supplier_gstin  VARCHAR(15) CHECK (supplier_gstin IS NULL OR supplier_gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
    customer_gstin  VARCHAR(15) CHECK (customer_gstin IS NULL OR customer_gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
    invoice_date    DATE        NOT NULL DEFAULT CURRENT_DATE,
    due_date        DATE,
    supply_type_id  INT         REFERENCES core.lookup_values(id),  -- B2B, B2C, EXPORT
    place_of_supply VARCHAR(50),
    subtotal        NUMERIC(15,2) NOT NULL DEFAULT 0,
    discount_amount NUMERIC(15,2) DEFAULT 0,
    taxable_amount  NUMERIC(15,2) NOT NULL DEFAULT 0,
    cgst_amount     NUMERIC(15,2) DEFAULT 0,
    sgst_amount     NUMERIC(15,2) DEFAULT 0,
    igst_amount     NUMERIC(15,2) DEFAULT 0,
    cess_amount     NUMERIC(15,2) DEFAULT 0,
    making_charges  NUMERIC(15,2) DEFAULT 0,
    total_amount    NUMERIC(15,2) NOT NULL DEFAULT 0,
    amount_paid     NUMERIC(15,2) NOT NULL DEFAULT 0,
    outstanding     NUMERIC(15,2) GENERATED ALWAYS AS (total_amount - amount_paid) STORED,
    currency        VARCHAR(3)   NOT NULL DEFAULT 'INR',
    exchange_rate   NUMERIC(15,6) NOT NULL DEFAULT 1,
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- DRAFT, PENDING_APPROVAL, APPROVED, DISPATCHED, PARTIALLY_PAID, PAID, CANCELLED, WRITTEN_OFF
    approved_by     UUID        REFERENCES core.users(id),
    approved_at     TIMESTAMPTZ,
    dispatched_at   TIMESTAMPTZ,
    notes           TEXT,
    terms_conditions TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id),
    updated_by      UUID        REFERENCES core.users(id)
);

CREATE INDEX idx_invoices_branch   ON finance.invoices(branch_id);
CREATE INDEX idx_invoices_customer ON finance.invoices(customer_id);
CREATE INDEX idx_invoices_status   ON finance.invoices(status_id);
CREATE INDEX idx_invoices_date     ON finance.invoices(invoice_date);

CREATE TABLE finance.invoice_line_items (
    id              BIGSERIAL   PRIMARY KEY,
    invoice_id      UUID        NOT NULL REFERENCES finance.invoices(id),
    line_number     SMALLINT    NOT NULL,
    description     VARCHAR(500) NOT NULL,
    material_id     UUID        REFERENCES inventory.materials(id),
    hsn_sac_code    VARCHAR(10),
    quantity        NUMERIC(15,4) NOT NULL CHECK (quantity > 0),
    uom_id          INT         REFERENCES core.lookup_values(id),
    unit_price      NUMERIC(15,4) NOT NULL CHECK (unit_price >= 0),
    discount_pct    NUMERIC(6,3) DEFAULT 0,
    taxable_amount  NUMERIC(15,4) GENERATED ALWAYS AS (quantity * unit_price * (1 - discount_pct/100)) STORED,
    gst_rate        NUMERIC(5,2) DEFAULT 0,
    cgst_rate       NUMERIC(5,2) DEFAULT 0,
    sgst_rate       NUMERIC(5,2) DEFAULT 0,
    igst_rate       NUMERIC(5,2) DEFAULT 0,
    line_total      NUMERIC(15,4) NOT NULL,
    UNIQUE (invoice_id, line_number)
);

-- Payments (FR-INV-05) — supports partial, FIFO (BR-INV-05)
CREATE TABLE finance.payments (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    payment_number  VARCHAR(40) NOT NULL UNIQUE,
    party_id        UUID        NOT NULL REFERENCES core.parties(id),
    payment_type_id INT         NOT NULL REFERENCES core.lookup_values(id),  -- RECEIPT, PAYMENT
    payment_mode_id INT         NOT NULL REFERENCES core.lookup_values(id),  -- CASH, BANK_TRANSFER, CHEQUE, UPI, BARTER
    amount          NUMERIC(15,2) NOT NULL CHECK (amount > 0),
    currency        VARCHAR(3)   NOT NULL DEFAULT 'INR',
    payment_date    DATE         NOT NULL DEFAULT CURRENT_DATE,
    bank_reference  VARCHAR(100),
    cheque_number   VARCHAR(30),
    cheque_date     DATE,
    utr_number      VARCHAR(50),
    is_material_credit BOOLEAN  NOT NULL DEFAULT FALSE,
    material_id     UUID        REFERENCES inventory.materials(id),       -- if barter/material credit
    material_purity NUMERIC(6,4) CHECK (material_purity IS NULL OR (material_purity >= 0.001 AND material_purity <= 1.000)),
    material_weight NUMERIC(15,4) CHECK (material_weight IS NULL OR material_weight > 0),
    material_cost_at_time NUMERIC(15,4),                                  -- BR-INV-04
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id),
    -- BR-INV-04: material credit fields mandatory together
    CHECK (
        (is_material_credit = FALSE)
        OR (material_id IS NOT NULL AND material_purity IS NOT NULL
            AND material_weight IS NOT NULL AND material_cost_at_time IS NOT NULL)
    )
);

CREATE INDEX idx_payments_party  ON finance.payments(party_id);
CREATE INDEX idx_payments_date   ON finance.payments(payment_date);

-- Payment-Invoice allocations (FIFO by default — BR-INV-05)
CREATE TABLE finance.payment_allocations (
    id              BIGSERIAL   PRIMARY KEY,
    payment_id      UUID        NOT NULL REFERENCES finance.payments(id),
    invoice_id      UUID        NOT NULL REFERENCES finance.invoices(id),
    allocated_amount NUMERIC(15,2) NOT NULL CHECK (allocated_amount > 0),
    is_manual_override BOOLEAN  NOT NULL DEFAULT FALSE,
    override_approved_by UUID   REFERENCES core.users(id),
    allocated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    allocated_by    UUID        REFERENCES core.users(id),
    UNIQUE (payment_id, invoice_id)
);

-- Loans, EMIs, Chit Funds (FR-INV-06)
CREATE TABLE finance.loans_and_funds (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    fund_type_id    INT         NOT NULL REFERENCES core.lookup_values(id),  -- LOAN, EMI, CHIT_FUND
    direction_id    INT         NOT NULL REFERENCES core.lookup_values(id),  -- PAYABLE, RECEIVABLE
    party_id        UUID        REFERENCES core.parties(id),
    reference_number VARCHAR(80),
    principal_amount NUMERIC(15,2) NOT NULL CHECK (principal_amount > 0),
    interest_rate   NUMERIC(6,3),
    tenure_months   SMALLINT,
    start_date      DATE        NOT NULL,
    end_date        DATE,
    outstanding_amount NUMERIC(15,2),
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id)
);

-- =============================================================================
-- SECTION 14: DELIVERY & RETURNS (RMA)
-- =============================================================================

CREATE TABLE sales.delivery_challans (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    order_id        UUID        NOT NULL REFERENCES sales.orders(id),
    invoice_id      UUID        NOT NULL REFERENCES finance.invoices(id),
    challan_number  VARCHAR(40) NOT NULL UNIQUE,
    customer_id     UUID        NOT NULL REFERENCES core.parties(id),
    delivery_type_id INT        NOT NULL REFERENCES core.lookup_values(id),  -- STANDARD, EXPRESS, SELF_PICKUP
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- DRAFT, APPROVED, DISPATCHED, DELIVERED, RETURNED
    shipping_address JSONB,
    logistics_partner VARCHAR(200),
    tracking_number VARCHAR(100),
    dispatch_date   DATE,
    expected_delivery_date DATE,
    actual_delivery_date DATE,
    delivered_by    VARCHAR(200),
    receiver_name   VARCHAR(200),
    receiver_signature_url TEXT,
    customer_feedback TEXT,
    customer_rating SMALLINT CHECK (customer_rating BETWEEN 1 AND 5),
    approved_by     UUID        REFERENCES core.users(id),
    approved_at     TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id)
);

CREATE TABLE sales.rma_requests (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    rma_number      VARCHAR(40) NOT NULL UNIQUE,
    order_id        UUID        NOT NULL REFERENCES sales.orders(id),
    delivery_challan_id UUID    NOT NULL REFERENCES sales.delivery_challans(id),
    customer_id     UUID        NOT NULL REFERENCES core.parties(id),
    return_reason_id INT        NOT NULL REFERENCES core.lookup_values(id),  -- DEFECTIVE, WRONG_ITEM, DESIGN_MISMATCH, OTHER
    return_description TEXT     NOT NULL,
    delivery_date   DATE        NOT NULL,  -- used for 90-day check (BR-DEL-02)
    rma_request_date DATE       NOT NULL DEFAULT CURRENT_DATE,
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- REQUESTED, AUTHORIZED, RECEIVED, INSPECTED, RESOLVED, REJECTED
    disposition_id  INT         REFERENCES core.lookup_values(id),           -- REPAIR, REPLACE, REJECT
    inspection_notes TEXT,
    resolution_notes TEXT,
    authorized_by   UUID        REFERENCES core.users(id),
    authorized_at   TIMESTAMPTZ,
    extension_approved_by UUID  REFERENCES core.users(id),  -- if > 90 days
    extension_reason TEXT,
    qc_result_id    INT         REFERENCES core.lookup_values(id),
    inspected_by    UUID        REFERENCES core.users(id),
    inspected_at    TIMESTAMPTZ,
    resolved_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id)
);

CREATE INDEX idx_rma_order    ON sales.rma_requests(order_id);
CREATE INDEX idx_rma_customer ON sales.rma_requests(customer_id);

-- =============================================================================
-- SECTION 15: EMPLOYEE MANAGEMENT & PAYROLL
-- =============================================================================

CREATE TABLE hr.employees (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    employee_number VARCHAR(30) NOT NULL UNIQUE,
    user_id         UUID        REFERENCES core.users(id),
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    middle_name     VARCHAR(100),
    date_of_birth   DATE,
    gender_id       INT         REFERENCES core.lookup_values(id),
    aadhaar_number  VARCHAR(12) CHECK (aadhaar_number IS NULL OR aadhaar_number ~ '^[0-9]{12}$'),
    pan             VARCHAR(10) CHECK (pan IS NULL OR pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
    phone           VARCHAR(20) NOT NULL,
    alternate_phone VARCHAR(20),
    email           VARCHAR(200),
    address_line1   VARCHAR(300),
    city            VARCHAR(100),
    state           VARCHAR(100),
    pincode         VARCHAR(10),
    designation_id  INT         NOT NULL REFERENCES core.lookup_values(id),
    department_id   INT         NOT NULL REFERENCES core.lookup_values(id),
    employment_type_id INT      NOT NULL REFERENCES core.lookup_values(id),  -- FULL_TIME, PART_TIME, CONTRACT, ARTISAN_DAILY
    bank_name       VARCHAR(200),
    bank_account_no VARCHAR(30),
    bank_ifsc       VARCHAR(15) CHECK (bank_ifsc IS NULL OR bank_ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
    pf_number       VARCHAR(30),
    esi_number      VARCHAR(30),
    joining_date    DATE        NOT NULL,
    confirmation_date DATE,
    exit_date       DATE,
    exit_reason_id  INT         REFERENCES core.lookup_values(id),
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- ACTIVE, ON_LEAVE, RESIGNED, TERMINATED
    emergency_contact_name VARCHAR(200),
    emergency_contact_phone VARCHAR(20),
    skills          JSONB,                   -- array of skill codes
    certifications  JSONB,                   -- array of cert objects
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id),
    -- BR-HR-04: mandatory fields
    CHECK (aadhaar_number IS NOT NULL AND pan IS NOT NULL AND bank_account_no IS NOT NULL)
);

CREATE INDEX idx_employees_branch ON hr.employees(branch_id);
CREATE INDEX idx_employees_status ON hr.employees(status_id);

CREATE TABLE hr.employee_skill_sets (
    id              BIGSERIAL   PRIMARY KEY,
    employee_id     UUID        NOT NULL REFERENCES hr.employees(id),
    skill_id        INT         NOT NULL REFERENCES core.lookup_values(id),  -- CASTING, FILING, POLISHING, STONE_SETTING...
    proficiency_id  INT         NOT NULL REFERENCES core.lookup_values(id),  -- BEGINNER, INTERMEDIATE, EXPERT
    certified_at    DATE,
    certificate_url TEXT,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    UNIQUE (employee_id, skill_id)
);

-- Attendance (FR-EMP-02)
CREATE TABLE hr.attendance (
    id              BIGSERIAL   PRIMARY KEY,
    employee_id     UUID        NOT NULL REFERENCES hr.employees(id),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    attendance_date DATE        NOT NULL,
    shift_id        INT         REFERENCES core.lookup_values(id),
    check_in        TIMESTAMPTZ,
    check_out       TIMESTAMPTZ,
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- PRESENT, ABSENT, HALF_DAY, ON_LEAVE, HOLIDAY, WEEK_OFF
    overtime_hours  NUMERIC(5,2) DEFAULT 0 CHECK (overtime_hours >= 0),
    biometric_ref   VARCHAR(100),
    is_finalized    BOOLEAN     NOT NULL DEFAULT FALSE,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (employee_id, attendance_date)
);

CREATE INDEX idx_attendance_emp    ON hr.attendance(employee_id);
CREATE INDEX idx_attendance_date   ON hr.attendance(attendance_date);
CREATE INDEX idx_attendance_branch ON hr.attendance(branch_id);

-- Leave management
CREATE TABLE hr.leave_types (
    id              SERIAL      PRIMARY KEY,
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    code            VARCHAR(30) NOT NULL,
    name            VARCHAR(100) NOT NULL,
    max_days_per_year NUMERIC(5,1),
    is_paid         BOOLEAN     NOT NULL DEFAULT TRUE,
    carry_forward   BOOLEAN     NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    UNIQUE (organization_id, code)
);

CREATE TABLE hr.leave_requests (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    employee_id     UUID        NOT NULL REFERENCES hr.employees(id),
    leave_type_id   INT         NOT NULL REFERENCES hr.leave_types(id),
    from_date       DATE        NOT NULL,
    to_date         DATE        NOT NULL,
    total_days      NUMERIC(5,1) NOT NULL CHECK (total_days > 0),
    reason          TEXT,
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- PENDING, APPROVED, REJECTED, CANCELLED
    approved_by     UUID        REFERENCES core.users(id),
    approved_at     TIMESTAMPTZ,
    rejection_reason TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (to_date >= from_date)
);

-- Salary components (configurable — FR-EMP-03)
CREATE TABLE hr.salary_components (
    id              SERIAL      PRIMARY KEY,
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    code            VARCHAR(40) NOT NULL,
    name            VARCHAR(200) NOT NULL,
    component_type_id INT       NOT NULL REFERENCES core.lookup_values(id),  -- EARNING, DEDUCTION
    calculation_type_id INT     NOT NULL REFERENCES core.lookup_values(id),  -- FIXED, PERCENTAGE_OF_BASIC, FORMULA
    formula         TEXT,        -- expression evaluated at payroll time
    is_taxable      BOOLEAN     NOT NULL DEFAULT TRUE,
    is_pf_applicable BOOLEAN   NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    display_order   SMALLINT    NOT NULL DEFAULT 0,
    UNIQUE (organization_id, code)
);

-- Employee salary structures
CREATE TABLE hr.employee_salary_structures (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    employee_id     UUID        NOT NULL REFERENCES hr.employees(id),
    effective_from  DATE        NOT NULL,
    effective_to    DATE,
    basic_salary    NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    approved_by     UUID        REFERENCES core.users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE hr.employee_salary_component_values (
    id              BIGSERIAL   PRIMARY KEY,
    salary_structure_id UUID    NOT NULL REFERENCES hr.employee_salary_structures(id),
    component_id    INT         NOT NULL REFERENCES hr.salary_components(id),
    value           NUMERIC(12,2) NOT NULL CHECK (value >= 0),
    UNIQUE (salary_structure_id, component_id)
);

-- Payroll runs (FR-EMP-04)
CREATE TABLE hr.payroll_runs (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    pay_period_month SMALLINT   NOT NULL CHECK (pay_period_month BETWEEN 1 AND 12),
    pay_period_year  SMALLINT   NOT NULL CHECK (pay_period_year >= 2020),
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- DRAFT, PENDING_APPROVAL, APPROVED, DISBURSED, CANCELLED
    attendance_finalized BOOLEAN NOT NULL DEFAULT FALSE,
    total_gross     NUMERIC(15,2),
    total_deductions NUMERIC(15,2),
    total_net       NUMERIC(15,2),
    approved_by     UUID        REFERENCES core.users(id),
    approved_at     TIMESTAMPTZ,
    disbursed_at    TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id),
    UNIQUE (branch_id, pay_period_month, pay_period_year)
);

CREATE TABLE hr.payslips (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    payroll_run_id  UUID        NOT NULL REFERENCES hr.payroll_runs(id),
    employee_id     UUID        NOT NULL REFERENCES hr.employees(id),
    days_present    NUMERIC(5,1) NOT NULL DEFAULT 0,
    days_absent     NUMERIC(5,1) NOT NULL DEFAULT 0,
    days_leave      NUMERIC(5,1) NOT NULL DEFAULT 0,
    overtime_hours  NUMERIC(8,2) NOT NULL DEFAULT 0,
    gross_pay       NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    total_deductions NUMERIC(12,2) NOT NULL CHECK (total_deductions >= 0),
    net_pay         NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),  -- BR-HR-02
    pf_employee     NUMERIC(12,2) DEFAULT 0,
    pf_employer     NUMERIC(12,2) DEFAULT 0,
    esi_employee    NUMERIC(12,2) DEFAULT 0,
    esi_employer    NUMERIC(12,2) DEFAULT 0,
    tds             NUMERIC(12,2) DEFAULT 0,
    advance_deducted NUMERIC(12,2) DEFAULT 0,
    component_breakdown JSONB,   -- detailed earning/deduction breakdown
    payment_status_id INT       NOT NULL REFERENCES core.lookup_values(id),  -- PENDING, PAID, HELD
    payment_date    DATE,
    bank_reference  VARCHAR(100),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (payroll_run_id, employee_id)
);

-- =============================================================================
-- SECTION 16: ACCOUNTING & GST
-- =============================================================================

CREATE TABLE finance.account_groups (
    id              SERIAL      PRIMARY KEY,
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    parent_id       INT         REFERENCES finance.account_groups(id),
    code            VARCHAR(30) NOT NULL,
    name            VARCHAR(200) NOT NULL,
    group_type_id   INT         NOT NULL REFERENCES core.lookup_values(id),  -- ASSET, LIABILITY, EQUITY, INCOME, EXPENSE
    is_system       BOOLEAN     NOT NULL DEFAULT FALSE,
    UNIQUE (organization_id, code)
);

CREATE TABLE finance.chart_of_accounts (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    branch_id       UUID        REFERENCES core.branches(id),  -- NULL = org-level
    account_group_id INT        NOT NULL REFERENCES finance.account_groups(id),
    account_code    VARCHAR(30) NOT NULL,
    name            VARCHAR(200) NOT NULL,
    account_type_id INT         NOT NULL REFERENCES core.lookup_values(id),  -- BANK, CASH, DEBTORS, CREDITORS, STOCK, SALES, PURCHASE...
    opening_balance NUMERIC(18,4) DEFAULT 0,
    current_balance NUMERIC(18,4) NOT NULL DEFAULT 0,  -- denormalized, updated by triggers
    currency        VARCHAR(3)   NOT NULL DEFAULT 'INR',
    gstin           VARCHAR(15),
    is_system       BOOLEAN     NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (organization_id, account_code)
);

CREATE INDEX idx_coa_branch ON finance.chart_of_accounts(branch_id);

-- Journal entries (double-entry bookkeeping)
CREATE TABLE finance.journal_entries (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    entry_number    VARCHAR(40) NOT NULL UNIQUE,
    entry_type_id   INT         NOT NULL REFERENCES core.lookup_values(id),   -- PURCHASE, SALE, PAYMENT, RECEIPT, ADJUSTMENT, OPENING
    entry_date      DATE        NOT NULL,
    reference_type  VARCHAR(60),  -- 'invoice', 'payment', 'stock_inward', etc.
    reference_id    UUID,
    narration       TEXT        NOT NULL,
    total_debit     NUMERIC(18,4) NOT NULL CHECK (total_debit >= 0),
    total_credit    NUMERIC(18,4) NOT NULL CHECK (total_credit >= 0),
    is_balanced     BOOLEAN     GENERATED ALWAYS AS (ABS(total_debit - total_credit) < 0.01) STORED,
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- DRAFT, POSTED, REVERSED
    is_backdated    BOOLEAN     NOT NULL DEFAULT FALSE,
    posted_by       UUID        REFERENCES core.users(id),
    posted_at       TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      UUID        REFERENCES core.users(id)
);

CREATE INDEX idx_je_branch ON finance.journal_entries(branch_id);
CREATE INDEX idx_je_date   ON finance.journal_entries(entry_date);
CREATE INDEX idx_je_ref    ON finance.journal_entries(reference_type, reference_id);

CREATE TABLE finance.journal_entry_lines (
    id              BIGSERIAL   PRIMARY KEY,
    journal_entry_id UUID       NOT NULL REFERENCES finance.journal_entries(id),
    account_id      UUID        NOT NULL REFERENCES finance.chart_of_accounts(id),
    line_number     SMALLINT    NOT NULL,
    debit_amount    NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (debit_amount >= 0),
    credit_amount   NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (credit_amount >= 0),
    narration       TEXT,
    CHECK (NOT (debit_amount > 0 AND credit_amount > 0)),  -- a line is either debit or credit
    UNIQUE (journal_entry_id, line_number)
);

-- Financial periods (monthly close — BR-ACC-01)
CREATE TABLE finance.financial_periods (
    id              SERIAL      PRIMARY KEY,
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    period_month    SMALLINT    NOT NULL CHECK (period_month BETWEEN 1 AND 12),
    period_year     SMALLINT    NOT NULL CHECK (period_year >= 2020),
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- OPEN, CLOSING_INITIATED, CLOSED
    closed_by       UUID        REFERENCES core.users(id),
    closed_at       TIMESTAMPTZ,
    notes           TEXT,
    UNIQUE (branch_id, period_month, period_year)
);

-- =============================================================================
-- SECTION 17: APPROVAL WORKFLOWS
-- =============================================================================

CREATE TABLE core.approval_workflows (
    id              SERIAL      PRIMARY KEY,
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    entity_type     VARCHAR(80) NOT NULL,   -- 'stock_inward', 'quotation', 'invoice', etc.
    name            VARCHAR(200) NOT NULL,
    description     TEXT,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (organization_id, entity_type)
);

CREATE TABLE core.approval_workflow_steps (
    id              SERIAL      PRIMARY KEY,
    workflow_id     INT         NOT NULL REFERENCES core.approval_workflows(id),
    step_order      SMALLINT    NOT NULL,
    step_name       VARCHAR(200) NOT NULL,
    approver_role_id UUID       NOT NULL REFERENCES core.roles(id),
    amount_threshold NUMERIC(15,2),    -- if amount > threshold, this step is required
    is_mandatory    BOOLEAN     NOT NULL DEFAULT TRUE,
    auto_approve_after_hours INT,       -- auto-approve SLA
    UNIQUE (workflow_id, step_order)
);

-- Approval requests (all workflows converge here)
CREATE TABLE core.approval_requests (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    workflow_id     INT         NOT NULL REFERENCES core.approval_workflows(id),
    entity_type     VARCHAR(80) NOT NULL,
    entity_id       UUID        NOT NULL,
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    current_step    SMALLINT    NOT NULL DEFAULT 1,
    status_id       INT         NOT NULL REFERENCES core.lookup_values(id),  -- PENDING, APPROVED, REJECTED, RECALLED, ESCALATED
    initiated_by    UUID        NOT NULL REFERENCES core.users(id),
    initiated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ,
    comments        TEXT
);

CREATE INDEX idx_approval_req_entity ON core.approval_requests(entity_type, entity_id);
CREATE INDEX idx_approval_req_status ON core.approval_requests(status_id);

CREATE TABLE core.approval_actions (
    id              BIGSERIAL   PRIMARY KEY,
    request_id      UUID        NOT NULL REFERENCES core.approval_requests(id),
    step_id         INT         NOT NULL REFERENCES core.approval_workflow_steps(id),
    action_id       INT         NOT NULL REFERENCES core.lookup_values(id),   -- APPROVED, REJECTED, ESCALATED, RECALLED
    actioned_by     UUID        NOT NULL REFERENCES core.users(id),
    actioned_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    comments        TEXT,                                                      -- mandatory on rejection
    -- BR-ORG-03: Self-approval check enforced by application layer + trigger
    CHECK (comments IS NOT NULL OR action_id NOT IN (SELECT id FROM core.lookup_values WHERE code = 'REJECTED'))
);

CREATE INDEX idx_approval_actions_req ON core.approval_actions(request_id);

-- Notification log for approvals and alerts
CREATE TABLE core.notifications (
    id              BIGSERIAL   PRIMARY KEY,
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    user_id         UUID        NOT NULL REFERENCES core.users(id),
    notification_type_id INT    NOT NULL REFERENCES core.lookup_values(id),   -- APPROVAL_REQUIRED, BLACKLIST_ALERT, STOCK_LOW, WASTAGE_EXCEEDED etc.
    title           VARCHAR(300) NOT NULL,
    message         TEXT        NOT NULL,
    entity_type     VARCHAR(80),
    entity_id       UUID,
    is_read         BOOLEAN     NOT NULL DEFAULT FALSE,
    read_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_notifications_user   ON core.notifications(user_id) WHERE NOT is_read;
CREATE INDEX idx_notifications_type   ON core.notifications(notification_type_id);

-- =============================================================================
-- SECTION 18: AUDIT LOG (IMMUTABLE — BR-ACC-04, FR-AUD-*)
-- =============================================================================

CREATE TABLE audit.activity_logs (
    id              BIGSERIAL   PRIMARY KEY,
    organization_id UUID        NOT NULL,
    branch_id       UUID,
    user_id         UUID,
    username        VARCHAR(80),    -- denormalized to survive user deletion
    user_ip         INET,
    user_agent      TEXT,
    session_id      VARCHAR(100),
    action_code     VARCHAR(80)  NOT NULL,  -- CREATE, UPDATE, DELETE, APPROVE, REJECT, LOGIN, LOGOUT...
    entity_type     VARCHAR(80)  NOT NULL,
    entity_id       TEXT,
    before_snapshot JSONB,          -- state before change
    after_snapshot  JSONB,          -- state after change
    diff            JSONB,          -- computed diff of changed fields
    module_code     VARCHAR(60),
    result_code     VARCHAR(20) NOT NULL DEFAULT 'SUCCESS',  -- SUCCESS, FAILURE, BLOCKED
    failure_reason  TEXT,
    logged_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
    -- NO primary key update/delete allowed; enforced via RLS or table ownership
);

-- Partition by month for performance (10M+ records — NFR-SC-02)
-- Example: audit.activity_logs_2025_01, _2025_02 etc. created by partition management job.
-- Using non-partitioned for simplicity; add partitioning in production.

CREATE INDEX idx_audit_org      ON audit.activity_logs(organization_id);
CREATE INDEX idx_audit_user     ON audit.activity_logs(user_id);
CREATE INDEX idx_audit_entity   ON audit.activity_logs(entity_type, entity_id);
CREATE INDEX idx_audit_date     ON audit.activity_logs(logged_at);
CREATE INDEX idx_audit_action   ON audit.activity_logs(action_code);

-- Revoke update/delete from all roles to enforce immutability (BR-ACC-04)
REVOKE UPDATE, DELETE ON audit.activity_logs FROM PUBLIC;

-- User sessions (security)
CREATE TABLE audit.user_sessions (
    id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID        NOT NULL REFERENCES core.users(id),
    session_token   TEXT        NOT NULL UNIQUE,
    ip_address      INET,
    user_agent      TEXT,
    logged_in_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_active_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    logged_out_at   TIMESTAMPTZ,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    invalidation_reason VARCHAR(100)
);

CREATE INDEX idx_sessions_user   ON audit.user_sessions(user_id) WHERE is_active;
CREATE INDEX idx_sessions_token  ON audit.user_sessions(session_token);

-- =============================================================================
-- SECTION 19: SYSTEM CONFIGURATION
-- =============================================================================

CREATE TABLE core.system_settings (
    id              SERIAL      PRIMARY KEY,
    organization_id UUID        NOT NULL REFERENCES core.organizations(id),
    branch_id       UUID        REFERENCES core.branches(id),
    setting_key     VARCHAR(100) NOT NULL,
    setting_value   JSONB       NOT NULL,
    description     TEXT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by      UUID        REFERENCES core.users(id),
    UNIQUE (organization_id, branch_id, setting_key)
);

-- Barcode / QR sequences per branch
CREATE TABLE core.document_sequences (
    id              SERIAL      PRIMARY KEY,
    branch_id       UUID        NOT NULL REFERENCES core.branches(id),
    document_type   VARCHAR(60) NOT NULL,   -- QUOTATION, ORDER, JOB_CARD, INVOICE, PAYMENT, CHALLAN, TRANSFER
    prefix          VARCHAR(20),
    suffix          VARCHAR(20),
    current_value   BIGINT      NOT NULL DEFAULT 0,
    min_digits      SMALLINT    NOT NULL DEFAULT 6,
    reset_on        VARCHAR(20),            -- YEARLY, MONTHLY, NEVER
    last_reset_at   TIMESTAMPTZ,
    UNIQUE (branch_id, document_type)
);

-- =============================================================================
-- SECTION 20: ANALYTICS SUPPORT (denormalized fact tables for dashboards)
-- =============================================================================

CREATE TABLE production.job_card_analytics_snapshots (
    id              BIGSERIAL   PRIMARY KEY,
    job_card_id     UUID        NOT NULL REFERENCES production.job_cards(id),
    snapshot_date   DATE        NOT NULL DEFAULT CURRENT_DATE,
    completion_pct  NUMERIC(5,2),
    stages_total    SMALLINT,
    stages_done     SMALLINT,
    stages_in_qc    SMALLINT,
    total_material_allocated NUMERIC(15,4),
    total_material_consumed  NUMERIC(15,4),
    total_wastage   NUMERIC(15,4),
    estimated_cost  NUMERIC(15,2),
    actual_cost     NUMERIC(15,2),
    is_on_schedule  BOOLEAN,
    bottleneck_stage SMALLINT,
    UNIQUE (job_card_id, snapshot_date)
);

-- =============================================================================
-- =============================================================================
-- SEED DATA — LOOKUP CATEGORIES & VALUES
-- =============================================================================
-- =============================================================================

-- ---------------------------------------------------------------
-- Lookup Categories
-- ---------------------------------------------------------------
INSERT INTO core.lookup_categories (code, name, description) VALUES
  ('BRANCH_TYPE',          'Branch Type',                  'Organization hierarchy node types'),
  ('PARTY_TYPE',           'Party Type',                   'Supplier, Vendor, Customer classifications'),
  ('PARTY_STATUS',         'Party Status',                 'Active, Inactive, Blacklisted'),
  ('PARTY_TAG',            'Party Tag',                    'User-defined tags for parties'),
  ('PAYMENT_TERMS',        'Payment Terms',                'Net 30, Advance, etc.'),
  ('UOM',                  'Unit of Measure',              'Gram, KG, Piece, Carat, etc.'),
  ('MATERIAL_TYPE',        'Material Type',                'Precious Metal, Stone, Tool, etc.'),
  ('INWARD_STATUS',        'Stock Inward Status',          'Pending, Approved, Rejected'),
  ('ALLOCATION_STATUS',    'Allocation Status',            'Allocated, Consumed, Returned'),
  ('TRANSFER_STATUS',      'Branch Transfer Status',       'Draft to Received'),
  ('DESIGN_TYPE',          'Design Type',                  'Catalog, Custom, Bespoke'),
  ('DESIGN_STATUS',        'Design Status',                'Draft, Review, Approved, Archived'),
  ('BOM_STATUS',           'BOM Status',                   'Draft, Pending Approval, Approved, Obsolete'),
  ('BOM_COMPONENT_TYPE',   'BOM Component Type',           'Precious Metal, Stone, Tool, Labor'),
  ('QC_CHECK_TYPE',        'QC Check Type',                'Visual, Weight, Purity, Dimensions'),
  ('QC_RESULT',            'QC Result',                    'Pass, Fail, Conditional'),
  ('JOB_TYPE',             'Job Card Type',                'Regular, Rework, Vendor, Repair'),
  ('JOB_STATUS',           'Job Card Status',              'All job card lifecycle statuses'),
  ('STAGE_STATUS',         'Stage Status',                 'All production stage statuses'),
  ('WASTAGE_TYPE',         'Wastage Type',                 'Normal, Excess, Scrap'),
  ('ORDER_TYPE',           'Order Type',                   'Custom, Catalog, Repair, Bulk'),
  ('ORDER_STATUS',         'Order Status',                 'Draft to Closed'),
  ('QUOTATION_STATUS',     'Quotation Status',             'Draft to Converted'),
  ('INVOICE_TYPE',         'Invoice Type',                 'GST, Non-GST, Proforma, Credit, Debit'),
  ('INVOICE_STATUS',       'Invoice Status',               'Draft to Written Off'),
  ('SUPPLY_TYPE',          'GST Supply Type',              'B2B, B2C, Export'),
  ('PAYMENT_TYPE',         'Payment Type',                 'Receipt or Payment'),
  ('PAYMENT_MODE',         'Payment Mode',                 'Cash, Bank, Cheque, UPI, Barter'),
  ('PAYMENT_STATUS',       'Payment Status',               'Pending, Cleared, Bounced'),
  ('FUND_TYPE',            'Fund Type',                    'Loan, EMI, Chit Fund'),
  ('DIRECTION',            'Direction',                    'Payable or Receivable'),
  ('DELIVERY_TYPE',        'Delivery Type',                'Standard, Express, Self Pickup'),
  ('DELIVERY_STATUS',      'Delivery Status',              'Draft to Returned'),
  ('RETURN_REASON',        'Return Reason',                'Defective, Wrong Item, etc.'),
  ('RMA_STATUS',           'RMA Status',                   'Requested to Resolved'),
  ('DISPOSITION',          'RMA Disposition',              'Repair, Replace, Reject'),
  ('GENDER',               'Gender',                       'Employee gender options'),
  ('DESIGNATION',          'Designation',                  'Employee designations'),
  ('DEPARTMENT',           'Department',                   'Organization departments'),
  ('EMPLOYMENT_TYPE',      'Employment Type',              'Full Time, Part Time, Contract'),
  ('EXIT_REASON',          'Exit Reason',                  'Resignation, Termination, etc.'),
  ('EMPLOYEE_STATUS',      'Employee Status',              'Active, On Leave, Resigned'),
  ('LEAVE_STATUS',         'Leave Request Status',         'Pending, Approved, Rejected'),
  ('ATTENDANCE_STATUS',    'Attendance Status',            'Present, Absent, Half Day, etc.'),
  ('SHIFT',                'Shift',                        'Morning, General, Night'),
  ('SALARY_COMPONENT_TYPE','Salary Component Type',        'Earning or Deduction'),
  ('CALC_TYPE',            'Salary Calculation Type',      'Fixed, Percentage, Formula'),
  ('PAYROLL_STATUS',       'Payroll Run Status',           'Draft to Disbursed'),
  ('PAYSLIP_STATUS',       'Payslip Payment Status',       'Pending, Paid, Held'),
  ('ACCOUNT_TYPE',         'Account Type',                 'Bank, Cash, Debtors, etc.'),
  ('ACCOUNT_GROUP_TYPE',   'Account Group Type',           'Asset, Liability, Equity, Income, Expense'),
  ('JOURNAL_TYPE',         'Journal Entry Type',           'Purchase, Sale, Payment, etc.'),
  ('JOURNAL_STATUS',       'Journal Status',               'Draft, Posted, Reversed'),
  ('PERIOD_STATUS',        'Financial Period Status',      'Open, Closing, Closed'),
  ('APPROVAL_STATUS',      'Approval Status',              'Pending, Approved, Rejected, Recalled'),
  ('APPROVAL_ACTION',      'Approval Action',              'Approved, Rejected, Escalated, Recalled'),
  ('NOTIFICATION_TYPE',    'Notification Type',            'All system alert categories'),
  ('SKILL',                'Employee Skill',               'Artisan skill codes'),
  ('PROFICIENCY',          'Skill Proficiency',            'Beginner, Intermediate, Expert'),
  ('PERMISSION_MODULE',    'Permission Module',            'All RBAC modules'),
  ('VERSION_STATUS',       'Design Version Status',        'Draft, Submitted, Approved, Rejected'),
  ('PRIORITY',             'Priority Level',               'Normal, High, Urgent'),
  ('CONTACT_TYPE',         'Contact Address Type',         'Billing, Shipping, Other'),
  ('FUND_STATUS',          'Loan/Fund Status',             'Active, Closed, Defaulted');

-- ---------------------------------------------------------------
-- Lookup Values
-- ---------------------------------------------------------------

-- BRANCH_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='BRANCH_TYPE'), 'HEAD_OFFICE',         'Head Office',          1),
  ((SELECT id FROM core.lookup_categories WHERE code='BRANCH_TYPE'), 'BRANCH',               'Branch',               2),
  ((SELECT id FROM core.lookup_categories WHERE code='BRANCH_TYPE'), 'MANUFACTURING_UNIT',   'Manufacturing Unit',   3),
  ((SELECT id FROM core.lookup_categories WHERE code='BRANCH_TYPE'), 'WAREHOUSE',            'Warehouse',            4);

-- PARTY_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_TYPE'), 'SUPPLIER',  'Supplier',          1),
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_TYPE'), 'VENDOR',    'Vendor (Outsource)', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_TYPE'), 'CUSTOMER',  'Customer',           3),
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_TYPE'), 'SUPPLIER_VENDOR', 'Supplier & Vendor', 4);

-- PARTY_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_STATUS'), 'ACTIVE',      'Active',      1),
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_STATUS'), 'INACTIVE',    'Inactive',    2),
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_STATUS'), 'BLACKLISTED', 'Blacklisted', 3);

-- PARTY_TAG
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_TAG'), 'SILVER_SUPPLIER', 'Silver Supplier',  1),
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_TAG'), 'GOLD_SUPPLIER',   'Gold Supplier',    2),
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_TAG'), 'DIAMOND_SUPPLIER','Diamond Supplier', 3),
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_TAG'), 'B2B_CUSTOMER',    'B2B Customer',     4),
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_TAG'), 'RETAIL_CUSTOMER', 'Retail Customer',  5),
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_TAG'), 'EXPORT_CUSTOMER', 'Export Customer',  6),
  ((SELECT id FROM core.lookup_categories WHERE code='PARTY_TAG'), 'ARTISAN_VENDOR',  'Artisan Vendor',   7);

-- PAYMENT_TERMS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_TERMS'), 'ADVANCE',  'Full Advance',  1),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_TERMS'), 'NET_7',    'Net 7 Days',    2),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_TERMS'), 'NET_15',   'Net 15 Days',   3),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_TERMS'), 'NET_30',   'Net 30 Days',   4),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_TERMS'), 'NET_45',   'Net 45 Days',   5),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_TERMS'), 'NET_60',   'Net 60 Days',   6),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_TERMS'), 'BARTER',   'Barter/Material',7);

-- UOM
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='UOM'), 'GRAM',   'Gram (g)',   1),
  ((SELECT id FROM core.lookup_categories WHERE code='UOM'), 'KG',     'Kilogram',   2),
  ((SELECT id FROM core.lookup_categories WHERE code='UOM'), 'PIECE',  'Piece',      3),
  ((SELECT id FROM core.lookup_categories WHERE code='UOM'), 'CARAT',  'Carat',      4),
  ((SELECT id FROM core.lookup_categories WHERE code='UOM'), 'MM',     'Millimeter', 5),
  ((SELECT id FROM core.lookup_categories WHERE code='UOM'), 'SET',    'Set',        6),
  ((SELECT id FROM core.lookup_categories WHERE code='UOM'), 'PAIR',   'Pair',       7);

-- MATERIAL_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='MATERIAL_TYPE'), 'PRECIOUS_METAL', 'Precious Metal', 1),
  ((SELECT id FROM core.lookup_categories WHERE code='MATERIAL_TYPE'), 'STONE',          'Gemstone',       2),
  ((SELECT id FROM core.lookup_categories WHERE code='MATERIAL_TYPE'), 'TOOL',           'Tool / Equipment',3),
  ((SELECT id FROM core.lookup_categories WHERE code='MATERIAL_TYPE'), 'CONSUMABLE',     'Consumable',     4),
  ((SELECT id FROM core.lookup_categories WHERE code='MATERIAL_TYPE'), 'PACKAGING',      'Packaging',      5),
  ((SELECT id FROM core.lookup_categories WHERE code='MATERIAL_TYPE'), 'ALLOY',          'Alloy / Base Metal', 6);

-- INWARD_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='INWARD_STATUS'), 'PENDING',  'Pending Approval', 1),
  ((SELECT id FROM core.lookup_categories WHERE code='INWARD_STATUS'), 'APPROVED', 'Approved',         2),
  ((SELECT id FROM core.lookup_categories WHERE code='INWARD_STATUS'), 'REJECTED', 'Rejected',         3);

-- ALLOCATION_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='ALLOCATION_STATUS'), 'ALLOCATED',         'Allocated',           1),
  ((SELECT id FROM core.lookup_categories WHERE code='ALLOCATION_STATUS'), 'PARTIALLY_CONSUMED','Partially Consumed',  2),
  ((SELECT id FROM core.lookup_categories WHERE code='ALLOCATION_STATUS'), 'FULLY_CONSUMED',    'Fully Consumed',      3),
  ((SELECT id FROM core.lookup_categories WHERE code='ALLOCATION_STATUS'), 'RETURNED',          'Returned to Stock',   4);

-- TRANSFER_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='TRANSFER_STATUS'), 'DRAFT',                  'Draft',                    1),
  ((SELECT id FROM core.lookup_categories WHERE code='TRANSFER_STATUS'), 'PENDING_SOURCE_APPROVAL','Pending Source Approval',  2),
  ((SELECT id FROM core.lookup_categories WHERE code='TRANSFER_STATUS'), 'PENDING_DEST_APPROVAL',  'Pending Destination Approval',3),
  ((SELECT id FROM core.lookup_categories WHERE code='TRANSFER_STATUS'), 'APPROVED',               'Approved',                 4),
  ((SELECT id FROM core.lookup_categories WHERE code='TRANSFER_STATUS'), 'IN_TRANSIT',             'In Transit',               5),
  ((SELECT id FROM core.lookup_categories WHERE code='TRANSFER_STATUS'), 'RECEIVED',               'Received',                 6),
  ((SELECT id FROM core.lookup_categories WHERE code='TRANSFER_STATUS'), 'CANCELLED',              'Cancelled',                7);

-- DESIGN_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGN_TYPE'), 'CATALOG',  'Catalog Design',  1),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGN_TYPE'), 'CUSTOM',   'Custom Design',   2),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGN_TYPE'), 'BESPOKE',  'Bespoke Design',  3);

-- DESIGN_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGN_STATUS'), 'DRAFT',        'Draft',        1),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGN_STATUS'), 'UNDER_REVIEW', 'Under Review', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGN_STATUS'), 'APPROVED',     'Approved',     3),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGN_STATUS'), 'ARCHIVED',     'Archived',     4);

-- VERSION_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='VERSION_STATUS'), 'DRAFT',     'Draft',     1),
  ((SELECT id FROM core.lookup_categories WHERE code='VERSION_STATUS'), 'SUBMITTED', 'Submitted', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='VERSION_STATUS'), 'APPROVED',  'Approved',  3),
  ((SELECT id FROM core.lookup_categories WHERE code='VERSION_STATUS'), 'REJECTED',  'Rejected',  4);

-- BOM_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='BOM_STATUS'), 'DRAFT',            'Draft',              1),
  ((SELECT id FROM core.lookup_categories WHERE code='BOM_STATUS'), 'PENDING_APPROVAL', 'Pending Approval',   2),
  ((SELECT id FROM core.lookup_categories WHERE code='BOM_STATUS'), 'APPROVED',         'Approved',           3),
  ((SELECT id FROM core.lookup_categories WHERE code='BOM_STATUS'), 'OBSOLETE',         'Obsolete',           4);

-- BOM_COMPONENT_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='BOM_COMPONENT_TYPE'), 'PRECIOUS_METAL', 'Precious Metal', 1),
  ((SELECT id FROM core.lookup_categories WHERE code='BOM_COMPONENT_TYPE'), 'STONE',          'Gemstone',       2),
  ((SELECT id FROM core.lookup_categories WHERE code='BOM_COMPONENT_TYPE'), 'TOOL',           'Tool',           3),
  ((SELECT id FROM core.lookup_categories WHERE code='BOM_COMPONENT_TYPE'), 'LABOR',          'Labor',          4),
  ((SELECT id FROM core.lookup_categories WHERE code='BOM_COMPONENT_TYPE'), 'OTHER',          'Other',          5);

-- QC_CHECK_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='QC_CHECK_TYPE'), 'VISUAL',     'Visual Inspection',  1),
  ((SELECT id FROM core.lookup_categories WHERE code='QC_CHECK_TYPE'), 'WEIGHT',     'Weight Check',       2),
  ((SELECT id FROM core.lookup_categories WHERE code='QC_CHECK_TYPE'), 'PURITY',     'Purity Test',        3),
  ((SELECT id FROM core.lookup_categories WHERE code='QC_CHECK_TYPE'), 'DIMENSIONS', 'Dimension Check',    4),
  ((SELECT id FROM core.lookup_categories WHERE code='QC_CHECK_TYPE'), 'FINISH',     'Surface Finish',     5),
  ((SELECT id FROM core.lookup_categories WHERE code='QC_CHECK_TYPE'), 'HALLMARK',   'Hallmark Verification', 6);

-- QC_RESULT
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='QC_RESULT'), 'PASS',        'Pass',             1),
  ((SELECT id FROM core.lookup_categories WHERE code='QC_RESULT'), 'FAIL',        'Fail',             2),
  ((SELECT id FROM core.lookup_categories WHERE code='QC_RESULT'), 'CONDITIONAL', 'Conditional Pass', 3),
  ((SELECT id FROM core.lookup_categories WHERE code='QC_RESULT'), 'REWORK_REQUIRED', 'Rework Required', 4);

-- JOB_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_TYPE'), 'REGULAR',          'Regular Production',      1),
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_TYPE'), 'REWORK',           'Rework',                  2),
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_TYPE'), 'VENDOR_OUTSOURCE', 'Vendor Outsource',        3),
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_TYPE'), 'REPAIR',           'Repair',                  4);

-- JOB_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_STATUS'), 'DRAFT',                'Draft',                    1),
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_STATUS'), 'PENDING_BOM_APPROVAL', 'Pending BOM Approval',     2),
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_STATUS'), 'BOM_APPROVED',         'BOM Approved',             3),
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_STATUS'), 'IN_PROGRESS',          'In Progress',              4),
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_STATUS'), 'ON_HOLD',              'On Hold',                  5),
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_STATUS'), 'QUALITY_CHECK',        'Quality Check',            6),
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_STATUS'), 'COMPLETED',            'Completed',                7),
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_STATUS'), 'CANCELLED',            'Cancelled',                8),
  ((SELECT id FROM core.lookup_categories WHERE code='JOB_STATUS'), 'RELEASED',             'Released for Delivery',    9);

-- STAGE_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='STAGE_STATUS'), 'PENDING',     'Pending',         1),
  ((SELECT id FROM core.lookup_categories WHERE code='STAGE_STATUS'), 'IN_PROGRESS', 'In Progress',     2),
  ((SELECT id FROM core.lookup_categories WHERE code='STAGE_STATUS'), 'QC_PENDING',  'QC Pending',      3),
  ((SELECT id FROM core.lookup_categories WHERE code='STAGE_STATUS'), 'QC_PASSED',   'QC Passed',       4),
  ((SELECT id FROM core.lookup_categories WHERE code='STAGE_STATUS'), 'QC_FAILED',   'QC Failed',       5),
  ((SELECT id FROM core.lookup_categories WHERE code='STAGE_STATUS'), 'COMPLETED',   'Completed',       6),
  ((SELECT id FROM core.lookup_categories WHERE code='STAGE_STATUS'), 'SKIPPED',     'Skipped',         7);

-- WASTAGE_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='WASTAGE_TYPE'), 'NORMAL', 'Normal Wastage', 1),
  ((SELECT id FROM core.lookup_categories WHERE code='WASTAGE_TYPE'), 'EXCESS', 'Excess Wastage', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='WASTAGE_TYPE'), 'SCRAP',  'Scrap',          3);

-- ORDER_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='ORDER_TYPE'), 'CUSTOM',  'Custom Order',  1),
  ((SELECT id FROM core.lookup_categories WHERE code='ORDER_TYPE'), 'CATALOG', 'Catalog Order', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='ORDER_TYPE'), 'REPAIR',  'Repair Order',  3),
  ((SELECT id FROM core.lookup_categories WHERE code='ORDER_TYPE'), 'BULK',    'Bulk Order',    4);

-- ORDER_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='ORDER_STATUS'), 'DRAFT',         'Draft',          1),
  ((SELECT id FROM core.lookup_categories WHERE code='ORDER_STATUS'), 'CONFIRMED',     'Confirmed',      2),
  ((SELECT id FROM core.lookup_categories WHERE code='ORDER_STATUS'), 'IN_PRODUCTION', 'In Production',  3),
  ((SELECT id FROM core.lookup_categories WHERE code='ORDER_STATUS'), 'READY',         'Ready to Ship',  4),
  ((SELECT id FROM core.lookup_categories WHERE code='ORDER_STATUS'), 'DELIVERED',     'Delivered',      5),
  ((SELECT id FROM core.lookup_categories WHERE code='ORDER_STATUS'), 'CANCELLED',     'Cancelled',      6),
  ((SELECT id FROM core.lookup_categories WHERE code='ORDER_STATUS'), 'CLOSED',        'Closed',         7);

-- QUOTATION_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='QUOTATION_STATUS'), 'DRAFT',     'Draft',     1),
  ((SELECT id FROM core.lookup_categories WHERE code='QUOTATION_STATUS'), 'SUBMITTED', 'Submitted', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='QUOTATION_STATUS'), 'APPROVED',  'Approved',  3),
  ((SELECT id FROM core.lookup_categories WHERE code='QUOTATION_STATUS'), 'REJECTED',  'Rejected',  4),
  ((SELECT id FROM core.lookup_categories WHERE code='QUOTATION_STATUS'), 'EXPIRED',   'Expired',   5),
  ((SELECT id FROM core.lookup_categories WHERE code='QUOTATION_STATUS'), 'CONVERTED', 'Converted to Order', 6),
  ((SELECT id FROM core.lookup_categories WHERE code='QUOTATION_STATUS'), 'CANCELLED', 'Cancelled', 7);

-- INVOICE_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_TYPE'), 'GST',         'GST Invoice',      1),
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_TYPE'), 'NON_GST',     'Non-GST Invoice',  2),
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_TYPE'), 'PROFORMA',    'Proforma Invoice', 3),
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_TYPE'), 'CREDIT_NOTE', 'Credit Note',      4),
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_TYPE'), 'DEBIT_NOTE',  'Debit Note',       5);

-- INVOICE_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_STATUS'), 'DRAFT',            'Draft',             1),
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_STATUS'), 'PENDING_APPROVAL', 'Pending Approval',  2),
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_STATUS'), 'APPROVED',         'Approved',          3),
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_STATUS'), 'DISPATCHED',       'Dispatched',        4),
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_STATUS'), 'PARTIALLY_PAID',   'Partially Paid',    5),
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_STATUS'), 'PAID',             'Fully Paid',        6),
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_STATUS'), 'CANCELLED',        'Cancelled',         7),
  ((SELECT id FROM core.lookup_categories WHERE code='INVOICE_STATUS'), 'WRITTEN_OFF',      'Written Off',       8);

-- SUPPLY_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='SUPPLY_TYPE'), 'B2B',    'Business to Business', 1),
  ((SELECT id FROM core.lookup_categories WHERE code='SUPPLY_TYPE'), 'B2C',    'Business to Consumer', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='SUPPLY_TYPE'), 'EXPORT', 'Export',               3);

-- PAYMENT_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_TYPE'), 'RECEIPT', 'Receipt (Inflow)',  1),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_TYPE'), 'PAYMENT', 'Payment (Outflow)', 2);

-- PAYMENT_MODE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_MODE'), 'CASH',          'Cash',          1),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_MODE'), 'BANK_TRANSFER', 'Bank Transfer', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_MODE'), 'CHEQUE',        'Cheque',        3),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_MODE'), 'UPI',           'UPI',           4),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_MODE'), 'BARTER',        'Barter/Material',5),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_MODE'), 'DD',            'Demand Draft',  6);

-- PAYMENT_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_STATUS'), 'PENDING',  'Pending',  1),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_STATUS'), 'CLEARED',  'Cleared',  2),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_STATUS'), 'BOUNCED',  'Bounced',  3),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYMENT_STATUS'), 'REVERSED', 'Reversed', 4);

-- FUND_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='FUND_TYPE'), 'LOAN',      'Loan',      1),
  ((SELECT id FROM core.lookup_categories WHERE code='FUND_TYPE'), 'EMI',       'EMI',       2),
  ((SELECT id FROM core.lookup_categories WHERE code='FUND_TYPE'), 'CHIT_FUND', 'Chit Fund', 3);

-- DIRECTION
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='DIRECTION'), 'PAYABLE',    'Payable',    1),
  ((SELECT id FROM core.lookup_categories WHERE code='DIRECTION'), 'RECEIVABLE', 'Receivable', 2);

-- DELIVERY_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='DELIVERY_TYPE'), 'STANDARD',    'Standard Delivery', 1),
  ((SELECT id FROM core.lookup_categories WHERE code='DELIVERY_TYPE'), 'EXPRESS',     'Express Delivery',  2),
  ((SELECT id FROM core.lookup_categories WHERE code='DELIVERY_TYPE'), 'SELF_PICKUP', 'Self Pickup',       3);

-- DELIVERY_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='DELIVERY_STATUS'), 'DRAFT',      'Draft',      1),
  ((SELECT id FROM core.lookup_categories WHERE code='DELIVERY_STATUS'), 'APPROVED',   'Approved',   2),
  ((SELECT id FROM core.lookup_categories WHERE code='DELIVERY_STATUS'), 'DISPATCHED', 'Dispatched', 3),
  ((SELECT id FROM core.lookup_categories WHERE code='DELIVERY_STATUS'), 'DELIVERED',  'Delivered',  4),
  ((SELECT id FROM core.lookup_categories WHERE code='DELIVERY_STATUS'), 'RETURNED',   'Returned',   5);

-- RETURN_REASON
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='RETURN_REASON'), 'DEFECTIVE',      'Defective / Damaged',    1),
  ((SELECT id FROM core.lookup_categories WHERE code='RETURN_REASON'), 'WRONG_ITEM',     'Wrong Item Delivered',   2),
  ((SELECT id FROM core.lookup_categories WHERE code='RETURN_REASON'), 'DESIGN_MISMATCH','Design Mismatch',        3),
  ((SELECT id FROM core.lookup_categories WHERE code='RETURN_REASON'), 'SIZE_ISSUE',     'Size / Fit Issue',       4),
  ((SELECT id FROM core.lookup_categories WHERE code='RETURN_REASON'), 'CUSTOMER_CHANGE','Customer Changed Mind',  5),
  ((SELECT id FROM core.lookup_categories WHERE code='RETURN_REASON'), 'OTHER',          'Other',                  6);

-- RMA_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='RMA_STATUS'), 'REQUESTED',  'Requested',  1),
  ((SELECT id FROM core.lookup_categories WHERE code='RMA_STATUS'), 'AUTHORIZED', 'Authorized', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='RMA_STATUS'), 'RECEIVED',   'Received',   3),
  ((SELECT id FROM core.lookup_categories WHERE code='RMA_STATUS'), 'INSPECTED',  'Inspected',  4),
  ((SELECT id FROM core.lookup_categories WHERE code='RMA_STATUS'), 'RESOLVED',   'Resolved',   5),
  ((SELECT id FROM core.lookup_categories WHERE code='RMA_STATUS'), 'REJECTED',   'Rejected',   6);

-- DISPOSITION
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='DISPOSITION'), 'REPAIR',  'Repair',  1),
  ((SELECT id FROM core.lookup_categories WHERE code='DISPOSITION'), 'REPLACE', 'Replace', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='DISPOSITION'), 'REJECT',  'Reject',  3);

-- GENDER
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='GENDER'), 'MALE',   'Male',              1),
  ((SELECT id FROM core.lookup_categories WHERE code='GENDER'), 'FEMALE', 'Female',            2),
  ((SELECT id FROM core.lookup_categories WHERE code='GENDER'), 'OTHER',  'Other / Prefer not to say', 3);

-- DESIGNATION
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGNATION'), 'SUPER_ADMIN',        'Super Admin',            1),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGNATION'), 'BRANCH_MANAGER',     'Branch Manager',         2),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGNATION'), 'PRODUCTION_MANAGER', 'Production Manager',     3),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGNATION'), 'DESIGNER',           'Designer',               4),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGNATION'), 'SALES_EXECUTIVE',    'Sales Executive',        5),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGNATION'), 'ACCOUNTS_OFFICER',   'Accounts Officer',       6),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGNATION'), 'STORE_MANAGER',      'Store / Stock Manager',  7),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGNATION'), 'QC_INSPECTOR',       'QC Inspector',           8),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGNATION'), 'ARTISAN',            'Artisan / Worker',       9),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGNATION'), 'HR_OFFICER',         'HR Officer',             10),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGNATION'), 'VENDOR_COORDINATOR', 'Vendor Coordinator',     11),
  ((SELECT id FROM core.lookup_categories WHERE code='DESIGNATION'), 'AUDITOR',            'Auditor / Viewer',       12);

-- DEPARTMENT
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='DEPARTMENT'), 'PRODUCTION', 'Production',        1),
  ((SELECT id FROM core.lookup_categories WHERE code='DEPARTMENT'), 'SALES',      'Sales & Marketing', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='DEPARTMENT'), 'ACCOUNTS',   'Accounts & Finance',3),
  ((SELECT id FROM core.lookup_categories WHERE code='DEPARTMENT'), 'DESIGN',     'Design Studio',     4),
  ((SELECT id FROM core.lookup_categories WHERE code='DEPARTMENT'), 'STORE',      'Store & Inventory', 5),
  ((SELECT id FROM core.lookup_categories WHERE code='DEPARTMENT'), 'QC',         'Quality Control',   6),
  ((SELECT id FROM core.lookup_categories WHERE code='DEPARTMENT'), 'HR',         'Human Resources',   7),
  ((SELECT id FROM core.lookup_categories WHERE code='DEPARTMENT'), 'ADMIN',      'Administration',    8);

-- EMPLOYMENT_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='EMPLOYMENT_TYPE'), 'FULL_TIME',    'Full Time',        1),
  ((SELECT id FROM core.lookup_categories WHERE code='EMPLOYMENT_TYPE'), 'PART_TIME',    'Part Time',        2),
  ((SELECT id FROM core.lookup_categories WHERE code='EMPLOYMENT_TYPE'), 'CONTRACT',     'Contract',         3),
  ((SELECT id FROM core.lookup_categories WHERE code='EMPLOYMENT_TYPE'), 'ARTISAN_DAILY','Artisan (Daily)',  4);

-- EXIT_REASON
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='EXIT_REASON'), 'RESIGNATION',  'Resignation',   1),
  ((SELECT id FROM core.lookup_categories WHERE code='EXIT_REASON'), 'TERMINATION',  'Termination',   2),
  ((SELECT id FROM core.lookup_categories WHERE code='EXIT_REASON'), 'RETIREMENT',   'Retirement',    3),
  ((SELECT id FROM core.lookup_categories WHERE code='EXIT_REASON'), 'CONTRACT_END', 'Contract End',  4),
  ((SELECT id FROM core.lookup_categories WHERE code='EXIT_REASON'), 'DEATH',        'Death',         5);

-- EMPLOYEE_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='EMPLOYEE_STATUS'), 'ACTIVE',     'Active',         1),
  ((SELECT id FROM core.lookup_categories WHERE code='EMPLOYEE_STATUS'), 'ON_LEAVE',   'On Leave',       2),
  ((SELECT id FROM core.lookup_categories WHERE code='EMPLOYEE_STATUS'), 'RESIGNED',   'Resigned',       3),
  ((SELECT id FROM core.lookup_categories WHERE code='EMPLOYEE_STATUS'), 'TERMINATED', 'Terminated',     4),
  ((SELECT id FROM core.lookup_categories WHERE code='EMPLOYEE_STATUS'), 'PROBATION',  'Probation',      5);

-- LEAVE_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='LEAVE_STATUS'), 'PENDING',   'Pending',   1),
  ((SELECT id FROM core.lookup_categories WHERE code='LEAVE_STATUS'), 'APPROVED',  'Approved',  2),
  ((SELECT id FROM core.lookup_categories WHERE code='LEAVE_STATUS'), 'REJECTED',  'Rejected',  3),
  ((SELECT id FROM core.lookup_categories WHERE code='LEAVE_STATUS'), 'CANCELLED', 'Cancelled', 4);

-- ATTENDANCE_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='ATTENDANCE_STATUS'), 'PRESENT',  'Present',       1),
  ((SELECT id FROM core.lookup_categories WHERE code='ATTENDANCE_STATUS'), 'ABSENT',   'Absent',        2),
  ((SELECT id FROM core.lookup_categories WHERE code='ATTENDANCE_STATUS'), 'HALF_DAY', 'Half Day',      3),
  ((SELECT id FROM core.lookup_categories WHERE code='ATTENDANCE_STATUS'), 'ON_LEAVE', 'On Leave',      4),
  ((SELECT id FROM core.lookup_categories WHERE code='ATTENDANCE_STATUS'), 'HOLIDAY',  'Holiday',       5),
  ((SELECT id FROM core.lookup_categories WHERE code='ATTENDANCE_STATUS'), 'WEEK_OFF', 'Week Off',      6);

-- SHIFT
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='SHIFT'), 'MORNING', 'Morning Shift (6AM–2PM)',   1),
  ((SELECT id FROM core.lookup_categories WHERE code='SHIFT'), 'GENERAL', 'General Shift (9AM–6PM)',   2),
  ((SELECT id FROM core.lookup_categories WHERE code='SHIFT'), 'EVENING', 'Evening Shift (2PM–10PM)',  3),
  ((SELECT id FROM core.lookup_categories WHERE code='SHIFT'), 'NIGHT',   'Night Shift (10PM–6AM)',    4);

-- SALARY_COMPONENT_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='SALARY_COMPONENT_TYPE'), 'EARNING',   'Earning',   1),
  ((SELECT id FROM core.lookup_categories WHERE code='SALARY_COMPONENT_TYPE'), 'DEDUCTION', 'Deduction', 2);

-- CALC_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='CALC_TYPE'), 'FIXED',                'Fixed Amount',              1),
  ((SELECT id FROM core.lookup_categories WHERE code='CALC_TYPE'), 'PERCENTAGE_OF_BASIC',  'Percentage of Basic',       2),
  ((SELECT id FROM core.lookup_categories WHERE code='CALC_TYPE'), 'FORMULA',              'Custom Formula',            3);

-- PAYROLL_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='PAYROLL_STATUS'), 'DRAFT',            'Draft',           1),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYROLL_STATUS'), 'PENDING_APPROVAL', 'Pending Approval',2),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYROLL_STATUS'), 'APPROVED',         'Approved',        3),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYROLL_STATUS'), 'DISBURSED',        'Disbursed',       4),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYROLL_STATUS'), 'CANCELLED',        'Cancelled',       5);

-- PAYSLIP_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='PAYSLIP_STATUS'), 'PENDING', 'Pending', 1),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYSLIP_STATUS'), 'PAID',    'Paid',    2),
  ((SELECT id FROM core.lookup_categories WHERE code='PAYSLIP_STATUS'), 'HELD',    'Held',    3);

-- ACCOUNT_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_TYPE'), 'BANK',         'Bank Account',   1),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_TYPE'), 'CASH',         'Cash Account',   2),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_TYPE'), 'DEBTORS',      'Debtors',        3),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_TYPE'), 'CREDITORS',    'Creditors',      4),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_TYPE'), 'STOCK',        'Stock Account',  5),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_TYPE'), 'SALES',        'Sales',          6),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_TYPE'), 'PURCHASE',     'Purchase',       7),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_TYPE'), 'GST_INPUT',    'GST Input',      8),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_TYPE'), 'GST_OUTPUT',   'GST Output',     9),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_TYPE'), 'SALARY_EXP',   'Salary Expense', 10),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_TYPE'), 'CAPITAL',      'Capital',        11);

-- ACCOUNT_GROUP_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_GROUP_TYPE'), 'ASSET',     'Asset',     1),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_GROUP_TYPE'), 'LIABILITY', 'Liability', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_GROUP_TYPE'), 'EQUITY',    'Equity',    3),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_GROUP_TYPE'), 'INCOME',    'Income',    4),
  ((SELECT id FROM core.lookup_categories WHERE code='ACCOUNT_GROUP_TYPE'), 'EXPENSE',   'Expense',   5);

-- JOURNAL_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='JOURNAL_TYPE'), 'PURCHASE',   'Purchase',              1),
  ((SELECT id FROM core.lookup_categories WHERE code='JOURNAL_TYPE'), 'SALE',       'Sale',                  2),
  ((SELECT id FROM core.lookup_categories WHERE code='JOURNAL_TYPE'), 'PAYMENT',    'Payment',               3),
  ((SELECT id FROM core.lookup_categories WHERE code='JOURNAL_TYPE'), 'RECEIPT',    'Receipt',               4),
  ((SELECT id FROM core.lookup_categories WHERE code='JOURNAL_TYPE'), 'ADJUSTMENT', 'Journal Adjustment',    5),
  ((SELECT id FROM core.lookup_categories WHERE code='JOURNAL_TYPE'), 'OPENING',    'Opening Balance',       6),
  ((SELECT id FROM core.lookup_categories WHERE code='JOURNAL_TYPE'), 'STOCK',      'Stock Movement',        7),
  ((SELECT id FROM core.lookup_categories WHERE code='JOURNAL_TYPE'), 'SALARY',     'Salary',                8);

-- JOURNAL_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='JOURNAL_STATUS'), 'DRAFT',    'Draft',    1),
  ((SELECT id FROM core.lookup_categories WHERE code='JOURNAL_STATUS'), 'POSTED',   'Posted',   2),
  ((SELECT id FROM core.lookup_categories WHERE code='JOURNAL_STATUS'), 'REVERSED', 'Reversed', 3);

-- PERIOD_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='PERIOD_STATUS'), 'OPEN',              'Open',              1),
  ((SELECT id FROM core.lookup_categories WHERE code='PERIOD_STATUS'), 'CLOSING_INITIATED', 'Closing Initiated', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='PERIOD_STATUS'), 'CLOSED',            'Closed',            3);

-- APPROVAL_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='APPROVAL_STATUS'), 'PENDING',   'Pending',   1),
  ((SELECT id FROM core.lookup_categories WHERE code='APPROVAL_STATUS'), 'APPROVED',  'Approved',  2),
  ((SELECT id FROM core.lookup_categories WHERE code='APPROVAL_STATUS'), 'REJECTED',  'Rejected',  3),
  ((SELECT id FROM core.lookup_categories WHERE code='APPROVAL_STATUS'), 'RECALLED',  'Recalled',  4),
  ((SELECT id FROM core.lookup_categories WHERE code='APPROVAL_STATUS'), 'ESCALATED', 'Escalated', 5);

-- APPROVAL_ACTION
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='APPROVAL_ACTION'), 'APPROVED',  'Approved',  1),
  ((SELECT id FROM core.lookup_categories WHERE code='APPROVAL_ACTION'), 'REJECTED',  'Rejected',  2),
  ((SELECT id FROM core.lookup_categories WHERE code='APPROVAL_ACTION'), 'ESCALATED', 'Escalated', 3),
  ((SELECT id FROM core.lookup_categories WHERE code='APPROVAL_ACTION'), 'RECALLED',  'Recalled',  4);

-- NOTIFICATION_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='NOTIFICATION_TYPE'), 'APPROVAL_REQUIRED',    'Approval Required',       1),
  ((SELECT id FROM core.lookup_categories WHERE code='NOTIFICATION_TYPE'), 'APPROVAL_DONE',        'Approval Completed',      2),
  ((SELECT id FROM core.lookup_categories WHERE code='NOTIFICATION_TYPE'), 'BLACKLIST_ALERT',      'Blacklisted Party Alert', 3),
  ((SELECT id FROM core.lookup_categories WHERE code='NOTIFICATION_TYPE'), 'STOCK_LOW',            'Low Stock Alert',         4),
  ((SELECT id FROM core.lookup_categories WHERE code='NOTIFICATION_TYPE'), 'WASTAGE_EXCEEDED',     'Wastage Threshold Exceeded', 5),
  ((SELECT id FROM core.lookup_categories WHERE code='NOTIFICATION_TYPE'), 'QC_FAILED',            'QC Failure Alert',        6),
  ((SELECT id FROM core.lookup_categories WHERE code='NOTIFICATION_TYPE'), 'PAYMENT_DUE',          'Payment Due',             7),
  ((SELECT id FROM core.lookup_categories WHERE code='NOTIFICATION_TYPE'), 'ORDER_DELAYED',        'Order Delayed',           8),
  ((SELECT id FROM core.lookup_categories WHERE code='NOTIFICATION_TYPE'), 'JOB_CARD_BOTTLENECK',  'Job Card Bottleneck',     9),
  ((SELECT id FROM core.lookup_categories WHERE code='NOTIFICATION_TYPE'), 'SYSTEM_ALERT',         'System Alert',            10);

-- SKILL
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='SKILL'), 'CASTING',        'Casting',           1),
  ((SELECT id FROM core.lookup_categories WHERE code='SKILL'), 'FILING',         'Filing',            2),
  ((SELECT id FROM core.lookup_categories WHERE code='SKILL'), 'POLISHING',      'Polishing',         3),
  ((SELECT id FROM core.lookup_categories WHERE code='SKILL'), 'STONE_SETTING',  'Stone Setting',     4),
  ((SELECT id FROM core.lookup_categories WHERE code='SKILL'), 'ENGRAVING',      'Engraving',         5),
  ((SELECT id FROM core.lookup_categories WHERE code='SKILL'), 'SOLDERING',      'Soldering',         6),
  ((SELECT id FROM core.lookup_categories WHERE code='SKILL'), 'DESIGN_CAD',     'CAD Design',        7),
  ((SELECT id FROM core.lookup_categories WHERE code='SKILL'), 'QUALITY_CHECK',  'Quality Inspection',8),
  ((SELECT id FROM core.lookup_categories WHERE code='SKILL'), 'ENAMELING',      'Enameling',         9),
  ((SELECT id FROM core.lookup_categories WHERE code='SKILL'), 'HALLMARKING',    'Hallmarking',       10);

-- PROFICIENCY
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='PROFICIENCY'), 'BEGINNER',     'Beginner',     1),
  ((SELECT id FROM core.lookup_categories WHERE code='PROFICIENCY'), 'INTERMEDIATE', 'Intermediate', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='PROFICIENCY'), 'EXPERT',       'Expert',       3);

-- PRIORITY
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='PRIORITY'), 'LOW',    'Low',    1),
  ((SELECT id FROM core.lookup_categories WHERE code='PRIORITY'), 'NORMAL', 'Normal', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='PRIORITY'), 'HIGH',   'High',   3),
  ((SELECT id FROM core.lookup_categories WHERE code='PRIORITY'), 'URGENT', 'Urgent', 4);

-- CONTACT_TYPE
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='CONTACT_TYPE'), 'BILLING',  'Billing Address',  1),
  ((SELECT id FROM core.lookup_categories WHERE code='CONTACT_TYPE'), 'SHIPPING', 'Shipping Address', 2),
  ((SELECT id FROM core.lookup_categories WHERE code='CONTACT_TYPE'), 'OTHER',    'Other',            3);

-- FUND_STATUS
INSERT INTO core.lookup_values (category_id, code, name, display_order) VALUES
  ((SELECT id FROM core.lookup_categories WHERE code='FUND_STATUS'), 'ACTIVE',   'Active',   1),
  ((SELECT id FROM core.lookup_categories WHERE code='FUND_STATUS'), 'CLOSED',   'Closed',   2),
  ((SELECT id FROM core.lookup_categories WHERE code='FUND_STATUS'), 'DEFAULTED','Defaulted',3);

-- =============================================================================
-- PERMISSION MODULES SEED
-- =============================================================================
INSERT INTO core.modules (code, name, description, display_order) VALUES
  ('ORG',        'Organization & Branch',    'Org and branch management',       1),
  ('RBAC',       'Roles & Permissions',      'User roles and permissions',      2),
  ('MASTER',     'Master Data',              'Parties, materials, designs',     3),
  ('INVENTORY',  'Inventory & Stock',        'Raw material inward/outward',     4),
  ('QUOTATION',  'Quotations',               'Quotation management',            5),
  ('ORDER',      'Orders',                   'Sales order management',          6),
  ('PRODUCTION', 'Production & Job Cards',   'Job card workflow',               7),
  ('QC',         'Quality Control',          'QC checks and rework',            8),
  ('INVOICE',    'Invoicing',                'Invoice generation',              9),
  ('PAYMENT',    'Payments',                 'Payment tracking',                10),
  ('DELIVERY',   'Delivery & Returns',       'Challan and RMA',                 11),
  ('HR',         'HR & Employees',           'Employee management',             12),
  ('PAYROLL',    'Payroll',                  'Salary and payroll',              13),
  ('ACCOUNTS',   'Accounting & GST',         'Ledger, journals, GST',           14),
  ('AUDIT',      'Audit Logs',               'Audit trail and reports',         15),
  ('ANALYTICS',  'Analytics & Reports',      'Dashboards and reports',          16),
  ('SETTINGS',   'System Settings',          'Configuration management',        17);

INSERT INTO core.permission_actions (code, name, display_order) VALUES
  ('VIEW',    'View',    1),
  ('ADD',     'Add',     2),
  ('EDIT',    'Edit',    3),
  ('DELETE',  'Delete',  4),
  ('APPROVE', 'Approve', 5),
  ('EXPORT',  'Export',  6),
  ('PRINT',   'Print',   7);

-- =============================================================================
-- SAMPLE MASTER DATA
-- =============================================================================

-- Organization
INSERT INTO core.organizations (id, code, name, legal_name, pan, gstin, address_line1, city, state, pincode, phone, email)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    'ZLV',
    'Zilverra Jewelry Pvt Ltd',
    'Zilverra Jewelry Private Limited',
    'AABCZ1234D',
    '36AABCZ1234D1ZA',
    '12-34, Jewellers Street, Secunderabad',
    'Hyderabad', 'Telangana', '500003',
    '+91-9876543210', 'admin@zilverra.com'
);

-- Branches
INSERT INTO core.branches (id, organization_id, code, name, branch_type_id, gstin, city, state, phone, email)
VALUES
(
    '22222222-2222-2222-2222-222222222222',
    '11111111-1111-1111-1111-111111111111',
    'HYD-HO',
    'Hyderabad Head Office',
    (SELECT id FROM core.lookup_values WHERE code='HEAD_OFFICE'),
    '36AABCZ1234D1ZA', 'Hyderabad', 'Telangana',
    '+91-9876543210', 'hyderabad@zilverra.com'
),
(
    '33333333-3333-3333-3333-333333333333',
    '11111111-1111-1111-1111-111111111111',
    'MUM-BR',
    'Mumbai Branch',
    (SELECT id FROM core.lookup_values WHERE code='BRANCH'),
    '27AABCZ1234D1Z5', 'Mumbai', 'Maharashtra',
    '+91-9876543220', 'mumbai@zilverra.com'
);

-- Roles
INSERT INTO core.roles (id, organization_id, code, name, is_system_role) VALUES
  ('aaaa0001-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'SUPER_ADMIN',        'Super Admin',              TRUE),
  ('aaaa0002-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'BRANCH_MANAGER',     'Branch Manager',           TRUE),
  ('aaaa0003-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'PRODUCTION_MANAGER', 'Production Manager',       TRUE),
  ('aaaa0004-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'DESIGNER',           'Designer',                 TRUE),
  ('aaaa0005-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'SALES_EXECUTIVE',    'Sales Executive',          TRUE),
  ('aaaa0006-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'ACCOUNTS_OFFICER',   'Accounts Officer',         TRUE),
  ('aaaa0007-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', 'STORE_MANAGER',      'Store / Stock Manager',    TRUE),
  ('aaaa0008-0000-0000-0000-000000000008', '11111111-1111-1111-1111-111111111111', 'QC_INSPECTOR',       'QC Inspector',             TRUE),
  ('aaaa0009-0000-0000-0000-000000000009', '11111111-1111-1111-1111-111111111111', 'WORKER',             'Worker / Artisan',         TRUE),
  ('aaaa0010-0000-0000-0000-000000000010', '11111111-1111-1111-1111-111111111111', 'HR_OFFICER',         'HR Officer',               TRUE),
  ('aaaa0011-0000-0000-0000-000000000011', '11111111-1111-1111-1111-111111111111', 'AUDITOR',            'Auditor / Viewer',         TRUE),
  ('aaaa0012-0000-0000-0000-000000000012', '11111111-1111-1111-1111-111111111111', 'VENDOR_COORDINATOR', 'Vendor Coordinator',       TRUE);

-- Sample Users
INSERT INTO core.users (id, organization_id, username, email, password_hash, full_name) VALUES
  ('bbbb0001-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'superadmin',    'superadmin@zilverra.com',    '$2b$12$placeholder_hash_1', 'System Administrator'),
  ('bbbb0002-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'mgr.hyderabad', 'mgr.hyd@zilverra.com',       '$2b$12$placeholder_hash_2', 'Ramesh Kumar'),
  ('bbbb0003-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'prod.manager1', 'prod1@zilverra.com',          '$2b$12$placeholder_hash_3', 'Suresh Verma'),
  ('bbbb0004-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'designer1',     'designer1@zilverra.com',     '$2b$12$placeholder_hash_4', 'Priya Sharma'),
  ('bbbb0005-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'sales1',        'sales1@zilverra.com',        '$2b$12$placeholder_hash_5', 'Anita Reddy'),
  ('bbbb0006-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'accounts1',     'accounts1@zilverra.com',     '$2b$12$placeholder_hash_6', 'Vikram Nair'),
  ('bbbb0007-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', 'storemanager1', 'store1@zilverra.com',        '$2b$12$placeholder_hash_7', 'Deepa Menon'),
  ('bbbb0008-0000-0000-0000-000000000008', '11111111-1111-1111-1111-111111111111', 'qcinspector1',  'qc1@zilverra.com',           '$2b$12$placeholder_hash_8', 'Kiran Pillai');

-- User-Branch-Role assignments
INSERT INTO core.user_branch_roles (user_id, branch_id, role_id, assigned_by) VALUES
  ('bbbb0001-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'aaaa0001-0000-0000-0000-000000000001', 'bbbb0001-0000-0000-0000-000000000001'),
  ('bbbb0002-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'aaaa0002-0000-0000-0000-000000000002', 'bbbb0001-0000-0000-0000-000000000001'),
  ('bbbb0003-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'aaaa0003-0000-0000-0000-000000000003', 'bbbb0001-0000-0000-0000-000000000001'),
  ('bbbb0004-0000-0000-0000-000000000004', '22222222-2222-2222-2222-222222222222', 'aaaa0004-0000-0000-0000-000000000004', 'bbbb0001-0000-0000-0000-000000000001'),
  ('bbbb0005-0000-0000-0000-000000000005', '22222222-2222-2222-2222-222222222222', 'aaaa0005-0000-0000-0000-000000000005', 'bbbb0001-0000-0000-0000-000000000001'),
  ('bbbb0006-0000-0000-0000-000000000006', '22222222-2222-2222-2222-222222222222', 'aaaa0006-0000-0000-0000-000000000006', 'bbbb0001-0000-0000-0000-000000000001'),
  ('bbbb0007-0000-0000-0000-000000000007', '22222222-2222-2222-2222-222222222222', 'aaaa0007-0000-0000-0000-000000000007', 'bbbb0001-0000-0000-0000-000000000001'),
  ('bbbb0008-0000-0000-0000-000000000008', '22222222-2222-2222-2222-222222222222', 'aaaa0008-0000-0000-0000-000000000008', 'bbbb0001-0000-0000-0000-000000000001');

-- Material Categories
INSERT INTO inventory.material_categories (organization_id, code, name, is_precious_metal) VALUES
  ('11111111-1111-1111-1111-111111111111', 'SILVER',    'Silver',          TRUE),
  ('11111111-1111-1111-1111-111111111111', 'GOLD',      'Gold',            TRUE),
  ('11111111-1111-1111-1111-111111111111', 'PLATINUM',  'Platinum',        TRUE),
  ('11111111-1111-1111-1111-111111111111', 'DIAMONDS',  'Diamonds',        FALSE),
  ('11111111-1111-1111-1111-111111111111', 'STONES',    'Gemstones',       FALSE),
  ('11111111-1111-1111-1111-111111111111', 'TOOLS',     'Tools & Equipment',FALSE),
  ('11111111-1111-1111-1111-111111111111', 'PACKAGING', 'Packaging',       FALSE);

-- Materials
INSERT INTO inventory.materials (id, organization_id, category_id, code, name, uom_id, material_type_id, hsn_code, gst_rate, min_purity, max_purity) VALUES
(
    'cccc0001-0000-0000-0000-000000000001',
    '11111111-1111-1111-1111-111111111111',
    (SELECT id FROM inventory.material_categories WHERE code='SILVER'),
    'AG-925', '925 Sterling Silver',
    (SELECT id FROM core.lookup_values WHERE code='GRAM'),
    (SELECT id FROM core.lookup_values WHERE code='PRECIOUS_METAL'),
    '71069100', 3.00, 0.920, 0.930
),
(
    'cccc0002-0000-0000-0000-000000000002',
    '11111111-1111-1111-1111-111111111111',
    (SELECT id FROM inventory.material_categories WHERE code='SILVER'),
    'AG-999', '999 Fine Silver',
    (SELECT id FROM core.lookup_values WHERE code='GRAM'),
    (SELECT id FROM core.lookup_values WHERE code='PRECIOUS_METAL'),
    '71069100', 3.00, 0.998, 1.000
),
(
    'cccc0003-0000-0000-0000-000000000003',
    '11111111-1111-1111-1111-111111111111',
    (SELECT id FROM inventory.material_categories WHERE code='GOLD'),
    'AU-22K', '22 Karat Gold',
    (SELECT id FROM core.lookup_values WHERE code='GRAM'),
    (SELECT id FROM core.lookup_values WHERE code='PRECIOUS_METAL'),
    '71081200', 3.00, 0.916, 0.920
);

-- Sample Parties (Supplier and Customer)
INSERT INTO core.parties (id, organization_id, party_type_id, code, name, gstin, pan, phone, email, city, state, status_id, credit_days)
VALUES
(
    'dddd0001-0000-0000-0000-000000000001',
    '11111111-1111-1111-1111-111111111111',
    (SELECT id FROM core.lookup_values WHERE code='SUPPLIER'),
    'SUP-001', 'Rajasthan Silver Refiners Pvt Ltd',
    '08AABCR5678D1ZP', 'AABCR5678D',
    '+91-9876540001', 'purchase@rajsilver.com',
    'Jaipur', 'Rajasthan',
    (SELECT id FROM core.lookup_values WHERE code='ACTIVE'), 30
),
(
    'dddd0002-0000-0000-0000-000000000002',
    '11111111-1111-1111-1111-111111111111',
    (SELECT id FROM core.lookup_values WHERE code='CUSTOMER'),
    'CUS-001', 'Mumbai Jewellery Exports',
    '27AABCM9012D1ZK', 'AABCM9012D',
    '+91-9876540002', 'orders@mujewex.com',
    'Mumbai', 'Maharashtra',
    (SELECT id FROM core.lookup_values WHERE code='ACTIVE'), 15
),
(
    'dddd0003-0000-0000-0000-000000000003',
    '11111111-1111-1111-1111-111111111111',
    (SELECT id FROM core.lookup_values WHERE code='VENDOR'),
    'VEN-001', 'Artisan Works (Outsource)',
    NULL, NULL,
    '+91-9876540003', NULL,
    'Hyderabad', 'Telangana',
    (SELECT id FROM core.lookup_values WHERE code='ACTIVE'), 0
);

-- Stock Lot sample
INSERT INTO inventory.stock_lots (
    id, branch_id, material_id, supplier_id, lot_number, batch_reference,
    barcode, purity, gross_weight, net_weight, tare_weight, unit_cost,
    currency, inward_date, inward_status_id, available_weight
) VALUES (
    'eeee0001-0000-0000-0000-000000000001',
    '22222222-2222-2222-2222-222222222222',
    'cccc0001-0000-0000-0000-000000000001',
    'dddd0001-0000-0000-0000-000000000001',
    'LOT-2025-001', 'BATCH-RAJ-25-03',
    'ZLV-AG925-001', 0.925,
    1005.500, 1000.000, 5.500, 82.50,
    'INR', '2025-03-01',
    (SELECT id FROM core.lookup_values WHERE code='APPROVED'),
    1000.000
);

-- Stock Balance
INSERT INTO inventory.stock_balances (branch_id, material_id, purity, total_weight, available_weight)
VALUES (
    '22222222-2222-2222-2222-222222222222',
    'cccc0001-0000-0000-0000-000000000001',
    0.925, 1000.000, 1000.000
);

-- Production Stage Templates
INSERT INTO production.stage_templates (id, organization_id, code, name, default_duration_hrs, requires_qc) VALUES
  ('ffff0001-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'DESIGN',    'Design & Approval',    4,  FALSE),
  ('ffff0002-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'MOLDING',   'Wax Molding',          2,  FALSE),
  ('ffff0003-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'CASTING',   'Metal Casting',        3,  TRUE),
  ('ffff0004-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'FILING',    'Filing & Shaping',     4,  FALSE),
  ('ffff0005-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'POLISHING', 'Polishing',            3,  FALSE),
  ('ffff0006-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'STONE_SET', 'Stone Setting',        4,  TRUE),
  ('ffff0007-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', 'QC',        'Final Quality Control', 2, TRUE),
  ('ffff0008-0000-0000-0000-000000000008', '11111111-1111-1111-1111-111111111111', 'PACKING',   'Packing & Dispatch',   1,  FALSE);

-- Design
INSERT INTO production.designs (id, organization_id, branch_id, code, name, design_type_id, status_id, current_version, created_by)
VALUES (
    'gggg0001-0000-0000-0000-000000000001',
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    'DES-2025-001', 'Sterling Silver Bangle - Classic Twist',
    (SELECT id FROM core.lookup_values WHERE code='CATALOG'),
    (SELECT id FROM core.lookup_values WHERE code='APPROVED'),
    1,
    'bbbb0004-0000-0000-0000-000000000004'
);

INSERT INTO production.design_versions (design_id, version_number, change_summary, status_id, approved_by, approved_at, created_by)
VALUES (
    'gggg0001-0000-0000-0000-000000000001',
    1, 'Initial release of Classic Twist Bangle design',
    (SELECT id FROM core.lookup_values WHERE code='APPROVED'),
    'bbbb0002-0000-0000-0000-000000000002', NOW(),
    'bbbb0004-0000-0000-0000-000000000004'
);

-- BOM Template
INSERT INTO production.bom_templates (id, organization_id, design_version_id, code, name, status_id, approved_by, approved_at, created_by)
VALUES (
    'hhhh0001-0000-0000-0000-000000000001',
    '11111111-1111-1111-1111-111111111111',
    (SELECT id FROM production.design_versions WHERE design_id='gggg0001-0000-0000-0000-000000000001' AND version_number=1),
    'BOM-DES-001-V1', 'BOM - Classic Twist Bangle v1',
    (SELECT id FROM core.lookup_values WHERE code='APPROVED'),
    'bbbb0002-0000-0000-0000-000000000002', NOW(),
    'bbbb0003-0000-0000-0000-000000000003'
);

INSERT INTO production.bom_line_items (bom_template_id, material_id, component_type_id, quantity, uom_id, purity_required, wastage_pct, unit_cost)
VALUES (
    'hhhh0001-0000-0000-0000-000000000001',
    'cccc0001-0000-0000-0000-000000000001',
    (SELECT id FROM core.lookup_values WHERE code='PRECIOUS_METAL'),
    25.000,
    (SELECT id FROM core.lookup_values WHERE code='GRAM'),
    0.925, 2.500, 82.50
);

-- Document Sequences
INSERT INTO core.document_sequences (branch_id, document_type, prefix, current_value, min_digits, reset_on) VALUES
  ('22222222-2222-2222-2222-222222222222', 'QUOTATION',  'ZLV-QT-',  0, 6, 'YEARLY'),
  ('22222222-2222-2222-2222-222222222222', 'ORDER',      'ZLV-ORD-', 0, 6, 'YEARLY'),
  ('22222222-2222-2222-2222-222222222222', 'JOB_CARD',   'ZLV-JC-',  0, 6, 'YEARLY'),
  ('22222222-2222-2222-2222-222222222222', 'INVOICE',    'ZLV-INV-', 0, 6, 'YEARLY'),
  ('22222222-2222-2222-2222-222222222222', 'PAYMENT',    'ZLV-PAY-', 0, 6, 'YEARLY'),
  ('22222222-2222-2222-2222-222222222222', 'CHALLAN',    'ZLV-DCH-', 0, 6, 'YEARLY'),
  ('22222222-2222-2222-2222-222222222222', 'TRANSFER',   'ZLV-TRF-', 0, 6, 'YEARLY');

-- Sample Salary Components
INSERT INTO hr.salary_components (organization_id, code, name, component_type_id, calculation_type_id, is_pf_applicable, display_order) VALUES
  ('11111111-1111-1111-1111-111111111111', 'BASIC',       'Basic Salary',    (SELECT id FROM core.lookup_values WHERE code='EARNING'),   (SELECT id FROM core.lookup_values WHERE code='FIXED'), TRUE,  1),
  ('11111111-1111-1111-1111-111111111111', 'HRA',         'HRA',             (SELECT id FROM core.lookup_values WHERE code='EARNING'),   (SELECT id FROM core.lookup_values WHERE code='PERCENTAGE_OF_BASIC'), FALSE, 2),
  ('11111111-1111-1111-1111-111111111111', 'CONVEYANCE',  'Conveyance',      (SELECT id FROM core.lookup_values WHERE code='EARNING'),   (SELECT id FROM core.lookup_values WHERE code='FIXED'), FALSE, 3),
  ('11111111-1111-1111-1111-111111111111', 'SPECIAL_ALL', 'Special Allowance',(SELECT id FROM core.lookup_values WHERE code='EARNING'),  (SELECT id FROM core.lookup_values WHERE code='FIXED'), FALSE, 4),
  ('11111111-1111-1111-1111-111111111111', 'PF_EMP',      'PF (Employee)',   (SELECT id FROM core.lookup_values WHERE code='DEDUCTION'), (SELECT id FROM core.lookup_values WHERE code='PERCENTAGE_OF_BASIC'), TRUE,  5),
  ('11111111-1111-1111-1111-111111111111', 'ESI_EMP',     'ESI (Employee)',  (SELECT id FROM core.lookup_values WHERE code='DEDUCTION'), (SELECT id FROM core.lookup_values WHERE code='PERCENTAGE_OF_BASIC'), FALSE, 6),
  ('11111111-1111-1111-1111-111111111111', 'TDS',         'TDS',             (SELECT id FROM core.lookup_values WHERE code='DEDUCTION'), (SELECT id FROM core.lookup_values WHERE code='FIXED'), FALSE, 7),
  ('11111111-1111-1111-1111-111111111111', 'ADVANCE_DED', 'Advance Deduction',(SELECT id FROM core.lookup_values WHERE code='DEDUCTION'),(SELECT id FROM core.lookup_values WHERE code='FIXED'), FALSE, 8);

-- Leave Types
INSERT INTO hr.leave_types (organization_id, code, name, max_days_per_year, is_paid, carry_forward) VALUES
  ('11111111-1111-1111-1111-111111111111', 'CL',  'Casual Leave',    12, TRUE,  FALSE),
  ('11111111-1111-1111-1111-111111111111', 'SL',  'Sick Leave',      12, TRUE,  FALSE),
  ('11111111-1111-1111-1111-111111111111', 'EL',  'Earned Leave',    15, TRUE,  TRUE),
  ('11111111-1111-1111-1111-111111111111', 'LOP', 'Loss of Pay',     NULL, FALSE, FALSE),
  ('11111111-1111-1111-1111-111111111111', 'ML',  'Maternity Leave', 180, TRUE,  FALSE);

-- Approval Workflows
INSERT INTO core.approval_workflows (organization_id, entity_type, name) VALUES
  ('11111111-1111-1111-1111-111111111111', 'stock_inward',      'Stock Inward Approval'),
  ('11111111-1111-1111-1111-111111111111', 'branch_transfer',   'Inter-Branch Transfer Approval'),
  ('11111111-1111-1111-1111-111111111111', 'quotation',         'Quotation Approval'),
  ('11111111-1111-1111-1111-111111111111', 'order',             'Order Approval'),
  ('11111111-1111-1111-1111-111111111111', 'bom',               'BOM Approval'),
  ('11111111-1111-1111-1111-111111111111', 'job_card_release',  'Final Job Card Release'),
  ('11111111-1111-1111-1111-111111111111', 'wastage',           'Excess Wastage Approval'),
  ('11111111-1111-1111-1111-111111111111', 'invoice',           'Invoice Dispatch Approval'),
  ('11111111-1111-1111-1111-111111111111', 'design_release',    'Design Release Approval'),
  ('11111111-1111-1111-1111-111111111111', 'leave_request',     'Leave Request Approval'),
  ('11111111-1111-1111-1111-111111111111', 'payroll',           'Payroll Approval'),
  ('11111111-1111-1111-1111-111111111111', 'financial_close',   'Monthly Financial Close'),
  ('11111111-1111-1111-1111-111111111111', 'blacklist_removal', 'Blacklist Removal Approval'),
  ('11111111-1111-1111-1111-111111111111', 'rma',               'RMA Authorization');

-- =============================================================================
-- USEFUL VIEWS FOR REPORTING
-- =============================================================================

-- Active stock per branch
CREATE VIEW inventory.v_stock_summary AS
SELECT
    b.name                  AS branch_name,
    m.name                  AS material_name,
    mc.name                 AS category,
    sb.purity,
    sb.total_weight         AS total_weight_grams,
    sb.available_weight     AS available_weight_grams,
    sb.reserved_weight      AS reserved_weight_grams,
    sb.wip_weight           AS wip_weight_grams,
    sb.last_updated
FROM inventory.stock_balances sb
JOIN core.branches b ON b.id = sb.branch_id
JOIN inventory.materials m ON m.id = sb.material_id
JOIN inventory.material_categories mc ON mc.id = m.category_id
WHERE sb.available_weight > 0;

-- Job card progress overview
CREATE VIEW production.v_job_card_progress AS
SELECT
    jc.job_card_number,
    jc.branch_id,
    b.name                      AS branch_name,
    js_status.name              AS status,
    jc.planned_start_date,
    jc.planned_end_date,
    jc.actual_start_date,
    jc.completion_pct,
    COUNT(jcs.id)               AS total_stages,
    COUNT(jcs.id) FILTER (WHERE comp.code = 'COMPLETED') AS completed_stages,
    jc.estimated_cost,
    jc.actual_cost,
    (jc.actual_cost - jc.estimated_cost) AS cost_variance
FROM production.job_cards jc
JOIN core.branches b ON b.id = jc.branch_id
JOIN core.lookup_values js_status ON js_status.id = jc.status_id
LEFT JOIN production.job_card_stages jcs ON jcs.job_card_id = jc.id
LEFT JOIN core.lookup_values comp ON comp.id = jcs.status_id
GROUP BY jc.id, jc.job_card_number, jc.branch_id, b.name, js_status.name,
         jc.planned_start_date, jc.planned_end_date, jc.actual_start_date,
         jc.completion_pct, jc.estimated_cost, jc.actual_cost;

-- Outstanding invoices
CREATE VIEW finance.v_outstanding_invoices AS
SELECT
    i.invoice_number,
    b.name          AS branch_name,
    p.name          AS customer_name,
    i.invoice_date,
    i.due_date,
    it.name         AS invoice_type,
    i.total_amount,
    i.amount_paid,
    i.outstanding,
    CASE WHEN i.due_date < CURRENT_DATE THEN TRUE ELSE FALSE END AS is_overdue,
    COALESCE(CURRENT_DATE - i.due_date, 0) AS days_overdue
FROM finance.invoices i
JOIN core.branches b ON b.id = i.branch_id
JOIN core.parties p ON p.id = i.customer_id
JOIN core.lookup_values it ON it.id = i.invoice_type_id
JOIN core.lookup_values ist ON ist.id = i.status_id
WHERE ist.code NOT IN ('PAID', 'CANCELLED', 'WRITTEN_OFF')
  AND i.outstanding > 0;

-- Wastage analysis view
CREATE VIEW production.v_wastage_analysis AS
SELECT
    jc.job_card_number,
    jcs.stage_name,
    m.name              AS material,
    wr.wastage_grams,
    wr.wastage_pct,
    wr.threshold_pct,
    wr.deviation_pct,
    wr.is_within_threshold,
    wt.name             AS wastage_type,
    wr.recorded_at
FROM production.wastage_records wr
JOIN production.job_card_stages jcs ON jcs.id = wr.job_card_stage_id
JOIN production.job_cards jc ON jc.id = jcs.job_card_id
JOIN inventory.materials m ON m.id = wr.material_id
JOIN core.lookup_values wt ON wt.id = wr.wastage_type_id
ORDER BY wr.recorded_at DESC;

-- =============================================================================
-- FINAL NOTES & INDEX SUMMARY
-- =============================================================================
-- Total Tables: 60+
-- Schemas: core, inventory, production, sales, finance, hr, audit
-- Key Design Decisions:
--   1. ALL dropdowns served from core.lookup_values (0 hardcoded enums in app)
--   2. UUID PKs throughout for distributed-safe IDs
--   3. NUMERIC(15,2) for INR amounts; NUMERIC(15,4) for weights in grams
--   4. Purity stored as NUMERIC(6,4) — decimal fraction (0.925 = 92.5%)
--   5. Audit log is append-only with REVOKE UPDATE/DELETE
--   6. stock_balances is a denormalized running total, updated by triggers
--   7. Approval workflow is fully generic via entity_type + entity_id
--   8. All version histories stored as JSONB snapshots
--   9. GST regex validated at DB level for both GSTIN and PAN
--  10. Self-approval prevention (BR-ORG-03) enforced at application + trigger layer
--  11. Generated columns used for balance_due, line_total, is_balanced
--  12. Partial indexes on status columns for active-record queries
-- =============================================================================
