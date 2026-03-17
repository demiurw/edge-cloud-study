CREATE TABLE IF NOT EXISTS edge_runs (
    run_id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    workload_type TEXT NOT NULL,
    workload_size_mb REAL,
    run_number INTEGER NOT NULL,
    timestamp_start TEXT NOT NULL,
    timestamp_end TEXT NOT NULL,
    duration_seconds REAL,
    data_sent_mb REAL,
    scaphandre_joules REAL,
    powerstat_joules REAL,
    cpu_peak_percent REAL,
    cpu_avg_percent REAL,
    powertop_flag TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS edge_baselines (
    baseline_id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    workload_type TEXT,
    idle_power_scaphandre_w REAL,
    idle_power_powerstat_w REAL,
    idle_cpu_percent REAL,
    baseline_duration_seconds REAL DEFAULT 60,
    baseline_energy_joules REAL,
    dominant_idle_processes TEXT
);

CREATE TABLE IF NOT EXISTS cloud_runs (
    run_id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    workload_type TEXT NOT NULL,
    workload_size_mb REAL,
    run_number INTEGER NOT NULL,
    timestamp_start TEXT NOT NULL,
    timestamp_end TEXT NOT NULL,
    duration_seconds REAL,
    data_sent_mb REAL,
    bandwidth_out_mb REAL,
    response_time_ms REAL,
    cpu_avg_percent REAL,
    request_count INTEGER,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS cloud_derived_energy (
    derivation_id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    workload_type TEXT NOT NULL,
    total_bandwidth_gb REAL,
    total_cpu_hours REAL,
    mean_response_time_ms REAL,
    total_requests INTEGER,
    energy_model_used TEXT,
    energy_per_gb_wh REAL,
    pue_factor REAL,
    datacenter_region TEXT,
    estimated_total_energy_joules REAL,
    estimated_energy_per_request_joules REAL,
    estimated_energy_per_gb_joules REAL,
    estimated_cost_usd REAL,
    derivation_notes TEXT,
    timestamp TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    workload_type TEXT,
    environment TEXT,
    team_notes TEXT,
    status TEXT DEFAULT 'active'
);
