#!/bin/bash

# .venv内のpythonを使用
PYTHON="./.venv/bin/python"

echo "Instanceを検索後、最も条件に合うインスタンスを起動します..." >&2
# instance_create.pyを実行し、標準出力からInstance ID, SSH URL, および詳細情報を取得
read -r INSTANCE_ID SSH_URL PRICE INET_UP INET_DOWN DRIVER CUDA LOCATION < <($PYTHON instance_create.py)

if [ -z "$INSTANCE_ID" ] || [ -z "$SSH_URL" ]; then
    echo "エラー: インスタンス作成または接続情報の取得に失敗しました。" >&2
    exit 1
fi

echo "取得したInstance ID: $INSTANCE_ID" >&2
echo "取得したSSH URL: $SSH_URL" >&2

# instance.info をローカルに作成（毎回上書き）
cat <<EOF > instance.info
Instance ID:   $INSTANCE_ID
Price:         \$$PRICE/h
Net Speed:     Up: ${INET_UP}Mbps / Down: ${INET_DOWN}Mbps
NVIDIA Driver: $DRIVER
CUDA Version:  $CUDA
Location:      $LOCATION
EOF

# URLからホストとポートを抽出
# 期待される形式: ssh://root@IP:PORT または root@IP:PORT
# 1. 'ssh://' を削除
# 2. 'root@' を削除
# 3. ':' で分割して IP と PORT を取得
CLEAN_URL=$(echo "$SSH_URL" | sed -e 's/ssh:\/\///' -e 's/root@//')
SSH_HOST=$(echo "$CLEAN_URL" | cut -d: -f1)
SSH_PORT=$(echo "$CLEAN_URL" | cut -d: -f2)

if [ -z "$SSH_HOST" ] || [ -z "$SSH_PORT" ]; then
    echo "エラー: ホストまたはポートの解析に失敗しました。 URL: $SSH_URL" >&2
    exit 1
fi

# ファイルの転送処理 (auth.json と instance.info)
echo "インスタンスの起動完了を待っています (最大60秒)..." >&2

MAX_RETRIES=12
RETRY_COUNT=0
SUCCESS_AUTH=false
SUCCESS_INFO=false

if [ ! -f "$HOME/.codex/auth.json" ]; then
    echo "注意: ローカルに $HOME/.codex/auth.json が見つからないため、転送をスキップします。" >&2
    SUCCESS_AUTH=true # スキップするので成功扱い
fi

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "接続を試行中 ($((RETRY_COUNT + 1))/$MAX_RETRIES)..." >&2
    
    # SSH接続チェック
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$SSH_HOST" -p "$SSH_PORT" "exit" > /dev/null 2>&1; then
        # instance.info の転送
        if scp -o StrictHostKeyChecking=no -P "$SSH_PORT" instance.info root@"$SSH_HOST":~/instance.info > /dev/null 2>&1; then
            echo "instance.info の転送に成功しました。" >&2
            SUCCESS_INFO=true
        fi

        # auth.json の転送 (存在する場合のみ)
        if [ "$SUCCESS_AUTH" = false ]; then
            ssh -o StrictHostKeyChecking=no root@"$SSH_HOST" -p "$SSH_PORT" "mkdir -p ~/.codex" > /dev/null 2>&1
            if scp -o StrictHostKeyChecking=no -P "$SSH_PORT" "$HOME/.codex/auth.json" root@"$SSH_HOST":~/.codex/auth.json > /dev/null 2>&1; then
                echo "auth.json の転送に成功しました。" >&2
                SUCCESS_AUTH=true
            fi
        fi

        if [ "$SUCCESS_INFO" = true ] && [ "$SUCCESS_AUTH" = true ]; then
            break
        fi
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 5
done

if [ "$SUCCESS_INFO" = false ]; then
    echo "エラー: instance.info の転送に失敗しました。" >&2
fi
if [ "$SUCCESS_AUTH" = false ]; then
    echo "エラー: auth.json の転送に失敗しました。" >&2
fi

RETRY_DONE=false

while true; do
    echo "接続しています: ssh root@$SSH_HOST -p $SSH_PORT" >&2
    ssh -t -o StrictHostKeyChecking=no root@"$SSH_HOST" -p "$SSH_PORT" "$WELCOME_COMMAND"
    SSH_EXIT_CODE=$?

    if [ $SSH_EXIT_CODE -eq 0 ]; then
        echo "SSHセッションが正常に終了しました。" >&2
        break
    fi

    if [ "$RETRY_DONE" = true ]; then
        echo "再接続試行後も接続が維持できませんでした (Exit code: $SSH_EXIT_CODE)。" >&2
        break
    fi

    echo "SSH接続が中断されました (Exit code: $SSH_EXIT_CODE)。10秒後に一度だけ再接続を試みます..." >&2
    RETRY_DONE=true
    sleep 10
done

echo "インスタンス $INSTANCE_ID を破棄しています..." >&2
./.venv/bin/vastai destroy instance "$INSTANCE_ID"
