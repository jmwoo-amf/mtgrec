#!/bin/sh
# mtgrec 를 빌드해 ~/.claude/bin 에 설치한다.
set -e
cd "$(dirname "$0")"

swift build -c release
mkdir -p "$HOME/.claude/bin"

# cp 로 제자리 덮어쓰기를 하면 코드 서명이 어긋나 커널이 SIGKILL 로 죽인다
# (실행하면 아무 출력 없이 exit 137). 새 inode 에 쓰고 rename 으로 갈아끼운다.
cp "$(swift build -c release --show-bin-path)/mtgrec" "$HOME/.claude/bin/mtgrec.new"
mv -f "$HOME/.claude/bin/mtgrec.new" "$HOME/.claude/bin/mtgrec"

echo "설치 완료: $HOME/.claude/bin/mtgrec"
if [ ! -f "${MTGREC_CONFIG_DIR:-$HOME/.config/mtgrec}/config.json" ]; then
    echo "설정 파일이 없습니다. Claude Code 에서 /rec setup 을 실행하십시오 (없으면 ~/Recordings/mtgrec 에 저장)."
fi
"$HOME/.claude/bin/mtgrec" --help | head -3
