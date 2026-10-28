#!/usr/bin/env bash
# Quality gate dựa trên baseline: chỉ tính các finding MỚI so với baseline.
#
# Cách dùng: bash security-gate/gate.sh <tên> <key-hiện-tại> <key-baseline> <ngoại-lệ>
#   <key-hiện-tại>  : file mỗi dòng một khóa finding của lần quét này
#   <key-baseline>  : file khóa đã ghi nhận ở baseline (có thể chưa tồn tại)
#   <ngoại-lệ>      : file ngoại lệ, mỗi dòng "KHÓA;;YYYY-MM-DD;;lý do"
#                     (ngoại lệ hết hạn sau ngày ghi trong cột 2; dòng bắt đầu bằng # là ghi chú)
#
# Kết quả: in tóm tắt, ghi vào $GITHUB_STEP_SUMMARY và $GITHUB_OUTPUT (new_count, expired_count).
# Script luôn thoát mã 0; workflow tự quyết định fail dựa trên new_count và ENFORCE_GATE.

set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Cách dùng: $0 <tên> <key-hiện-tại> <key-baseline> <ngoại-lệ>" >&2
  exit 2
fi

name="$1"; current="$2"; baseline="$3"; exceptions="$4"
today=$(date -u +%F)
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# Chuẩn hóa: bỏ CR, bỏ dòng trống, sắp xếp, loại trùng. File không tồn tại = rỗng.
norm() {
  if [ -f "$1" ]; then
    tr -d '\r' < "$1" | sed '/^[[:space:]]*$/d' | sort -u
  fi
}

norm "${current}"  > "${work}/cur"
norm "${baseline}" > "${work}/base"

# Tách ngoại lệ còn hạn / đã hết hạn
: > "${work}/exc_active"
: > "${work}/exc_expired"
if [ -f "${exceptions}" ]; then
  tr -d '\r' < "${exceptions}" | awk -F';;' -v f_act="${work}/exc_active" -v f_exp="${work}/exc_expired" -v t="${today}" '
    /^[[:space:]]*#/ || NF < 2 { next }
    {
      k = $1; d = $2
      gsub(/^ +| +$/, "", k); gsub(/ /, "", d)
      if (d >= t) print k >> f_act; else print k >> f_exp
    }'
fi
sort -u -o "${work}/exc_active"  "${work}/exc_active"
sort -u -o "${work}/exc_expired" "${work}/exc_expired"

sort -u "${work}/base" "${work}/exc_active" > "${work}/allowed"

comm -23 "${work}/cur" "${work}/allowed" > "${work}/new"        # mới, chưa được chấp nhận
comm -12 "${work}/cur" "${work}/base"    > "${work}/existing"   # đã có ở baseline
comm -13 "${work}/cur" "${work}/base"    > "${work}/fixed"      # có ở baseline nhưng nay không còn
comm -12 "${work}/cur" "${work}/exc_expired" > "${work}/expired_hit"  # ngoại lệ đã hết hạn mà vẫn còn finding

n_cur=$(wc -l < "${work}/cur" | tr -d ' ')
n_new=$(wc -l < "${work}/new" | tr -d ' ')
n_existing=$(wc -l < "${work}/existing" | tr -d ' ')
n_fixed=$(wc -l < "${work}/fixed" | tr -d ' ')
n_expired=$(wc -l < "${work}/expired_hit" | tr -d ' ')

# Ngoại lệ hết hạn mà finding vẫn còn và không nằm trong baseline thì đã được tính vào "new".
report() {
  echo "### Quality gate (baseline): ${name}"
  echo ""
  echo "| Chỉ số | Số lượng |"
  echo "|---|---:|"
  echo "| Finding hiện tại | ${n_cur} |"
  echo "| Đã có ở baseline | ${n_existing} |"
  echo "| **Mới so với baseline (chưa có ngoại lệ)** | **${n_new}** |"
  echo "| Đã khắc phục so với baseline | ${n_fixed} |"
  echo "| Ngoại lệ đã hết hạn nhưng finding còn | ${n_expired} |"
  if [ "${n_new}" -gt 0 ]; then
    echo ""
    echo "Các finding mới (tối đa 50 dòng):"
    echo ""
    echo '```'
    head -n 50 "${work}/new"
    echo '```'
  fi
  if [ "${n_expired}" -gt 0 ]; then
    echo ""
    echo "Ngoại lệ hết hạn cần xem lại:"
    echo ""
    echo '```'
    head -n 50 "${work}/expired_hit"
    echo '```'
  fi
  echo ""
}

report
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then report >> "${GITHUB_STEP_SUMMARY}"; fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "new_count=${n_new}" >> "${GITHUB_OUTPUT}"
  echo "expired_count=${n_expired}" >> "${GITHUB_OUTPUT}"
fi
