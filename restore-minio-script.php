<?php

/**
 * Copies objects MinIO wrote into the SeaweedFS gateway that replaced it.
 *
 * Both stores share one PersistentVolumeClaim; SeaweedFS keeps its data
 * under /data/seaweedfs so MinIO's files were never overwritten. But the
 * new S3 gateway only serves its own directory, so everything written
 * before the swap is on disk and unreachable through Storage::disk().
 *
 * MinIO's layout: an object key is a DIRECTORY containing xl.meta.
 * Objects under ~128 KB are inlined into xl.meta itself; larger ones keep
 * their bytes at <uuid>/part.1. Both are handled.
 *
 * Only writes keys that are currently absent, so it is safe to re-run.
 */

$sources = [
    ['/legacy/laravel-spa-uploads', 's3'],
    ['/legacy/laravel-spa-backups', 'backups'],
];

/**
 * Pulls the object's bytes out of a MinIO object directory.
 *
 * The inlined case cannot use a fixed offset: xl.meta's metadata varies
 * in length, so the payload is found by its own magic bytes and its own
 * self-declared length. RIFF/WEBP carries a little-endian size at byte 4
 * covering everything after the first 8, which is what makes an exact
 * extraction possible rather than a guess at where the file ends.
 */
function extractObject(string $dir): ?string
{
    // Large objects: the bytes sit in their own part file.
    foreach (glob($dir.'/*/part.1') ?: [] as $part) {
        $data = @file_get_contents($part);
        if ($data !== false && $data !== '') {
            return $data;
        }
    }

    $meta = @file_get_contents($dir.'/xl.meta');
    if ($meta === false) {
        return null;
    }

    // Inlined WEBP.
    $at = strpos($meta, 'RIFF');
    if ($at !== false && substr($meta, $at + 8, 4) === 'WEBP') {
        $size = unpack('V', substr($meta, $at + 4, 4))[1] ?? 0;
        if ($size > 0 && $at + 8 + $size <= strlen($meta)) {
            return substr($meta, $at, $size + 8);
        }
    }

    // Inlined gzip: no self-declared length, so take the tail. Safe
    // because gzip members carry their own end marker and trailing
    // bytes would be rejected by gunzip rather than silently accepted.
    $at = strpos($meta, "\x1f\x8b\x08");
    if ($at !== false) {
        return substr($meta, $at);
    }

    return null;
}

$totals = ['restored' => 0, 'skipped' => 0, 'failed' => 0, 'bytes' => 0];

foreach ($sources as [$root, $disk]) {
    if (! is_dir($root)) {
        printf("  %s: not present, skipping%s", $root, PHP_EOL);
        continue;
    }

    $store = Illuminate\Support\Facades\Storage::disk($disk);

    $walk = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::SELF_FIRST
    );

    foreach ($walk as $path => $info) {
        if (! $info->isDir() || ! is_file($path.'/xl.meta')) {
            continue;
        }

        $key = ltrim(substr($path, strlen($root)), '/');

        if ($store->exists($key)) {
            $totals['skipped']++;
            continue;
        }

        $data = extractObject($path);

        if ($data === null || $data === '') {
            $totals['failed']++;
            printf("  FAILED to extract: %s%s", $key, PHP_EOL);
            continue;
        }

        try {
            $store->put($key, $data);
            $totals['restored']++;
            $totals['bytes'] += strlen($data);
        } catch (Throwable $e) {
            $totals['failed']++;
            printf("  FAILED to upload %s: %s%s", $key, substr($e->getMessage(), 0, 120), PHP_EOL);
        }
    }
}

printf(
    "  restored %d  skipped %d (already present)  failed %d  (%.1f MB written)%s",
    $totals['restored'],
    $totals['skipped'],
    $totals['failed'],
    $totals['bytes'] / 1048576,
    PHP_EOL
);
