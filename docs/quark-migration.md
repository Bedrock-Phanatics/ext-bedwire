# Moving Quark v6 onto ext-bedwire

Quark currently does networking, batching, compression, encryption, login checks, packet serialization and NBT in PHP:

- networking runs on worker threads: RakLib, and `axolotl-pm/nethernet` with ext-webrtc;
- batching, compression, encryption and login checks happen in `NetworkSession`;
- packet serialization lives in `axolotl-pm/bedrock-protocol`;
- NBT goes through `pocketmine/nbt`.

ext-bedwire replaces each of those with one native pipeline and keeps the PHP-facing pieces that gameplay and plugins use. This guide maps the current classes onto the extension and proposes an order to move them in.

## Mapping

| Quark today | With ext-bedwire |
| --- | --- |
| `RakLibInterface`, `RakLibServer`, raklib, raklib-ipc | Removed, since NetherNet is the only transport |
| `NetherNetInterface`, `NetherNetThread`, `NetherNetChannel`, `NetherNetIpc`, axolotl-pm/nethernet, ext-webrtc | `Bedwire\Server`, polled from the main thread. No PHP thread or IPC encoding |
| `NetworkSession::handleEncoded`: decryption, decompression, `PacketBatch::decodeRaw`, the 300-packet limit, rate limiters | Done natively. `EVENT_PACKET` delivers one decompressed game packet at a time, already checked against the session stage, size limits and `packet_rate` |
| `NetworkSession::sendDataPacket`, `addToSendBuffer`, `flushGamePacketQueue`, `PacketBatch::encodeRaw`, `Server::prepareBatch`, `CompressBatchTask`, `ZlibCompressor`, `SnappyCompressor` | `Server::sendPackets()` or `sendBatch()`. Packets queued for one session in the same tick are merged into one compressed frame on the network thread |
| `StandardPacketBroadcaster` (encode once, compress once) | Encode once with `Protocol::encode()`, then `sendBatch()` per recipient. Compression is per session on the network thread, off the main thread |
| `EncryptionContext`, `PrepareEncryptionTask`, `HandshakePacketHandler`, ext-crypto `Cipher` | Removed. NetherNet is already encrypted by DTLS, and vanilla does not add Bedrock encryption on top |
| `LoginPacketHandler`, `ProcessOpenIdLoginTask`, `AuthKeyProvider`, `FetchAuthKeysTask`, `JwtUtils::verify` | `EVENT_LOGIN` carries the verified name, UUID and XUID before the Login packet arrives. Client data in the Login packet can then be read without checking signatures again |
| `ProcessSelfSignedLoginTask` (offline mode) | Start the server with `"authentication" => false`, verify in PHP as today, then call `acceptLogin($session, $clientKeyDer)` |
| `NetworkSession::tick` login timeout | `login_timeout_ms` (disconnects with `REASON_TIMEOUT`) |
| `PacketPool::getPacket`, `DataPacket::decode`, `PacketSerializer`/`CommonTypes`, `ByteBufferReader`/`Writer` for packets | `Protocol::packetId()` to dispatch, then `Protocol::decode()`, which returns a field array |
| `DataPacket::encode`, `XxxPacket::create(...)` | `Protocol::encode('xxx', [...])` or `Server::sendPackets()` |
| `ProtocolInfo::*_PACKET`, `CURRENT_PROTOCOL`, `MINECRAFT_VERSION_NETWORK` | `Bedwire\PacketId::*`, `Protocol::VERSION`, `Protocol::MINECRAFT_VERSION` |
| `ClientboundPacket` / `ServerboundPacket` checks | `Protocol::direction()`. The native session also refuses packets the current stage or direction does not allow |
| `LittleEndianNbtSerializer`, `BigEndianNbtSerializer`, `NetworkNbtSerializer` | `Bedwire\Nbt::read/readAt/readHeadless/readMultiple/write/writeHeadless/writeMultiple` with `BEDROCK`, `JAVA` or `NETWORK`. They take and return the same `TreeRoot` and `Tag` objects |
| `CacheableNbt`, forwarding tile NBT unchanged | `Nbt::transcode()` converts encodings without building objects. `Nbt::length()` validates and measures |

## Keeping packet classes and plugins working

The 258 files under `src/` that use `pocketmine\network\mcpe\protocol` mostly build packets to send: sounds, particles, entities, and so on. Two paths are realistic.

1. **Thin adapter first.** Keep the packet classes as plain data holders. Their `decodePayload` and `encodePayload` become:

   ```php
   protected function decodePayload(ByteBufferReader $in): void {
       $this->fill(Protocol::decode($in->getData()));
   }
   ```

   Here `fill()` copies fields by name. Keep `encode` the same way, building the field array from the properties.

   With this, `PacketPool`, `DataPacketReceiveEvent`, `DataPacketSendEvent` and every `handleXxx` keep working, while serialization is native. This is the lowest-risk first step, but each packet still crosses the boundary twice: bytes to array, then array to properties.

2. **Arrays end to end.** Handlers and events take the field array directly:

   ```php
   handleText(array $packet)
   new DataPacketReceiveEvent($session, PacketId::TEXT, $fields)
   ```

   Plugins read and modify the same arrays and encoding happens once in `sendPackets()`. The generated [packet reference](packets.md) replaces the per-class docblocks. This removes the PHP protocol library entirely.

Field names follow protocol-zig and the protocol docs in snake_case, not BedrockProtocol's camelCase. A one-time map is needed for path 1; path 2 uses the new names directly.

`DataPacketDecodeEvent`, which lets plugins skip decoding, maps onto `Protocol::packetId()`: decide on the ID before calling `decode()`. Unhandled packets are then never decoded, which is what `PacketHandlerInspector` does today.

## Session lifecycle with the server

```text
EVENT_CONNECT    -> create the NetworkSession (no transport thread, no IPC)
request_network_settings packet
                 -> sendPackets: network_settings
                    (the native session negotiates compression from it)
EVENT_LOGIN      -> identity verified natively; fire PlayerIdentityVerifyEvent, check bans and duplicates
login packet     -> read client data (skin and so on) from connection_request
                 -> sendPackets: play_status(LOGIN_SUCCESS), resource_packs_info, ...
                    (play_status opens the resource pack stage)
resource pack responses, start_game, set_local_player_as_initialised
                 -> the stages advance natively
EVENT_DISCONNECT -> REASON_REMOTE, SERVER, PROTOCOL, OVERLOAD, SHUTDOWN, AUTHENTICATION or TIMEOUT
```

To refuse a player, send a `disconnect` packet and call `Server::disconnect()`. Queued packets are delivered before the connection closes.

## What can be deleted once migrated

- Transport:
  - `src/network/mcpe/raklib/*` and `src/network/mcpe/nethernet/*`;
  - the dependencies `pocketmine/raklib`, `pocketmine/raklib-ipc`, `axolotl-pm/nethernet`, `ext-webrtc`, `ext-sockets` (if unused elsewhere) and `ext-pmmpthread` (for networking).
- Login and encryption:
  - `src/network/mcpe/encryption/*`;
  - `ProcessLoginTask` and its variants, `AuthKeyProvider`, `FetchAuthKeysTask`, `JwtUtils` (keep it for offline mode only);
  - ext-crypto, if it is not used elsewhere.
- Compression: `src/network/mcpe/compression/*` and `CompressBatchTask`.
- Protocol: `axolotl-pm/bedrock-protocol`, after path 2. With path 1, keep its classes as data holders only.
- NBT: `pocketmine/nbt` serializers can delegate to `Bedwire\Nbt`. Keep the tag classes, since the extension builds those objects.

## Not covered yet

- Quark's `bedwire` transport (`src/network/mcpe/bedwire`) is the adapter. `zig build join` installs `bedwire-join`, an offline client that spawns in it end to end.
- Vanilla client interoperability, including native verification of Xbox logins, still needs a live test.
