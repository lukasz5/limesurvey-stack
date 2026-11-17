<?php
// Container health probe: Apache + PHP up and the database reachable.
// Served only to 127.0.0.1 (see apache.conf).
define('BASEPATH', __DIR__);
header('Content-Type: text/plain');
header('Cache-Control: no-store');

try {
    $cfg = require '/var/lib/limesurvey/config.php';
    $db = $cfg['components']['db'];
    $pdo = new PDO($db['connectionString'], $db['username'], $db['password'], [
        PDO::ATTR_TIMEOUT => 3,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);
    $pdo->query('SELECT 1');
    echo "ok\n";
} catch (Throwable $e) {
    http_response_code(503);
    echo "unavailable\n";
}
