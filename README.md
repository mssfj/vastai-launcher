# Vast.ai Instance Management Tools

A set of scripts to automatically find, launch, connect to, and terminate GPU instances (e.g., NVIDIA RTX 4090) on Vast.ai with optimal conditions.

## Key Features

- **Automated Search & Launch**: utomatically finds and launches instances that meet your specific performance criteria.
- **One-Command SSH**: Handles the entire lifecycle from searching to SSH connection in a single command.
- **Auto-Environment Setup**: Transfers local credentials (`auth.json`) and instance metadata to the remote host automatically.
- **Automatic Cleanup**: Automatically **destroys** the instance upon SSH logout to prevent unnecessary charges.

## Setup

### 1. Install Dependencies

This project uses `uv` for dependency management.

```bash
uv sync
```

Or using pip:

```bash
pip install vastai packaging
```

### 2. Configure Vast.ai API Key

Ensure the Vast.ai CLI is authenticated.

```bash
./.venv/bin/vastai set api-key <YOUR_API_KEY>
```

## Usage: `ssh_connect.sh`

The `ssh_connect.sh` script is the primary entry point. It automates the following workflow:

```bash
./ssh_connect.sh
```

**Workflow:**
1. **Search & Create**: Runs `instance_create.py` to find and bid on the best available instance.
2. **Wait for Boot**: Polls the instance status until it is `running`.
3. **Data Transfer**: Securely copies `instance.info` and your local `~/.codex/auth.json` (if it exists) to the remote instance.
4. **Interactive SSH**: Establishes an SSH session with a custom welcome message and `nvidia-smi` output.
5. **Automatic Destruction**: Once you `exit` the SSH session, the script immediately runs `vastai destroy instance` to stop billing.

## Instance Selection Criteria

The `instance_create.py` script filters for high-quality hosts. You can customize these filters by editing the `query` and `filtered_offers` logic in the script.

### Current Filtering Logic

The script searches for instances that meet the following strict requirements:

| Requirement | Value / Condition |
| :--- | :--- |
| **GPU Model** | RTX 4090 (`gpu_name=RTX_4090`) |
| **GPU Count** | 1 (`num_gpus=1`) |
| **Verification** | Verified Hosts Only (`verified=true`) |
| **Reliability** | ≥ 99% |
| **Network Speed** | ≥ 500 Mbps Up / 500 Mbps Down |
| **NVIDIA Driver** | ≥ 580.65.06 |
| **CUDA Version** | ≥ 13.0 |
| **Disk Space** | 150 GB |
| **Pricing Type** | Interruptible (Bid) |

### Search Query Snippet (`instance_create.py`) ***  Modify this query as needed.***

```python
offers = vast.search_offers(
    query=(
        "gpu_name=RTX_4090 "
        "num_gpus=1 "
        "verified=true "
        "direct_port_count>=1 "
        "rentable=true "
        "driver_version >= 580.65.06 "
        "cuda_vers >= 13.0"
    ),
    order="dph_total",
    type="bid",
    limit="50",
    storage=150,
)
```

## File Transfers

Upon successful connection, the following files are available in the remote `~/` directory:

- `instance.info`: Contains metadata such as Instance ID, Price, Network Speed, and Driver versions.
- `~/.codex/auth.json`: Mirrored from your local `$HOME/.codex/auth.json` (useful for private API access from the instance).

## Important Notes

- **Data Volatility**: This tool is designed for ephemeral workloads. Since the instance is **destroyed** on exit, ensure you save any important work to external storage (e.g., S3, GitHub, or `scp` back to local) before logging out.
- **Bid Pricing**: Uses "Interruptible" pricing. Your instance may be outbid and terminated if market prices rise.
