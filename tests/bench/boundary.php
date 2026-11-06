<?php

declare(strict_types=1);

// PHP-side costs of the extension: NBT and an end-to-end echo server.
// Usage: php -d extension=bedwire.so boundary.php <load client> [pocketmine vendor dir]

use Bedwire\{Nbt, Server};

const TEXT = 9;

$client = $argv[1] ?? null;
$vendor = $argv[2] ?? getenv('POCKETMINE_VENDOR') ?: null;

function bench(string $name, callable $body, float $seconds = 0.3): void
{
    for ($i = 0; $i < 1000; $i++) {
        $body();
    }
    $ops = 0;
    $start = hrtime(true);
    do {
        for ($i = 0; $i < 256; $i++) {
            $body();
        }
        $ops += 256;
        $elapsed = hrtime(true) - $start;
    } while ($elapsed < $seconds * 1e9);
    printf("%-52s %10.1f ns/op %10.2f M ops/s\n", $name, $elapsed / $ops, $ops / ($elapsed / 1e9) / 1e6);
}

if ($vendor !== null && is_dir($vendor)) {
    spl_autoload_register(function (string $class) use ($vendor): void {
        foreach (["pocketmine\\nbt\\" => "pocketmine/nbt/src/", "pocketmine\\utils\\" => "pocketmine/binaryutils/src/"] as $prefix => $dir) {
            if (str_starts_with($class, $prefix)) {
                $file = $vendor . "/" . $dir . str_replace("\\", "/", substr($class, strlen($prefix))) . ".php";
                if (is_file($file)) {
                    require $file;
                }
            }
        }
    });
    echo "\n== NBT: pocketmine/nbt in PHP against Bedwire\\Nbt, same tag objects ==\n";
    $root = new pocketmine\nbt\tag\CompoundTag();
    $root->setString("id", "Chest")->setInt("x", 100)->setInt("y", 64)->setInt("z", -20);
    $items = [];
    for ($i = 0; $i < 27; $i++) {
        $items[] = (new pocketmine\nbt\tag\CompoundTag())
            ->setString("Name", "minecraft:diamond_sword")->setByte("Count", 1)->setByte("Slot", $i)->setShort("Damage", 0)
            ->setTag("tag", (new pocketmine\nbt\tag\CompoundTag())->setByte("Unbreakable", 1)->setTag("display", new pocketmine\nbt\tag\CompoundTag()));
    }
    $root->setTag("Items", new pocketmine\nbt\tag\ListTag($items));
    $tree = new pocketmine\nbt\TreeRoot($root);
    $serializer = new pocketmine\nbt\LittleEndianNbtSerializer();
    $php = $serializer->write($tree);
    $native = Nbt::write($tree, Nbt::BEDROCK);
    printf("identical output: %s, %d bytes\n", $php === $native ? "yes" : "NO", strlen($native));
    bench("pocketmine LittleEndianNbtSerializer::write", fn() => $serializer->write($tree));
    bench("Bedwire\\Nbt::write", fn() => Nbt::write($tree, Nbt::BEDROCK));
    bench("pocketmine LittleEndianNbtSerializer::read", fn() => $serializer->read($php));
    bench("Bedwire\\Nbt::read", fn() => Nbt::read($native, Nbt::BEDROCK));
    bench("Bedwire\\Nbt::length (validate only)", fn() => Nbt::length($native, Nbt::BEDROCK));
}

if ($client === null) {
    exit(0);
}

echo "\n== end to end: PHP echo server, load client in another process ==\n";
foreach ([[1, 20], [50, 20], [200, 20]] as [$sessions, $rate]) {
    $server = new Server("127.0.0.1", 0, ["protocol_version" => 2225, "minecraft_version" => "1.26.60", "authentication" => false, "max_sessions" => $sessions + 8, "packet_rate" => 0, "max_negotiations" => 64, "http_workers" => 64, "login_timeout_ms" => 60000]);
    $process = proc_open([$client, (string) $server->getPort(), (string) $sessions, (string) $rate, "5", "64"], [1 => ["pipe", "w"]], $pipes);
    $steps = [];
    // NetworkSettings, PlayStatus success and an empty 1.26.60 pack offer, written by hand.
    $settings = "\x8f\x01" . pack("vvCCg", 256, 0, 0, 0, 0.0);
    $status = "\x02" . pack("N", 0);
    $packs = "\x06" . str_repeat("\0", 22);
    $stack = "\x07" . str_repeat("\0", 9);
    // StartGame's unique and runtime IDs, then PlayStatus spawn.
    $start = ["\x0b\x02\x01", "\x02" . pack("N", 3)];
    // Any valid P-384 key works here, since NetherNet sessions are not encrypted by Bedrock.
    $der = base64_decode("MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEuyHwtjuGx8e2cPN6hfK87jCHrFlgU89VI5JZUTZJ9VafKjU1pVRe1nXHgvs6En0bB0uILy89E4KfWZRGPrvh06zfueS24YCWPaVk58qDzGXn6/hZTarLNEvuxI1ZatZY");
    $echoed = 0;
    $usage = getrusage();
    $cpuStart = $usage["ru_utime.tv_sec"] * 1e6 + $usage["ru_utime.tv_usec"] + $usage["ru_stime.tv_sec"] * 1e6 + $usage["ru_stime.tv_usec"];
    $wallStart = hrtime(true);
    while (proc_get_status($process)["running"]) {
        $events = $server->poll(4096, 5);
        for ($i = 0, $n = count($events); $i < $n; $i += 3) {
            if ($events[$i] !== Server::EVENT_PACKET) {
                continue;
            }
            $session = $events[$i + 1];
            $bytes = $events[$i + 2];
            $id = ord($bytes[0]);
            if ($id === TEXT) {
                $server->send($session, $bytes);
                $echoed++;
                continue;
            }
            $step = $steps[$session] = ($steps[$session] ?? -1) + 1;
            match ($step) {
                0 => $server->send($session, $settings),
                1 => $server->acceptLogin($session, $der) && $server->sendBatch($session, [$status, $packs, $stack]),
                2 => $server->sendBatch($session, $start),
                default => null,
            };
        }
    }
    $usage = getrusage();
    $cpu = $usage["ru_utime.tv_sec"] * 1e6 + $usage["ru_utime.tv_usec"] + $usage["ru_stime.tv_sec"] * 1e6 + $usage["ru_stime.tv_usec"] - $cpuStart;
    $wall = (hrtime(true) - $wallStart) / 1e3;
    $summary = trim(stream_get_contents($pipes[1]));
    proc_close($process);
    $stats = $server->getStatistics();
    $server->stop(500);
    printf("%d sessions at %d Hz: echoed %d, process CPU %.1f%% of one core (PHP, worker and WebRTC threads, joins included), client %s, worker stalls %d\n", $sessions, $rate, $echoed, 100 * $cpu / $wall, $summary, $stats["event_stalls"]);
}
