#!/bin/bash
# =============================================================================
# run_commands.sh — Experiment Run Commands
# =============================================================================
# All commands to execute the 1000-run experiment batches for each workload.
# Run edge before cloud for each session ID.
# Edge runs require sudo. Cloud runs do not.
# GCP instance: 34.41.147.159 (e2-medium, us-central1-a)
# Machine B:    100.79.129.127 (dedicated client)
# =============================================================================

cd /home/dem/major_project/edge_cloud_study

# --- file_transfer: small (10 MB) ---
sudo bash scripts/edge/run_workload.sh --session-id exp_file_transfer_small_001 --workload file_transfer --size small --runs 1000
bash scripts/cloud/run_cloud_workload.sh --session-id exp_file_transfer_small_001 --workload file_transfer --size small --runs 1000

# --- file_transfer: medium (100 MB) ---
sudo bash scripts/edge/run_workload.sh --session-id exp_file_transfer_medium_001 --workload file_transfer --size medium --runs 1000
bash scripts/cloud/run_cloud_workload.sh --session-id exp_file_transfer_medium_001 --workload file_transfer --size medium --runs 1000

# --- file_transfer: large (500 MB) ---
sudo bash scripts/edge/run_workload.sh --session-id exp_file_transfer_large_001 --workload file_transfer --size large --runs 1000
bash scripts/cloud/run_cloud_workload.sh --session-id exp_file_transfer_large_001 --workload file_transfer --size large --runs 1000

# --- video_encoding ---
sudo bash scripts/edge/run_workload.sh --session-id exp_video_encoding_001 --workload video_encoding --runs 1000
bash scripts/cloud/run_cloud_workload.sh --session-id exp_video_encoding_001 --workload video_encoding --runs 1000

# --- database_query ---
sudo bash scripts/edge/run_workload.sh --session-id exp_db_query_001 --workload db_query --runs 1000
bash scripts/cloud/run_cloud_workload.sh --session-id exp_db_query_001 --workload db_query --runs 1000
