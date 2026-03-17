# Cloud vs Edge Energy Study — Full Run Command Reference

All commands run from: `/home/dem/major_project/edge_cloud_study`

```
cd /home/dem/major_project/edge_cloud_study
```

---

## Machine Config (for reference)

| Variable         | Value                              |
|------------------|------------------------------------|
| Machine A        | local (this machine)               |
| Machine B IP     | 192.168.1.105                      |
| Machine B user   | dem                                |
| SSH key          | /home/dem/.ssh/edge-cloud-key      |
| GCP instance IP  | 35.238.201.243                     |
| GCP project ID   | project-8067bcb9-192a-4c85-9c5     |
| GCP instance ID  | 4478506382799514660                |
| GCP zone         | us-central1-a                      |

---

## 0 — One-Time Setup

### 0.1 Prepare Machine B (run once)
```bash
bash scripts/utils/setup_client_machine.sh
```

### 0.2 Validate full pipeline
```bash
sudo python3 scripts/utils/validate_pipeline.py
```

### 0.3 Verify Machine B SSH manually
```bash
ssh -i /home/dem/.ssh/edge-cloud-key dem@192.168.1.105 'echo OK'
```

---

## 1 — Capture Baselines (once per session or environment)

### Edge baseline
```bash
bash scripts/edge/capture_client_baseline.sh \
  --session-id exp_edge_001 \
  --environment edge \
  --workload-type file_transfer
```

### Cloud baseline
```bash
bash scripts/edge/capture_client_baseline.sh \
  --session-id exp_cloud_001 \
  --environment cloud \
  --workload-type file_transfer
```

### Check baselines in DB
```bash
sqlite3 data/results.db \
  "SELECT session_id, environment, workload_type, idle_power_scaphandre_w, idle_power_powerstat_w, idle_cpu_percent
   FROM client_energy_baselines ORDER BY baseline_id DESC LIMIT 10;"
```

---

## 2 — Edge Runs

> Uses Containernet topology on Machine A. Client energy measured independently on Machine B.

### file_transfer — small (10 MB)
```bash
sudo bash scripts/edge/run_workload.sh \
  --session-id exp_edge_ft_small_001 \
  --workload file_transfer \
  --size small \
  --runs 1000
```

### file_transfer — medium (100 MB)
```bash
sudo bash scripts/edge/run_workload.sh \
  --session-id exp_edge_ft_medium_001 \
  --workload file_transfer \
  --size medium \
  --runs 1000
```

### file_transfer — large (500 MB)
```bash
sudo bash scripts/edge/run_workload.sh \
  --session-id exp_edge_ft_large_001 \
  --workload file_transfer \
  --size large \
  --runs 1000
```

### video_encoding
```bash
sudo bash scripts/edge/run_workload.sh \
  --session-id exp_edge_video_001 \
  --workload video_encoding \
  --size small \
  --runs 1000
```

### db_query
```bash
sudo bash scripts/edge/run_workload.sh \
  --session-id exp_edge_db_001 \
  --workload db_query \
  --size small \
  --runs 1000
```

### web_request
```bash
sudo bash scripts/edge/run_workload.sh \
  --session-id exp_edge_web_001 \
  --workload web_request \
  --size small \
  --runs 1000
```

---

## 3 — Cloud Runs (GCP)

> iperf3 and HTTP traffic originates FROM Machine B to GCP.
> Machine B measures its own energy during transmission.
> Machine A handles GCP metric polling and DB insertion.

```bash
# Shorthand — paste this block at the top of each cloud command group:
GCP_IP=35.238.201.243
GCP_PROJECT=project-8067bcb9-192a-4c85-9c5
GCP_INSTANCE=4478506382799514660
```

### file_transfer — small (10 MB)
```bash
bash scripts/cloud/run_cloud_workload.sh \
  --session-id exp_cloud_ft_small_001 \
  --workload file_transfer \
  --size small \
  --runs 1000 \
  --instance-ip 35.238.201.243 \
  --project-id project-8067bcb9-192a-4c85-9c5 \
  --instance-id 4478506382799514660
```

### file_transfer — medium (100 MB)
```bash
bash scripts/cloud/run_cloud_workload.sh \
  --session-id exp_cloud_ft_medium_001 \
  --workload file_transfer \
  --size medium \
  --runs 1000 \
  --instance-ip 35.238.201.243 \
  --project-id project-8067bcb9-192a-4c85-9c5 \
  --instance-id 4478506382799514660
```

### file_transfer — large (500 MB)
```bash
bash scripts/cloud/run_cloud_workload.sh \
  --session-id exp_cloud_ft_large_001 \
  --workload file_transfer \
  --size large \
  --runs 1000 \
  --instance-ip 35.238.201.243 \
  --project-id project-8067bcb9-192a-4c85-9c5 \
  --instance-id 4478506382799514660
```

### video_encoding
```bash
bash scripts/cloud/run_cloud_workload.sh \
  --session-id exp_cloud_video_001 \
  --workload video_encoding \
  --size small \
  --runs 1000 \
  --instance-ip 35.238.201.243 \
  --project-id project-8067bcb9-192a-4c85-9c5 \
  --instance-id 4478506382799514660
```

### db_query
```bash
bash scripts/cloud/run_cloud_workload.sh \
  --session-id exp_cloud_db_001 \
  --workload db_query \
  --size small \
  --runs 1000 \
  --instance-ip 35.238.201.243 \
  --project-id project-8067bcb9-192a-4c85-9c5 \
  --instance-id 4478506382799514660
```

### web_request
```bash
bash scripts/cloud/run_cloud_workload.sh \
  --session-id exp_cloud_web_001 \
  --workload web_request \
  --size small \
  --runs 1000 \
  --instance-ip 35.238.201.243 \
  --project-id project-8067bcb9-192a-4c85-9c5 \
  --instance-id 4478506382799514660
```

---

## 4 — Master Orchestrator (run_experiment.py)

> Handles baseline + workload + comparison in one interactive flow.
> Prompts for confirmation at each checkpoint.

### Edge — file_transfer small
```bash
python3 scripts/run_experiment.py \
  --environment edge \
  --workload file_transfer \
  --size small \
  --runs 1000 \
  --session-id exp_edge_ft_small_001
```

### Edge — file_transfer medium
```bash
python3 scripts/run_experiment.py \
  --environment edge \
  --workload file_transfer \
  --size medium \
  --runs 1000 \
  --session-id exp_edge_ft_medium_001
```

### Edge — file_transfer large
```bash
python3 scripts/run_experiment.py \
  --environment edge \
  --workload file_transfer \
  --size large \
  --runs 1000 \
  --session-id exp_edge_ft_large_001
```

### Edge — video_encoding
```bash
python3 scripts/run_experiment.py \
  --environment edge \
  --workload video_encoding \
  --runs 1000 \
  --session-id exp_edge_video_001
```

### Edge — db_query
```bash
python3 scripts/run_experiment.py \
  --environment edge \
  --workload db_query \
  --runs 1000 \
  --session-id exp_edge_db_001
```

### Edge — web_request
```bash
python3 scripts/run_experiment.py \
  --environment edge \
  --workload web_request \
  --runs 1000 \
  --session-id exp_edge_web_001
```

### Cloud — file_transfer small
```bash
python3 scripts/run_experiment.py \
  --environment cloud \
  --workload file_transfer \
  --size small \
  --runs 1000 \
  --session-id exp_cloud_ft_small_001
```

### Cloud — file_transfer medium
```bash
python3 scripts/run_experiment.py \
  --environment cloud \
  --workload file_transfer \
  --size medium \
  --runs 1000 \
  --session-id exp_cloud_ft_medium_001
```

### Cloud — file_transfer large
```bash
python3 scripts/run_experiment.py \
  --environment cloud \
  --workload file_transfer \
  --size large \
  --runs 1000 \
  --session-id exp_cloud_ft_large_001
```

### Cloud — video_encoding
```bash
python3 scripts/run_experiment.py \
  --environment cloud \
  --workload video_encoding \
  --runs 1000 \
  --session-id exp_cloud_video_001
```

### Cloud — db_query
```bash
python3 scripts/run_experiment.py \
  --environment cloud \
  --workload db_query \
  --runs 1000 \
  --session-id exp_cloud_db_001
```

### Cloud — web_request
```bash
python3 scripts/run_experiment.py \
  --environment cloud \
  --workload web_request \
  --runs 1000 \
  --session-id exp_cloud_web_001
```

---

## 5 — Quick 3-Run Validation Tests

Use these to verify a new session works before committing to 1000 runs.

### Edge — 3-run smoke test
```bash
sudo bash scripts/edge/run_workload.sh \
  --session-id smoke_edge_001 \
  --workload file_transfer \
  --size small \
  --runs 3
```

### Cloud — 3-run smoke test
```bash
bash scripts/cloud/run_cloud_workload.sh \
  --session-id smoke_cloud_001 \
  --workload file_transfer \
  --size small \
  --runs 3 \
  --instance-ip 35.238.201.243 \
  --project-id project-8067bcb9-192a-4c85-9c5 \
  --instance-id 4478506382799514660
```

### Verify client_energy_runs has non-zero separate rows
```bash
sqlite3 data/results.db "
SELECT session_id, environment, workload_type,
       client_scaphandre_joules, client_powerstat_joules,
       cpu_avg_percent, notes
FROM client_energy_runs
ORDER BY run_id DESC LIMIT 20;"
```

---

## 6 — Analysis

### Compare client energy (all sessions for a workload)
```bash
python3 scripts/analysis/compare_client_energy.py --workload file_transfer
python3 scripts/analysis/compare_client_energy.py --workload video_encoding
python3 scripts/analysis/compare_client_energy.py --workload db_query
python3 scripts/analysis/compare_client_energy.py --workload web_request
```

### Compare client energy for a specific session
```bash
python3 scripts/analysis/compare_client_energy.py \
  --workload file_transfer \
  --session-id exp_edge_ft_small_001
```

### Full server-side comparison (edge vs cloud server energy)
```bash
python3 scripts/analysis/compare_results.py \
  --workload file_transfer \
  --session-id exp_edge_ft_small_001
```

### Raw DB queries — run counts
```bash
sqlite3 data/results.db "
SELECT environment, workload_type,
       COUNT(*) as runs,
       ROUND(SUM(client_scaphandre_joules),2) as total_scaph_j,
       ROUND(AVG(client_scaphandre_joules),4) as avg_scaph_j,
       ROUND(AVG(client_cpu_avg_percent),2) as avg_cpu_pct
FROM client_energy_runs
GROUP BY environment, workload_type
ORDER BY environment, workload_type;"
```

### Raw DB queries — edge server energy
```bash
sqlite3 data/results.db "
SELECT session_id, workload_type, COUNT(*) as runs,
       ROUND(AVG(scaphandre_joules),4) as avg_scaph_j,
       ROUND(AVG(duration_seconds),3) as avg_dur_s
FROM edge_runs
GROUP BY session_id, workload_type
ORDER BY rowid DESC LIMIT 20;"
```

### Raw DB queries — cloud runs
```bash
sqlite3 data/results.db "
SELECT session_id, workload_type, COUNT(*) as runs,
       ROUND(AVG(duration_seconds),3) as avg_dur_s,
       ROUND(AVG(bandwidth_out_mb),2) as avg_bw_mbs
FROM cloud_runs
GROUP BY session_id, workload_type
ORDER BY rowid DESC LIMIT 20;"
```

---

## 7 — GCP Carbon Footprint Fetch (run 4–6 weeks after experiment)

```bash
# Step 1: find your GCP org ID
gcloud organizations list

# Step 2: fetch carbon data for all recorded sessions
python3 scripts/cloud/fetch_gcp_energy.py \
  --mode fetch_mode \
  --org-id <YOUR_ORG_ID>

# Or via run_experiment.py fetch mode
python3 scripts/run_experiment.py --cloud-mode fetch_mode
```

---

## 8 — Teardown GCP Instance

> Only run after ALL cloud workload batches are complete.

```bash
bash scripts/cloud/teardown_gcp_instance.sh \
  --project-id project-8067bcb9-192a-4c85-9c5 \
  --zone us-central1-a

# Force teardown (skips workloads_pending check)
bash scripts/cloud/teardown_gcp_instance.sh \
  --project-id project-8067bcb9-192a-4c85-9c5 \
  --zone us-central1-a \
  --force
```

---

## 9 — Session ID Convention

| Workload           | Size   | Edge session ID              | Cloud session ID              |
|--------------------|--------|------------------------------|-------------------------------|
| file_transfer      | small  | exp_edge_ft_small_001        | exp_cloud_ft_small_001        |
| file_transfer      | medium | exp_edge_ft_medium_001       | exp_cloud_ft_medium_001       |
| file_transfer      | large  | exp_edge_ft_large_001        | exp_cloud_ft_large_001        |
| video_encoding     | —      | exp_edge_video_001           | exp_cloud_video_001           |
| db_query           | —      | exp_edge_db_001              | exp_cloud_db_001              |
| web_request        | —      | exp_edge_web_001             | exp_cloud_web_001             |

Increment the trailing number (`_002`, `_003` …) for repeat runs.

---

## 10 — Recommended Run Order

Run each pair (edge then cloud) before moving to the next workload.
Re-run validation between batches if anything looks wrong.

```
1.  bash scripts/utils/setup_client_machine.sh          # Machine B — once only
2.  sudo python3 scripts/utils/validate_pipeline.py     # confirm 88/88

3.  [edge]  file_transfer small   → exp_edge_ft_small_001
4.  [cloud] file_transfer small   → exp_cloud_ft_small_001
5.  compare_client_energy --workload file_transfer

6.  [edge]  file_transfer medium  → exp_edge_ft_medium_001
7.  [cloud] file_transfer medium  → exp_cloud_ft_medium_001

8.  [edge]  file_transfer large   → exp_edge_ft_large_001
9.  [cloud] file_transfer large   → exp_cloud_ft_large_001

10. [edge]  video_encoding        → exp_edge_video_001
11. [cloud] video_encoding        → exp_cloud_video_001
12. compare_client_energy --workload video_encoding

13. [edge]  db_query              → exp_edge_db_001
14. [cloud] db_query              → exp_cloud_db_001

15. [edge]  web_request           → exp_edge_web_001
16. [cloud] web_request           → exp_cloud_web_001

17. bash scripts/cloud/teardown_gcp_instance.sh ...     # after all cloud batches
18. [4–6 weeks later] fetch_gcp_energy.py --mode fetch_mode
```
