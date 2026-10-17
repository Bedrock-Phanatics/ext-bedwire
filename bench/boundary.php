<?php

declare(strict_types=1);

// PHP/native boundary costs with a real client in another process.
// Usage: php -d extension=bedwire.so bench/boundary.php <bedwire-bench-client>

use Bedwire\Server;

$clientBinary = $argv[1] ?? throw new RuntimeException("usage: boundary.php <bedwire-bench-client>");

function startClient(string $binary, int $port, array $args): array {
    $process = proc_open([$binary, (string) $port, ...$args], [1 => ["pipe", "w"]], $pipes);
    if ($process === false) {
        throw new RuntimeException("cannot start $binary");
    }
    $der = hex2bin(trim(fgets($pipes[1])));
    $replies = [];
    for ($i = 0; $i < 3; $i++) {
        $replies[] = hex2bin(trim(fgets($pipes[1])));
    }
    return [$process, $pipes[1], $der, $replies];
}

/** Answers the client's login like Quark would and returns its session ID. */
function login(Server $server, string $der, array $replies): int {
    $steps = 0;
    $session = 0;
    $deadline = microtime(true) + 10;
    while ($steps < 4 && microtime(true) < $deadline) {
        $events = $server->poll(64, 10);
        for ($i = 0, $n = count($events); $i < $n; $i += 3) {
            if ($events[$i] !== Server::EVENT_PACKET) {
                continue;
            }
            $session = $events[$i + 1];
            match ($steps++) {
                0 => $server->send($session, $replies[0]),
                1 => $server->acceptLogin($session, $der) && $server->send($session, $replies[1]),
                2 => $server->send($session, $replies[2]),
                default => null,
            };
        }
    }
    if ($steps < 4) {
        throw new RuntimeException("login timed out");
    }
    return $session;
}

function newServer(): Server {
    return new Server("127.0.0.1", 0, "MCPE;bench;2193;1.0;0;10;1;w;Survival;1;19132;19133;", [
        "encryption" => false,
        "packet_rate" => 0,
        "event_queue_bytes" => 64 * 1024 * 1024,
    ]);
}

function percentile(array $sorted, float $p): int {
    return $sorted ? $sorted[(int) ((count($sorted) - 1) * $p)] : 0;
}

// Inbound: drain events in one call per poll versus representation overheads.
foreach ([64, 1200] as $size) {
    $total = 200_000;
    $server = newServer();
    [$process, $out, $der, $replies] = startClient($clientBinary, $server->getPort(), ["inbound", (string) $total, (string) $size, "8"]);
    login($server, $der, $replies);

    $received = 0;
    $pollNs = 0;
    $untimed = 0;
    $nestedNs = 0;
    $latencies = [];
    $start = hrtime(true);
    while ($received < $total && hrtime(true) - $start < 30e9) {
        // Only non-blocking calls that returned events are timed.
        $before = hrtime(true);
        $events = $server->poll(4096, 0);
        if ($events) {
            $pollNs += hrtime(true) - $before;
        } else {
            $events = $server->poll(4096, 5);
            $untimed += count($events) / 3;
        }
        $n = count($events);

        // What a nested [kind, session, data] representation would add on top.
        $before = hrtime(true);
        $nested = [];
        for ($i = 0; $i < $n; $i += 3) {
            $nested[] = [$events[$i], $events[$i + 1], $events[$i + 2]];
        }
        $nestedNs += hrtime(true) - $before;
        unset($nested);

        $now = hrtime(true);
        for ($i = 0; $i < $n; $i += 3) {
            if ($events[$i] === Server::EVENT_PACKET) {
                $received++;
                if (($received & 63) === 0) {
                    $latencies[] = $now - unpack("P", $events[$i + 2], 2)[1];
                }
            }
        }
    }
    $elapsed = (hrtime(true) - $start) / 1e9;
    sort($latencies);
    printf(
        "inbound %4d B: %d packets in %.2f s (%.0f/s), poll %.0f ns/event, nested arrays +%.0f ns/event, latency p50 %d us p99 %d us\n",
        $size, $received, $elapsed, $received / $elapsed, $pollNs / max($received - $untimed, 1), $nestedNs / max($received, 1),
        percentile($latencies, 0.5) / 1000, percentile($latencies, 0.99) / 1000,
    );
    $server->stop(0);
    proc_terminate($process);
    proc_close($process);
}

// Outbound: send() per packet versus sendBatch() of 16.
foreach ([[1, 64], [16, 64], [1, 1200], [16, 1200]] as [$perCall, $size]) {
    $total = 64_000;
    $server = newServer();
    [$process, $out, $der, $replies] = startClient($clientBinary, $server->getPort(), ["outbound", (string) $total]);
    $session = login($server, $der, $replies);
    fgets($out);

    $callNs = 0;
    $calls = 0;
    $sent = 0;
    while ($sent < $total) {
        // Bursts of about 64 KiB, within RakNet's per-session queue, as a game tick would send.
        for ($bytes = 0; $bytes < 65536 && $sent < $total; $bytes += $perCall * $size) {
            $batch = [];
            for ($i = 0; $i < $perCall; $i++) {
                $batch[] = "\xfc\x07" . pack("P", hrtime(true)) . str_repeat("Z", $size - 10);
            }
            $before = hrtime(true);
            $perCall === 1 ? $server->send($session, $batch[0]) : $server->sendBatch($session, $batch);
            $callNs += hrtime(true) - $before;
            $calls++;
            $sent += $perCall;
        }
        $server->poll(4096, 0);
        usleep(2000);
    }
    $report = trim((string) fgets($out));
    printf("outbound %2d x %4d B per call: %.0f ns/call, %.0f ns/packet; client %s\n", $perCall, $size, $callNs / $calls, $callNs / $sent, $report);
    $server->stop(0);
    proc_close($process);
}
