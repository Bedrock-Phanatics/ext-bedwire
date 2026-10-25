--TEST--
Real NetherNet clients log in, exchange packets and disconnect through Bedwire\Server
--EXTENSIONS--
bedwire
--SKIPIF--
<?php
if (!is_executable(__DIR__ . '/../../zig-out/bin/bedwire-bench-client' . (PHP_OS_FAMILY === 'Windows' ? '.exe' : ''))) die("skip load client not built");
?>
--FILE--
<?php
use Bedwire\{PacketId, Protocol, Server};

$server = new Server("127.0.0.1", 0, ["authentication" => false, "max_sessions" => 8]);
$server->setStatus("phpt", "world", 8);
$client = proc_open([__DIR__ . '/../../zig-out/bin/bedwire-bench-client' . (PHP_OS_FAMILY === 'Windows' ? '.exe' : ''), (string) $server->getPort(), "3", "50", "1", "64"], [1 => ["pipe", "w"]], $pipes);

// Any valid P-384 key works here, since NetherNet sessions are not encrypted by Bedrock.
$der = base64_decode("MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEuyHwtjuGx8e2cPN6hfK87jCHrFlgU89VI5JZUTZJ9VafKjU1pVRe1nXHgvs6En0bB0uILy89E4KfWZRGPrvh06zfueS24YCWPaVk58qDzGXn6/hZTarLNEvuxI1ZatZY");
$connects = [];
$disconnects = [];
$steps = [];
$echoed = 0;
$deadline = microtime(true) + 30;
while ((count($disconnects) < 3 || count($connects) < 3) && microtime(true) < $deadline) {
    $events = $server->poll(1024, 10);
    for ($i = 0, $n = count($events); $i < $n; $i += 3) {
        [$kind, $session, $data] = [$events[$i], $events[$i + 1], $events[$i + 2]];
        if ($kind === Server::EVENT_CONNECT) {
            $connects[$session] = $data;
        } elseif ($kind === Server::EVENT_DISCONNECT) {
            $disconnects[$session] = $data;
        } elseif ($kind === Server::EVENT_PACKET) {
            if (Protocol::packetId($data) === PacketId::TEXT) {
                $server->send($session, $data);
                $echoed++;
                continue;
            }
            $step = $steps[$session] = ($steps[$session] ?? -1) + 1;
            match ($step) {
                0 => $server->sendPackets($session, [["network_settings", ["compression_threshold" => 256, "compression_algorithm" => 0, "client_throttle_enabled" => false, "client_throttle_threshold" => 0, "client_throttle_scalar" => 0.0]]]),
                1 => $server->acceptLogin($session, $der) && $server->sendPackets($session, [
                    ["play_status", ["status" => 0]],
                    ["resource_packs_info", ["resource_pack_required" => false, "has_addon_packs" => false, "has_scripts" => false, "force_disable_vibrant_visuals" => false, "world_template_id_and_version" => ["pack_uuid" => str_repeat("\0", 16), "pack_version" => ""], "resource_packs" => []]],
                    ["resource_pack_stack", ["texture_pack_required" => false, "texture_pack_list" => [], "base_game_version" => "", "experiments" => ["toggles" => [], "experiments_ever_toggled" => false], "include_editor_packs" => false]],
                ]),
                // StartGame only needs the player's unique and runtime IDs here.
                2 => $server->send($session, "\x0b\x02\x01") && $server->sendPackets($session, [["play_status", ["status" => 3]]]),
                default => null,
            };
        }
    }
}
$summary = json_decode(trim(stream_get_contents($pipes[1])), true);
proc_close($client);

var_dump(count($connects), count($disconnects));
foreach ($connects as $session => [$address, $networkId, $identity]) {
    var_dump(preg_match('/^[0-9a-f.:\[\]]+:\d+$/i', $address) === 1, preg_match("/^[0-9]+$/", $networkId) === 1, $identity);
    break;
}
var_dump(array_unique(array_values($disconnects)) === [Server::REASON_REMOTE]);
var_dump($summary["sent"] > 0, $summary["received"] === $summary["sent"], $echoed === $summary["sent"]);
$stats = $server->getStatistics();
var_dump($stats["sessions"], $stats["packets_received"] >= $echoed + 12, $stats["protocol_disconnects"]);
$server->stop(100);
?>
--EXPECT--
int(3)
int(3)
bool(true)
bool(true)
NULL
bool(true)
bool(true)
bool(true)
bool(true)
int(0)
bool(true)
int(0)
