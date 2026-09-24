<?php
/**
 * Small database helpers for setup.sh (PDO: the image has pdo_mysql only).
 *
 *   php db.php installed          # prints 1 if Magento's tables exist
 *   php db.php get <path>         # prints a default-scope value of core_config_data
 *   php db.php set <path> <value> # sets it (for the stack's own markers)
 *
 * Errors go to stderr with a non-zero exit code, never to stdout.
 */

ini_set('display_errors', 'stderr');

try {
    $pdo = new PDO(
        sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4', getenv('DB_HOST'), (int) getenv('DB_PORT'), getenv('DB_NAME')),
        (string) getenv('DB_USER'),
        (string) getenv('DB_PASSWORD'),
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
    );

    switch ($argv[1] ?? '') {
        case 'installed':
            echo $pdo->query("SHOW TABLES LIKE 'core_config_data'")->fetchColumn() ? '1' : '';
            break;
        case 'get':
            $stmt = $pdo->prepare("SELECT value FROM core_config_data WHERE scope = 'default' AND scope_id = 0 AND path = ?");
            $stmt->execute([$argv[2]]);
            echo (string) $stmt->fetchColumn();
            break;
        case 'set':
            $stmt = $pdo->prepare(
                "INSERT INTO core_config_data (scope, scope_id, path, value) VALUES ('default', 0, ?, ?)
                 ON DUPLICATE KEY UPDATE value = VALUES(value)"
            );
            $stmt->execute([$argv[2], $argv[3]]);
            break;
        default:
            fwrite(STDERR, "Usage: db.php installed | get <path> | set <path> <value>\n");
            exit(2);
    }
} catch (Throwable $e) {
    fwrite(STDERR, 'db.php: ' . $e->getMessage() . "\n");
    exit(1);
}
