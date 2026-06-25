#!/usr/bin/env bash
# file: update-log.sh
# description: Automatically updates log.txt with new git commits and pushes the change

set -euo pipefail

# Chuyển đến thư mục chứa script để đảm bảo đường dẫn chính xác
cd "$(dirname "$0")"

LOG_FILE="log.txt"

if [[ ! -f "$LOG_FILE" ]]; then
    echo "[ERROR] Không tìm thấy tệp $LOG_FILE."
    exit 1
fi

TMP_FILE=$(mktemp)
CURRENT_DATE=$(date +%Y-%m-%d)

# 1. Tạo phần header mới
cat <<EOF > "$TMP_FILE"
# arlogkn Commit Log

Generated: $CURRENT_DATE

---
EOF

# 2. Đọc các hash commit đã tồn tại trong log.txt
declare -A EXISTING_HASHES
while IFS= read -r line; do
    # Bỏ qua các dòng trống hoặc không bắt đầu bằng ký tự hợp lệ
    [[ -z "$line" ]] && continue
    # Sử dụng awk/cut thay vì regex bash phức tạp để tương thích cao hơn
    hash=$(awk '{print $1}' <<< "$line")
    if [[ "$hash" =~ ^[0-9a-f]{7,}$ ]]; then
        EXISTING_HASHES["$hash"]=1
    fi
done < <(awk '/^---$/ {p=1; next} p {print}' "$LOG_FILE")

# 3. Quét lịch sử git và tìm các commit chưa có trong log
NEW_COMMITS=0
TMP_NEW_COMMITS=$(mktemp)

while IFS= read -r commit_line; do
    hash=$(awk '{print $1}' <<< "$commit_line")
    if [[ -n "$hash" && -z "${EXISTING_HASHES[$hash]:-}" ]]; then
        # Commit này chưa tồn tại trong log.txt
        echo "$commit_line" >> "$TMP_NEW_COMMITS"
        NEW_COMMITS=$((NEW_COMMITS + 1))
    fi
done < <(git log --format="%h %cs %s")

# 4. Kiểm tra nếu không có commit mới
if [[ "$NEW_COMMITS" -eq 0 ]]; then
    echo "[INFO] Không có commit mới nào. $LOG_FILE đã được cập nhật đầy đủ."
    rm -f "$TMP_FILE" "$TMP_NEW_COMMITS"
    exit 0
fi

# 5. Ghi các commit mới vào ngay dưới header
cat "$TMP_NEW_COMMITS" >> "$TMP_FILE"

# 6. Ghi lại các commit cũ (nội dung cũ từ sau dấu ---)
awk '/^---$/ {p=1; next} p {print}' "$LOG_FILE" >> "$TMP_FILE"

# 7. Cập nhật log.txt
mv "$TMP_FILE" "$LOG_FILE"
rm -f "$TMP_NEW_COMMITS"
echo "[INFO] Đã thêm $NEW_COMMITS commit mới vào $LOG_FILE."

# 8. Thực hiện commit và push tự động
git add "$LOG_FILE"

# Kiểm tra xem có thực sự có thay đổi nào được stage không (đề phòng)
if git diff --cached --quiet; then
    echo "[INFO] Không có thay đổi nào để commit."
    exit 0
fi

git commit -m "docs: update log.txt with latest commits"
echo "[INFO] Đang push lên remote..."
git push

echo "[SUCCESS] Hoàn tất cập nhật và push tự động!"
