#!/bin/bash

# --- Configuration ---
TARGET="/"
EXCLUDES=("/mnt" "/usr/lib/wsl")
THRESHOLD_MB=${1:-128}

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
NC='\033[0m'

# Cleanup: Remove temp folder on script exit
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"; exit' INT TERM EXIT

# Prepare exclude arguments
exclude_args=()
for ex in "${EXCLUDES[@]}"; do exclude_args+=("--exclude=$ex"); done

# Native formatting function
format_size() {
    local size_kb=$1
    if [ "$size_kb" -ge 1048576 ]; then
        local gb=$((size_kb / 1048576))
        local dec=$(((size_kb % 1048576) / 104857))
        printf "${RED}%4d.%1dG${NC}" "$gb" "$dec"
    elif [ "$size_kb" -ge 1024 ]; then
        local mb=$((size_kb / 1024))
        printf "%6dM" "$mb"
    else
        printf "%6dK" "$size_kb"
    fi
}

# Recursive function: Visual with depth control
scan_layer() {
    local dir=$1
    local depth=$2
    local max_depth=3
    local threshold_kb=$((THRESHOLD_MB * 1024))

    local items
    items=$(du -k --max-depth=1 "$dir" "${exclude_args[@]}" 2>/dev/null | \
            awk -v limit=$threshold_kb '$2 != "'"$dir"'" && $1 >= limit {print $1 "\t" $2}' | \
            sort -rn)

    if [[ -n "$items" ]]; then
        local count=0
        local total=$(echo "$items" | wc -l)
        while IFS=$'\t' read -r size path; do
            count=$((count + 1))
            local prefix=""
            for ((i=1; i<depth; i++)); do prefix="$prefix    "; done
            [ "$count" -eq "$total" ] && prefix="$prefix${GRAY}└── ${NC}" || prefix="$prefix${GRAY}├── ${NC}"

            echo -e "$(format_size "$size")  $prefix$path"
            if (( depth < max_depth - 1 )); then
                scan_layer "$path" $((depth + 1))
            fi
        done <<< "$items"
    fi
}

echo -e "${YELLOW}>>> Scanning with parallel threads (threshold: >${THRESHOLD_MB}MB) <<<${NC}"

# 1. Find top-level directories
top_levels=$(du -k --max-depth=1 "$TARGET" "${exclude_args[@]}" 2>/dev/null | \
             awk -v limit=$((THRESHOLD_MB * 1024)) '$2 != "/" && $2 != "" && $1 >= limit {print $1 "\t" $2}' | \
             sort -rn)

# 2. Parallel distribution
while IFS=$'\t' read -r size path; do
    (
        # Use hash for safer filename mapping
        safe_name=$(echo "$path" | md5sum | cut -d' ' -f1)
        out_file="$tmp_dir/$safe_name"

        echo -e "$(format_size "$size")  $path" > "$out_file"
        scan_layer "$path" 1 >> "$out_file"
    ) &
done <<< "$top_levels"

wait

# 3. Merge output by weight order
echo "------------------------------------------------"
while IFS=$'\t' read -r size path; do
    safe_name=$(echo "$path" | md5sum | cut -d' ' -f1)
    if [ -f "$tmp_dir/$safe_name" ]; then
        cat "$tmp_dir/$safe_name"
    fi
done <<< "$top_levels"
echo "------------------------------------------------"
