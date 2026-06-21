import sys
from vastai import VastAI
import time
from packaging.version import Version, InvalidVersion

vast = VastAI()

def parse_version(value):
    try:
        return Version(str(value))
    except (InvalidVersion, TypeError):
        return None

def has_required_driver(offer):
    version = parse_version(offer.get("driver_version"))
    return version is not None and version >= Version("580.65.06")

def has_required_cuda(offer):
    cuda_vers = offer.get("cuda_vers", offer.get("cuda_max_good", 0))
    try:
        return float(cuda_vers) >= 13.0
    except (TypeError, ValueError):
        return False

# インスタンスの検索
offers = vast.search_offers(
    query=(
        "gpu_name=RTX_5090 "
        "num_gpus=1 "
        "verified=true "
        "direct_port_count>=1 "
        "rentable=true "
        "driver_version >= 580.65.06 "
        "cuda_vers >= 13.0"
    ),
    order="dph_total",
    type="ondemand",
    limit="50",
    storage=200,
)

# 信頼度が 90% 以上、かつ通信速度が 500Mbps 以上のものをフィルタリング
filtered_offers = [
    o for o in offers 
    if o.get('reliability', 0) >= 0.90 
    and o.get('inet_up', 0) >= 500 
    and o.get('inet_down', 0) >= 500
    and has_required_driver(o)
    and has_required_cuda(o)
]

# 価格（dph_total）の安い順にソート（念のためPython側でも実施）
filtered_offers.sort(key=lambda x: x.get('dph_total', 0))

if not filtered_offers:
    print("条件に合致するインスタンスが見つかりませんでした。", file=sys.stderr)
    exit(1)

# 表示件数を最大10件に制限
display_offers = filtered_offers[:10]

print(
    f"{'ID':<10} {'GPU':<15} {'Price ($/h)':<12} "
    f"{'Up/Down (Mbps)':<20} {'Reliability':<12} "
    f"{'Driver':<12} {'CUDA':<6} {'Location':<15}",
    file=sys.stderr,
)
print("-" * 110, file=sys.stderr)

for offer in display_offers:
    o_id = offer.get('id', 'N/A')
    gpu = offer.get('gpu_name', 'N/A')
    price = offer.get('dph_total', 0)
    inet_up = offer.get('inet_up', 0)
    inet_down = offer.get('inet_down', 0)
    reliability = offer.get('reliability', 0)
    driver = offer.get('driver_version', 'N/A')
    cuda = offer.get('cuda_vers', offer.get('cuda_max_good', 'N/A'))
    location = offer.get('geolocation', 'N/A')
    
    print(
        f"{o_id:<10} {gpu:<15} {price:<12.4f} "
        f"{inet_up:>7.1f}/{inet_down:<7.1f} {reliability:<12.2%} "
        f"{driver:<12} {cuda:<6} {location:<15}",
        file=sys.stderr,
    )

# ループ処理の中でオファーごとのIDと価格を取得
for offer in filtered_offers:
    OFFER_ID = offer.get('id')
    on_demand_price = offer.get('dph_total')

    print(f"\nCreating on-demand instance with OFFER_ID: {OFFER_ID} at ${on_demand_price}/hr", file=sys.stderr)

    try:
        result = vast.create_instance(
            id=OFFER_ID,
            image="nvcr.io/nvidia/pytorch:26.04-py3",
            disk=150,
            onstart_cmd="echo hello && nvidia-smi",
            runtype="ssh_direc ssh_proxy",
        )

        if not result or "new_contract" not in result:
            print(f"Failed to create instance for offer {OFFER_ID}. Result: {result}", file=sys.stderr)
            continue

        instance_id = result["new_contract"]
        print(f"Instance {instance_id} created. Waiting for it to start (timeout 600s)...", file=sys.stderr)

        start_time = time.time()
        empty_detail_start_time = None
        preparing_gpus_start_time = None
        success = False
        while time.time() - start_time < 600:
            # show_instance might return a list or a single dict depending on version/call
            info = vast.show_instance(id=instance_id)
            if isinstance(info, list):
                info = info[0] if info else {}
            
            status = info.get("actual_status")
            status_msg = (info.get("status_msg") or "").strip()
            print(f"Status: {status} | Detail: {status_msg}", file=sys.stderr)

            if status == "running":
                # ダイレクト接続情報が取得できるまで少し待つ
                # 10秒毎に12回 (最大120秒) 待機するように延長
                for i in range(12): 
                    # 1. direct_ip_ssh フィールドを確認
                    if info.get("direct_ip_ssh") and info.get("direct_port_ssh"):
                        print(f"\nDirect SSH info found (direct_ip_ssh) after {i*10}s.", file=sys.stderr)
                        break
                    
                    # 2. public_ipaddr と ports["22/tcp"] を確認
                    if info.get("public_ipaddr") and info.get("ports"):
                        ssh_ports = info.get("ports", {}).get("22/tcp", [])
                        if ssh_ports:
                            print(f"\nDirect SSH info found (public_ipaddr) after {i*10}s.", file=sys.stderr)
                            break

                    print(f"Waiting for direct SSH info... ({i+1}/12)", file=sys.stderr)
                    time.sleep(10)
                    info = vast.show_instance(id=instance_id)
                    if isinstance(info, list):
                        info = info[0] if info else {}
                else:
                    print("\nDirect SSH info not found after 120s. Falling back to Proxy.", file=sys.stderr)
                
                success = True
                break

            # Status: None または loading で Detail が空の状態が60秒続いたら次のオーダーへ
            if status in [None, "loading"] and not status_msg:
                if empty_detail_start_time is None:
                    empty_detail_start_time = time.time()
                elif time.time() - empty_detail_start_time >= 60:
                    print(f"\n⚠️ 60秒間ステータスに進展がないため、次のオーダーに移行します。", file=sys.stderr)
                    success = False
                    break
            else:
                empty_detail_start_time = None

            # status_msg が "Preparing GPUs..." で60秒以上経過したら次のオーダーへ
            if status_msg == "Preparing GPUs...":
                if preparing_gpus_start_time is None:
                    preparing_gpus_start_time = time.time()
                elif time.time() - preparing_gpus_start_time >= 60:
                    print(f"\n⚠️ 「Preparing GPUs...」が60秒以上続いたため、次のオーダーに移行します。", file=sys.stderr)
                    success = False
                    break
            else:
                preparing_gpus_start_time = None

            # status_msg にエラーの兆候があれば、タイムアウトを待たずに即座に諦める
            error_keywords = ["error", "failed", "oci runtime", "denied", "unknown"]
            if any(keyword in status_msg.lower() for keyword in error_keywords):
                print(f"\n❌ ホスト側の致命的なエラーを検知しました: {status_msg}", file=sys.stderr)
                print("このインスタンスの起動を諦め、破棄して次のオファーに移行します。", file=sys.stderr)
                success = False
                break

            time.sleep(10)

        if success:
            print(f"Successfully started instance: {instance_id}", file=sys.stderr)
            print("-" * 30, file=sys.stderr)
            print(f"  Instance ID: {instance_id}", file=sys.stderr)
            print(f"  GPU Name:    {offer.get('gpu_name', 'N/A')}", file=sys.stderr)
            print(f"  Price:       ${offer.get('dph_total', 0):.4f}/h", file=sys.stderr)
            print(f"  Net Speed:   Up: {offer.get('inet_up', 0):.1f} Mbps / Down: {offer.get('inet_down', 0):.1f} Mbps", file=sys.stderr)
            print(f"  Location:    {offer.get('geolocation', 'N/A')}", file=sys.stderr)
            print("-" * 30, file=sys.stderr)
            
            # Output details to stdout for the Bash script to capture
            ssh_host = info.get("ssh_host")
            ssh_port = info.get("ssh_port")
            direct_ip = info.get("direct_ip_ssh")
            direct_port = info.get("direct_port_ssh")

            # Fallback to public_ipaddr and ports if direct_ip_ssh is not there
            if not direct_ip and info.get("public_ipaddr") and info.get("ports"):
                ports = info.get("ports", {})
                ssh_ports = ports.get("22/tcp", [])
                if ssh_ports:
                    direct_ip = info.get("public_ipaddr")
                    direct_port = ssh_ports[0].get("HostPort")

            if direct_ip and direct_port:
                ssh_url = f"ssh://root@{direct_ip}:{direct_port}"
                print(f"  SSH (Direct): {direct_ip}:{direct_port}", file=sys.stderr)
            else:
                ssh_url = vast.ssh_url(id=instance_id)
                print(f"  SSH (Proxy):  {ssh_host}:{ssh_port}", file=sys.stderr)
            
            price = offer.get('dph_total', 0)
            inet_up = offer.get('inet_up', 0)
            inet_down = offer.get('inet_down', 0)
            driver = offer.get('driver_version', 'N/A')
            cuda = offer.get('cuda_vers', offer.get('cuda_max_good', 'N/A'))
            location = offer.get('geolocation', 'N/A')
            
            print(f"{instance_id} {ssh_url} {price} {inet_up} {inet_down} {driver} {cuda} {location}")
            break
        else:
            print(f"Instance {instance_id} did not start within 600 seconds. Destroying and trying next...", file=sys.stderr)
            vast.destroy_instance(id=instance_id)
    except Exception as e:
        print(f"An error occurred while processing offer {OFFER_ID}: {e}", file=sys.stderr)
        continue
else:
    print("Could not start any instance after trying all filtered offers.", file=sys.stderr)
    exit(1)

