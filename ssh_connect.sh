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

# インスタンス破棄用のクリーンアップ関数
cleanup() {
    if [ -n "$INSTANCE_ID" ]; then
        echo "インスタンス $INSTANCE_ID を破棄しています..." >&2
        ./.venv/bin/vastai destroy instance "$INSTANCE_ID" -y > /dev/null 2>&1
    fi
}
# 終了時、割り込み時、強制終了時にクリーンアップを実行
trap cleanup EXIT INT TERM

echo "取得したInstance ID: $INSTANCE_ID" >&2
echo "取得したSSH URL: $SSH_URL" >&2

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

# instance.info をローカルに作成（毎回上書き）
cat <<EOF > instance.info
Instance ID:   $INSTANCE_ID
SSH Host:      $SSH_HOST
SSH Port:      $SSH_PORT
Price:         \$$PRICE/h
Net Speed:     Up: ${INET_UP}Mbps / Down: ${INET_DOWN}Mbps
NVIDIA Driver: $DRIVER
CUDA Version:  $CUDA
Location:      $LOCATION
EOF

# ファイルの転送処理 (auth.json と instance.info)
echo "インスタンスの起動完了を待っています (最大120秒)..." >&2

MAX_RETRIES=24
RETRY_COUNT=0
SUCCESS_AUTH=false
SUCCESS_INFO=false
SUCCESS_GIT=false

if [ ! -f "$HOME/.codex/auth.json" ]; then
    echo "注意: ローカルに $HOME/.codex/auth.json が見つからないため、転送をスキップします。" >&2
    SUCCESS_AUTH=true # スキップするので成功扱い
fi

if [ ! -f "$HOME/.git-credentials" ]; then
    echo "注意: ローカルに $HOME/.git-credentials が見つからないため、GitHub認証情報の転送をスキップします。" >&2
    SUCCESS_GIT=true # スキップ
fi

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "接続を試行中 ($((RETRY_COUNT + 1))/$MAX_RETRIES)..." >&2
    
    # SSH接続チェック
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@"$SSH_HOST" -p "$SSH_PORT" "exit" > /dev/null 2>&1; then
        # instance.info の転送
        if scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$SSH_PORT" instance.info root@"$SSH_HOST":~/instance.info > /dev/null 2>&1; then
            echo "instance.info の転送に成功しました。" >&2
            SUCCESS_INFO=true
        fi

        # auth.json の転送 (存在する場合のみ)
        if [ "$SUCCESS_AUTH" = false ]; then
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$SSH_HOST" -p "$SSH_PORT" "mkdir -p ~/.codex" > /dev/null 2>&1
            if scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$SSH_PORT" "$HOME/.codex/auth.json" root@"$SSH_HOST":~/.codex/auth.json > /dev/null 2>&1; then
                echo "auth.json の転送に成功しました。" >&2
                SUCCESS_AUTH=true
            fi
        fi

        # GitHub 認証情報と設定の転送 (存在する場合のみ)
        if [ "$SUCCESS_GIT" = false ]; then
            if scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$SSH_PORT" "$HOME/.git-credentials" root@"$SSH_HOST":~/.git-credentials > /dev/null 2>&1; then
                # credential.helper の設定
                ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$SSH_HOST" -p "$SSH_PORT" "git config --global credential.helper store" > /dev/null 2>&1
                
                # ユーザー情報の同期
                LOCAL_GIT_NAME=$(git config --global user.name)
                LOCAL_GIT_EMAIL=$(git config --global user.email)
                if [ -n "$LOCAL_GIT_NAME" ] && [ -n "$LOCAL_GIT_EMAIL" ]; then
                    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$SSH_HOST" -p "$SSH_PORT" "git config --global user.name \"$LOCAL_GIT_NAME\" && git config --global user.email \"$LOCAL_GIT_EMAIL\"" > /dev/null 2>&1
                fi
                
                echo "Git 認証情報と設定の転送に成功しました。" >&2
                SUCCESS_GIT=true
            fi
        fi

        if [ "$SUCCESS_INFO" = true ] && [ "$SUCCESS_AUTH" = true ] && [ "$SUCCESS_GIT" = true ]; then
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
if [ "$SUCCESS_GIT" = false ]; then
    echo "エラー: Git 認証情報の転送に失敗しました。" >&2
fi

RETRY_DONE=false

while true; do
    echo "接続しています: ssh root@$SSH_HOST -p $SSH_PORT" >&2
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=5"
    if [ -n "$WELCOME_COMMAND" ]; then
        ssh -t $SSH_OPTS root@"$SSH_HOST" -p "$SSH_PORT" "$WELCOME_COMMAND"
    else
        ssh -t $SSH_OPTS root@"$SSH_HOST" -p "$SSH_PORT"
    fi
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
