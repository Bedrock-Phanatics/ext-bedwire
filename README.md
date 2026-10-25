# ext-bedwire

The native networking and protocol layer for Quark. It is a PHP extension built with [phpz](https://github.com/happystraw/phpz), and it provides three things:

- **Network:** a dedicated network thread runs the NetherNet transport ([nethernet-zig](https://github.com/Bedrock-Phanatics/nethernet-zig)). That covers HTTP signaling, LAN discovery and WebRTC data channels, and the thread also verifies logins. Sessions are handled by [Bedwire](https://github.com/Bedrock-Phanatics/bedwire): batching, compression, stage checks and rate limits.
- **Protocol:** every Bedrock packet is decoded and encoded by [protocol-zig](https://github.com/Bedrock-Phanatics/protocol-zig). PHP sees the packets as arrays.
- **NBT:** PocketMine's NBT tag trees are read and written by [nbt-zig](https://github.com/Bedrock-Phanatics/nbt-zig), one native call per document.

Gameplay, players, events and plugins stay in PHP. RakNet is not supported: NetherNet is the only transport.

## Requirements

- Zig 0.17.0.
- PHP 8.4 or later, ZTS or NTS. Tested on Linux x86_64 and on Windows x64 (built with phpz's MSVC cross build).
- The patched libdatachannel from nethernet-zig:
  - Build it with `tools/setup-native.sh` (Linux) or `tools/setup-native.ps1` (Windows).
  - Pass its install prefix with `-Dnative-prefix=...`, or set `NETHERNET_NATIVE_PREFIX`.
  - The extension links it as a shared library, so `libdatachannel.so` or `libdatachannel.dll` must be on the loader path at runtime.

All dependencies are pinned in `build.zig.zon`. protocol-zig comes only through Bedwire, and nbt-zig is shared with protocol-zig, so each library is compiled once.

## Build

```sh
zig build -Doptimize=ReleaseFast -Dnative-prefix="$PREFIX" -Dphp-include-dir="$(php-config --include-dir)"
# zig-out/modules/bedwire.so
```

| Step | What it does |
| --- | --- |
| `zig build test` | Zig unit, integration and stress tests over real NetherNet connections (no PHP needed) |
| `zig build phpt -Dphp=...` | PHPT tests against the built extension, including real NetherNet sessions |
| `zig build bench [-- codec session nbt ring transport]` | Native benchmarks |
| `zig build bench-php -Dphp=...` | PHP-side benchmarks. Set `POCKETMINE_VENDOR` to compare against pocketmine/nbt |
| `zig build docs` | Regenerates `docs/packets.md` and `stubs/bedwire_generated.php` from protocol-zig |

Other build options:

- `-Dlibdeflate=false` swaps libdeflate (the default) for std's deflate.
- `-Dlibc-file=...` is for cross builds.
- For Windows: `sh ../phpz/scripts/build-windows.sh --php-version 8.4.14 --zts -- -Dnative-prefix=...` produces `php_bedwire.dll`.

Regenerate `bedwire_arginfo.h` with `php gen_stub.php bedwire.stub.php` after editing the stub.

## Architecture

```
PHP thread                           network thread (one per Server)
Bedwire\Server ── command ring ──▶  NetherNet endpoint and LAN listeners
               ◀─── event ring ───   Bedwire sessions: framing, compression, stage checks,
                                     rate limits, login verification
Bedwire\Protocol, Bedwire\Nbt run on the calling PHP thread with no network involved.
```

**Queues and memory**
- Both rings are bounded single-producer, single-consumer byte queues.
- A command is copied out of Zend memory before the call returns. An event is copied into a PHP string when it is drained.
- The worker never touches Zend.

**Waking and scheduling**
- The worker waits on a single futex wakeup. Every connection, the listeners and PHP's command submissions signal it.
- There is no polling while idle: 50 connected players cost 0.00% of a core.
- Connections are pumped round robin, 64 messages per turn, so one flooding client cannot starve the others.

**Backpressure**
- When the event ring is low on space, the worker stops reading connections.
- NetherNet then pauses SCTP reads, so slow PHP ticks throttle the senders instead of dropping packets or growing memory.
- Space for every live session's disconnect event is always held back.
- A client that stops reading until its send buffer (`send_buffer_bytes`) fills is disconnected with `REASON_OVERLOAD`.

**Sessions**
- Session IDs are `generation << 16 | slot`, so a stale ID never reaches a reused slot.
- Bedwire drives the stage machine from the traffic itself. Packets the server's current stage forbids are dropped and counted.
- Vanilla NetherNet framing is used: no `0xfe` batch header, and no Bedrock encryption on top of DTLS.

**Authentication**
- With `authentication` on (the default), nethernet verifies each client's identity token at signaling against Microsoft's keys. Self-signed identities whose key is listed in `trusted_identity_keys` (your proxies) are accepted too.
- The worker then verifies Microsoft-signed Login tokens natively and reports a verified `EVENT_LOGIN` before the Login packet itself.
- Any other login (offline, proxy-signed, or one the native check rejects) still reaches PHP. PHP verifies it and calls `acceptLogin()`, and the session cannot leave the login stage before one of the two happens.

## Usage

```php
use Bedwire\{PacketId, Protocol, Server};

$server = new Server("0.0.0.0", 19132, [
    "max_sessions" => 500,
    "identity_file" => "server-identity.der", // keeps the server identity across restarts
    "lan_port" => 7551,                       // answer LAN discovery like a vanilla world
]);
$server->setStatus("My Server", "world", 500);

while ($running) {
    $events = $server->poll(4096, $msUntilNextTick);  // flat [kind, session, data, ...]
    for ($i = 0, $n = count($events); $i < $n; $i += 3) {
        [$kind, $session, $data] = [$events[$i], $events[$i + 1], $events[$i + 2]];
        match ($kind) {
            Server::EVENT_CONNECT => onConnect($session, ...$data),     // [ip:port, network ID, SHA-256 of the DER identity key or null, Microsoft-verified]
            Server::EVENT_LOGIN => onLogin($session, ...$data),         // [display name, UUID, XUID], already verified
            Server::EVENT_PACKET => onPacket($session, $data),          // one encoded game packet
            Server::EVENT_DISCONNECT => onDisconnect($session, $data),  // Server::REASON_*
            Server::EVENT_UNRELIABLE => onUnreliable($session, $data),  // a raw unreliable message, with "unreliable_events"
        };
    }
}

function onPacket(int $session, string $bytes): void {
    // Read only the header to dispatch, and decode the packets you handle.
    if (Protocol::packetId($bytes) === PacketId::TEXT) {
        $text = Protocol::decode($bytes);
        echo $text["body"]["author_and_message"]["message"] ?? "", "\n";
    }
}

// Encode and queue in one call. No intermediate PHP strings are created.
$server->sendPackets($session, [
    ["play_status", ["status" => 0]],
    ["text", ["localize" => false, "body" => ["message_only" => ["message_type" => 0, "message" => "hi"]], "senders_xuid" => "", "platform_id" => ""]],
]);
// Or send packets that are already encoded, as one batch.
$server->sendBatch($session, [$encodedA, $encodedB]);
// Or a batch body as Bedrock frames it (varint length + packet, repeated), compressed on the network thread.
$server->sendRawBatch($session, $batchBody, $offset = 0);
// Unreliable channel: one message, sent as it is.
$server->sendUnreliable($session, $payload);

$server->stop(2000);
```

### Results and errors

- `send*`, `disconnect` and `acceptLogin` return `false` for an unknown or closed session.
- When a bounded queue is full they throw `Bedwire\BackpressureException`.
- Invalid arguments throw `ValueError` or `TypeError`. Error messages name the failing field, e.g. `body.author_and_message.message must be of type string, int given`.
- A start failure throws `Bedwire\Exception`.
- A `Server` belongs to the thread that created it. Several servers may exist at once.

### Options

| Option | Default | |
| --- | --- | --- |
| `max_sessions` | 1024 | Concurrent sessions, up to 65535 |
| `authentication` | true | Verify identities at signaling and logins natively. Off means PHP calls `acceptLogin()` |
| `identity_file` | none | PKCS#8 server identity, created if missing |
| `lan_port` | 0 | UDP port for LAN discovery (7551 for vanilla). 0 disables it |
| `packet_rate` | 2000 | Packets per second per session (0 disables). Exceeding it disconnects with `REASON_OVERLOAD` |
| `login_timeout_ms` | 10000 | Time to finish logging in before `REASON_TIMEOUT` |
| `max_negotiations`, `http_workers` | 16 | Concurrent joins in negotiation, and HTTP signaling workers |
| `max_batch_bytes` | 4 MiB | Largest decompressed batch in either direction |
| `command_queue_bytes`, `event_queue_bytes` | 16 MiB | Ring sizes |
| `receive_queue_bytes` | 1 MiB | Per-connection receive buffering before SCTP reads pause |
| `send_buffer_bytes` | 16 MiB | Per-connection unsent data before the peer is disconnected |
| `port_range_begin`, `port_range_end` | any | UDP ports for WebRTC |
| `udp_mux` | false | Share one UDP socket across connections. Not verified against vanilla clients |
| `ice_servers` | none | STUN/TURN servers, e.g. `stun:stun.l.google.com:19302`, for servers behind NAT |
| `bind_address` | any | Local address WebRTC binds its UDP sockets to |
| `trusted_identity_keys` | none | DER public keys whose self-signed identities pass authenticated signaling (proxies) |
| `unreliable_events` | false | Deliver unreliable-channel messages as `EVENT_UNRELIABLE` instead of dropping them |
| `stats_interval_ms` | 1000 | Timer for statistics, login timeouts and the LAN advertisement |

`getStatistics()` returns sessions, traffic, packets, rejections, disconnects by cause, refused connections, receive pauses, event stalls and queue usage.

### Protocol

`Bedwire\Protocol` exposes protocol-zig's packets.

- **Lookup and metadata:** `id()`, `name()`, `direction()` (`CLIENTBOUND`, `SERVERBOUND` or `BIDIRECTIONAL`), `header()` and `packetId()`.
- **Codecs:**
  - `decode($bytes, $maxValues = 0)` returns the packet's fields, or `null` for an ID this protocol does not define. A nonzero `$maxValues` caps the array entries the packet may expand into, so untrusted input cannot turn a few megabytes into a huge array tree.
  - `encode($packet, $fields, $sender = 0, $target = 0)` takes a packet ID or name, and preserves sub-client IDs.
  - `decodeMany()` and `encodeMany()` do the same for whole lists in one call. `encodeMany()` takes `[packet, fields]` pairs, optionally followed by the sender and target sub-client IDs.
  - `encodeBatch()` takes the same pairs mixed with already encoded packets, and returns them as one batch body for `Server::sendRawBatch()`.
- **Schema:** `schema()` lists every packet with its ID, direction and fields, and every struct, union and enum they reach, under stable unique names. Code generators use it to build typed wrappers from the types the extension itself walks.
- **Constants:** `Protocol::VERSION` and `Protocol::MINECRAFT_VERSION`. `Bedwire\PacketId::<NAME>` has one constant per packet, registered at startup from protocol-zig.

The field layout of every packet is listed in [docs/packets.md](docs/packets.md), generated from the same types the extension uses. For IDEs, include [stubs/bedwire_generated.php](stubs/bedwire_generated.php).

How values are represented:

- Structs are arrays keyed by field name.
- A union is an array with exactly one key naming its variant.
- Lists are PHP lists, and enums are ints.
- Optional fields may be `null` or left out.
- NBT fields hold raw network NBT.
- Unsigned 64-bit values wrap into PHP's signed int.

Encoding validates every field and every protocol bound before writing, and writes straight into a PHP string of the exact size. Decoding validates the whole packet first and rejects trailing bytes. Malformed input throws `Bedwire\PacketException` and never crashes.

### NBT

`Bedwire\Nbt` reads and writes [pocketmine/nbt](https://github.com/pmmp/NBT) `TreeRoot` and `Tag` objects directly.

- **Formats:** `JAVA`, `BEDROCK` and `NETWORK`.
- **Calls:** `read`, `readAt` (also returns the end offset), `readHeadless`, `readHeadlessAt` (also returns the end offset), `readMultiple`, `write`, `writeHeadless`, `writeMultiple`, `transcode` (one encoding to another without building PHP objects), and `length` (validates and measures a document without building anything).
- **PocketMine semantics:**
  - Strings are raw bytes up to 32767 long.
  - For duplicate names, the first value wins.
  - `maxDepth` counts compounds and lists the way PocketMine does, except that one more empty compound is accepted at the limit. 0 means the 512-level maximum.
  - Fixed-width int arrays read back unsigned, matching PocketMine's `unpack` behaviour.
- **Stricter than PocketMine:** negative lengths, unknown element types in empty lists and overlong varints are refused, where PocketMine reads them as empty or truncated values. Minecraft never writes them.
- **Errors:** errors throw `Bedwire\NbtException`, and cyclic tag graphs are refused.

## Measurements

All numbers below were taken on WSL2 Ubuntu with a 12-thread host, ReleaseFast, PHP 8.4 NTS release build. Run them yourself with `zig build bench` and `zig build bench-php`.

### Native

| Workload | Result |
| --- | --- |
| Decode `move_player` | 46 ns |
| Decode + encode `move_player` | 136 ns |
| Decode `text` | 79 ns |
| Decode + encode a 16 KiB `level_chunk` | 371 ns |

Session batch, 17.5 KiB: 20 moves, 5 chat lines and 1 chunk.

| Backend | On the wire | Encode | Encode + decode |
| --- | --- | --- | --- |
| libdeflate (default) | 2721 B | 66 µs | 92 µs |
| std deflate | 2939 B | 116 µs | 150 µs |
| snappy | 3971 B | 13 µs | 23 µs |

NBT, a 2.6 KB chest block entity:

| Operation | Time |
| --- | --- |
| Validate (`length`) | 0.6 µs |
| Parse | 9.2 µs |
| Write | 4.5 µs |

The command/event ring moves 41 M records/s across threads.

### From PHP

| Call | Time |
| --- | --- |
| `Protocol::decode` `move_player` | 183 ns |
| `Protocol::encode` `move_player` | 228 ns |
| `Protocol::packetId` | 29 ns |

NBT, using the same pocketmine/nbt objects with byte-identical output:

| Operation | pocketmine/nbt in PHP | `Bedwire\Nbt` | Speed-up |
| --- | --- | --- | --- |
| Write | 75 µs | 9.9 µs | 7.5× |
| Read | 213 µs | 18 µs | 11.6× |

### End to end over NetherNet (loopback)

These runs echo one 64-byte packet per session at 20 Hz.

| Sessions | Echo round trip p50 / p99 | Worker CPU |
| --- | --- | --- |
| Native echo, 50 | 0.98 / 1.7 ms | 2.4% |
| Native echo, 200 | 1.3 / 2.6 ms | 9.6% |
| PHP echo server, 200 (load client in another process) | 2.2 / 4.1 ms | n/a |
| 50 logged in, idle | n/a | 0.00% |

In the PHP echo run, all 20,000 packets came back and there were no queue stalls.

These loopback measurements put both ends in one process, so the RSS figures from `zig build bench`, about 400 KiB per session pair, include the client side. No vanilla-client or WAN latency is claimed.

## Testing

- **Zig:** 37 tests, run on Linux and Windows, all over real WebRTC connections. They cover:
  - login, batching, compression and large-frame reassembly;
  - stale IDs, malformed and out-of-stage input, rate limits and backpressure;
  - login timeouts, graceful disconnects and shutdown;
  - LAN discovery and joins, overlapping servers, and connection churn.
- **PHPT:** 9 tests, run on PHP 8.4 NTS and ZTS (release, debug, and ASan/UBSan/LeakSanitizer builds) and on Windows ZTS. They cover:
  - every packet in protocol-zig's corpus, which must round-trip byte for byte through PHP;
  - NBT trees, arguments and lifecycle;
  - real NetherNet sessions through `Bedwire\Server`.

## Known limitations

- Native login verification uses the same Microsoft keys nethernet fetches at signaling. It is covered by Bedwire's own OIDC tests, but has not been exercised against a vanilla client here.
- On Windows, Zig 0.17 lets a second server bind the same signaling port. Linux refuses it.
- libdatachannel is a shared library, so it has to ship next to the extension.
