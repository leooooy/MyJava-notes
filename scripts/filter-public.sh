#!/usr/bin/env bash
# 生成"公开版"内容（就地修改当前工作树）：
#   1. 删除私有模块 Project/ 和 Interview/
#   2. 从 SUMMARY.md 侧边栏移除这两个模块的所有条目
#   3. 把其它文章里指向它们的跨链接降级为纯文本（保留文字、去掉链接）
#   4. 删除仅供本地/编辑用的目录
# 由 publish-public.yml 在一次性 CI runner 的临时副本上运行。须在仓库根目录运行。
set -euo pipefail

# 0. 安全保险：本脚本会就地删除 Project/Interview 并改写 SUMMARY/README，
#    本应只在 GitHub Actions runner 的临时副本上跑。若既不在 CI、又没显式放行，
#    直接拒绝，避免在本地主工作目录手滑误删原始文档。
if [[ -z "${GITHUB_ACTIONS:-}" && -z "${ALLOW_LOCAL:-}" ]]; then
  echo "拒绝执行：本脚本会删除 Project/Interview 并改写 SUMMARY/README，仅应在 CI 中运行。" >&2
  echo "若确需在某个一次性副本上手动运行，请显式设置 ALLOW_LOCAL=1（务必确认当前不是你的主工作目录！）。" >&2
  exit 1
fi

# 1. 私有模块整体删除
rm -rf Project Interview

# 2. 从目录（SUMMARY.md）中删掉指向这两个模块的行（父节点 + 所有子条目）
sed -i -E '/\]\((Project|Interview)\//d' SUMMARY.md

# 3. 首页 README 专项清理（landing page 要最干净）
#    a. 删掉整行指向 Project/Interview 的导航表格行（仅首页，避免误删其它文件里"捎带提一句"的行）
sed -i -E '/^\|.*\]\((Project|Interview)\//d' README.md
#    b. 去掉正文里对 Project 模块的纯文字提及（连接词+加粗，或学习路径箭头）
#    注意：这是针对 README 现有措辞的定向清理，README 改版后需同步更新此规则
perl -i -pe 's/\s*(?:与|\+)\s*\*\*Project\*\*//g; s/\s*→\s*Project\b//g;' README.md

# 4. 其它 .md 里残留的跨链接 [文字](../Project/x) → 文字（按字节处理，保留中文）
find . -type f -name '*.md' \
  -not -path './node_modules/*' -not -path './_book/*' -print0 \
| xargs -0 perl -i -pe 's/\[([^\]]+)\]\((?:\.\.\/)?(?:Project|Interview)\/[^)]*\)/$1/g'

# 5. 公开副本里不需要的本地目录
rm -rf .idea
