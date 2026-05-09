#!/bin/bash
# Shared helpers for backup_full.sh and backup_incremental.sh.
# Source this file; do not execute it directly.

# Run pg_dumpall inside the Immich postgres container.
dump_postgres() {
    local out=$1
    docker exec -t "$PG_CONTAINER" pg_dumpall -U "$PG_USER" > "$out"
}

# Stream the tar through dd-based 100 GB chunking, uploading each chunk
# in parallel (max $PARALLEL concurrent). Echoes the number of parts.
#
# Note: the writer emits TWO concatenated tar archives:
#   1) media (full or only-newer-than-marker subset)
#   2) db dump + config files
# Restore must use `tar -i` to read past the inter-archive zero blocks.
# We don't use --listed-incremental because it forbids multiple -C options,
# which we need to mix media + db dump + compose files in a single archive.
#
# Args:
#   $1 backup_type   "full" | "incremental"
#   $2 date          timestamp like 20260101T030000Z
#   $3 marker        path to the timestamp marker file (used only for incremental)
stream_tar_split_upload() {
    local backup_type=$1
    local date=$2
    local marker=$3
    local prefix="${backup_type}/${date}"

    local pipe="$BACKUP_TMPDIR/tar_pipe.$$"
    [[ -e "$pipe" ]] && rm -f "$pipe"
    mkfifo "$pipe"

    # Background tar writer. Exits non-zero will surface via wait below.
    (
        # ---- 1) media ----
        if [[ "$backup_type" == "full" ]]; then
            tar -cf - \
                --exclude='./thumbs' \
                --exclude='./encoded-video' \
                --exclude='./backups' \
                --exclude='./.backup_tmp' \
                --exclude='./.backup_state' \
                -C "$UPLOAD_LOCATION" .
        else
            (
                cd "$UPLOAD_LOCATION"
                find . -newer "$marker" \
                    -not -path './thumbs' -not -path './thumbs/*' \
                    -not -path './encoded-video' -not -path './encoded-video/*' \
                    -not -path './backups' -not -path './backups/*' \
                    -not -path './.backup_tmp' -not -path './.backup_tmp/*' \
                    -not -path './.backup_state' -not -path './.backup_state/*' \
                    -print0 \
                | tar --null --files-from=- --no-recursion -cf -
            )
        fi

        # ---- 2) db dump + config (always full) ----
        tar -cf - \
            -C "$BACKUP_TMPDIR" "db_${date}.sql" \
            -C "$COMPOSE_DIR" docker-compose.yml .env
    ) > "$pipe" &
    local tar_pid=$!

    # CRITICAL: keep an extra reader on the FIFO open in this shell so the
    # writer (tar) doesn't get SIGPIPE between dd invocations. Without this
    # holder fd, when a dd finishes its 100 GiB read and exits, the read-side
    # refcount briefly drops to zero; tar's next write then triggers SIGPIPE
    # and tar dies, silently truncating the archive. We saw this in practice:
    # 387 GB of media became a 100 GiB part_000 + 67 MB part_001 (only the
    # second tar's db+compose output got through after the first tar died).
    exec 3< "$pipe"

    local i=0
    local total_size=0
    while :; do
        local part="$BACKUP_TMPDIR/part_$(printf '%03d' "$i")"

        # Read from the held-open fd 3 (not by re-opening the FIFO each time).
        # iflag=fullblock prevents short reads from a FIFO.
        dd of="$part" bs=1M count="$CHUNK_SIZE_MB" \
            iflag=fullblock 2>/dev/null <&3 || true

        if [[ ! -s "$part" ]]; then
            rm -f "$part"
            break
        fi

        total_size=$((total_size + $(stat -c%s "$part")))

        # Wait for an upload slot before launching the next.
        while (( $(jobs -rp | wc -l) >= PARALLEL )); do
            wait -n
        done

        (
            aws s3 cp "$part" "s3://${S3_BUCKET}/${prefix}/$(basename "$part")" \
                --storage-class DEEP_ARCHIVE \
                --checksum-algorithm SHA256 \
                --no-progress \
                --metadata "backup-type=${backup_type},backup-date=${date}" \
                --profile "$AWS_PROFILE" \
            && rm -f "$part"
        ) &

        i=$((i + 1))
    done

    # Close the holder fd before final wait. Now any pending writer can finish
    # cleanly with EOF semantics.
    exec 3<&-

    wait "$tar_pid"
    wait

    rm -f "$pipe"

    local manifest
    manifest=$(printf '{"type":"%s","date":"%s","parts":%d,"total_size_bytes":%d}\n' \
        "$backup_type" "$date" "$i" "$total_size")
    printf '%s' "$manifest" | aws s3 cp - "s3://${S3_BUCKET}/${prefix}/manifest.json" \
        --storage-class STANDARD \
        --profile "$AWS_PROFILE"

    echo "$i"
}

# Forward a status line to Slack.
notify() {
    "$SCRIPT_DIR/notify_slack.sh" "$@"
}
