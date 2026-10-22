#!/bin/zsh
set -euo pipefail

app="/Applications/Glint.app"
if [[ ! -d "$app" ]]; then
  echo "未找到 /Applications/Glint.app，请先将 Glint 拖入应用程序文件夹。"
  read -r "?按回车关闭窗口。"
  exit 1
fi

"$app/Contents/MacOS/Glint" --diagnose
echo
read -r "?诊断完成。按回车关闭窗口。"
