# ext-bedwire

The native networking boundary between Quark and the Zig Bedrock stack. One PHP extension runs a dedicated network thread that owns the RakNet listener ([raknet-zig](https://github.com/Bedrock-Phanatics/raknet-zig)), the Bedrock sessions ([Bedwire](https://github.com/Bedrock-Phanatics/bedwire)) and their compression, encryption and batching. PHP only sends and receives encoded game packets. [nbt-zig](https://github.com/Bedrock-Phanatics/nbt-zig) backs a small NBT transcoder.

Gameplay, packet handling, players and plugins stay in PHP.

## Requirements

- Zig 0.17.0
- PHP 8.4 (ZTS or NTS) headers; Linux x86_64 is the primary target
- Dependencies are pinned in `build.zig.zon`: phpz, bedwire, raknet-zig and nbt-zig. protocol-zig comes only through Bedwire (`bedwire.protocol`), so one copy is compiled.

## Build

```sh
zig build -Doptimize=ReleaseFast -Dphp-include-dir="$(php-config --include-dir)"
# zig-out/modules/bedwire.so
```

| Step | What it runs |
| --- | --- |
| `zig build test` | Zig unit, integration and stress tests (no PHP needed) |
| `zig build phpt -Dphp=...` | PHPT tests against the built extension |
| `zig build bench` | Native queue and end-to-end benchmarks (`BEDWIRE_BENCH=ring\|paced\|saturated` selects one) |
| `zig build bench-php -Dphp=...` | PHP boundary benchmark with a client in another process |

Regenerate `bedwire_arginfo.h` with PHP's `build/gen_stub.php bedwire.stub.php` after editing the stub.

## Architecture

```
PHP thread                         network thread
Bedwire\Server ── command ring ──▶ raknet-zig listener
               ◀─── event ring ─── Bedwire sessions (batch, compress, encrypt)
```

- Both rings are bounded single-producer single-consumer byte queues. A command is copied out of Zend memory before the call returns; an event is copied into a PHP string when drained. The worker never touches Zend.
- The worker sleeps on the socket and the next RakNet deadline. Enqueuing a command while it sleeps sends a 16-byte token datagram to the listener, which the datagram filter consumes, so it wakes immediately without polling. Network progress is independent of Quark's tick.
- Session IDs are `generation << 16 | slot`, so a stale ID never reaches a reused slot.
- Bedwire's stage machine is driven from the traffic itself: NetworkSettings negotiates compression, ClientToServerHandshake, the finished resource pack response, StartGame and SetLocalPlayerAsInitialised advance the stage. Outbound packets the current stage forbids are dropped and counted.
- Space for every disconnect and tracked receipt is held back in the event ring, so they are never lost when it fills.

## Usage

```php
use Bedwire\Server;

$server = new Server("0.0.0.0", 19132, $motd, ["max_sessions" => 1000, "raw_prefixes" => ["\xfe\xfd"]]);

while ($running) {
    $events = $server->poll(4096, $msUntilNextTick);   // flat [kind, session, data, ...]
    for ($i = 0, $n = count($events); $i < $n; $i += 3) {
        [$kind, $session, $data] = [$events[$i], $events[$i + 1], $events[$i + 2]];
        match ($kind) {
            Server::EVENT_CONNECT => onConnect($session, ...$data),       // [ip, port, guid]
            Server::EVENT_PACKET => onPacket($session, $data),            // one encoded game packet
            Server::EVENT_DISCONNECT => onDisconnect($session, $data),    // Server::REASON_*
            Server::EVENT_RECEIPT_ACK, Server::EVENT_RECEIPT_FAILED => onReceipt($data),
            Server::EVENT_PING => onPing($session, $data),                // RTT in ms
            Server::EVENT_RAW => onRaw(...$data),                         // [ip, port, payload]
        };
    }
    $server->sendBatch($session, $encodedPackets);   // one frame, in order
}

// Login: after verifying the chain in PHP, hand over the handshake and the derived key.
$server->enableEncryption($session, $serverToClientHandshake, $key32);
// Without encryption, pass the verified client key instead.
$server->acceptLogin($session, $clientPublicKeyDer);

$server->stop(2000);
```

`send*` returns `false` for an unknown or closed session and throws `Bedwire\BackpressureException` when a bounded queue is full. Invalid arguments throw `ValueError`/`TypeError`; start failures throw `Bedwire\Exception`. A `Server` belongs to the thread that created it and is single-use; create a new one to listen again.

Options: `guid`, `max_sessions`, `encryption`, `max_batch_bytes`, `command_queue_bytes`, `event_queue_bytes`, `packet_rate` (per session, 0 disables), `handshake_rate` (per source IP; raise it behind a proxy), `ping_interval_ms`, `max_receipts`, `max_blocked`, `raw_prefixes`, `raw_rate`.

`Bedwire\Nbt::transcode($bytes, Nbt::BEDROCK, Nbt::NETWORK)` converts one root tag between the Java, Bedrock and network encodings without building PHP values.
