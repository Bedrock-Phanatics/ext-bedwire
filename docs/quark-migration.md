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
| `LoginPacketHandler`, `ProcessOpenIdLoginTask`, `AuthKeyProvider`, `FetchAuthKeysTask`, `JwtUtils::verify` | `EVENT_LOGIN` carries the verified name, UUID, XUID and client key before the Login packet arrives. Client data in the Login packet can then be read without checking signatures again |
| `ProcessSelfSignedLoginTask` (offline mode) | Start the server with `"authentication" => false`, verify in PHP as today, then call `acceptLogin($session, $clientKeyDer)` |
| `NetworkSession::tick` login timeout | `login_timeout_ms` (disconnects with `REASON_TIMEOUT`) |
| `PacketPool::getPacket`, `DataPacket::decode`, `PacketSerializer`/`CommonTypes`, `ByteBufferReader`/`Writer` for packets | `Protocol::packetId()` to dispatch, then `Protocol::decode()`, which returns a field array |
| `DataPacket::encode`, `XxxPacket::create(...)` | `Protocol::encode('xxx', [...])` or `Server::sendPackets()` |
| `ProtocolInfo::*_PACKET`, `CURRENT_PROTOCOL`, `MINECRAFT_VERSION_NETWORK` | `Bedwire\PacketId::*`, `Protocol::VERSION`, `Protocol::MINECRAFT_VERSION` |
| `ClientboundPacket` / `ServerboundPacket` checks | `Protocol::direction()`. The native session also refuses packets the current stage or direction does not allow |
| `LittleEndianNbtSerializer`, `BigEndianNbtSerializer`, `NetworkNbtSerializer` | `Bedwire\Nbt::read/readAt/readHeadless/readMultiple/write/writeHeadless/writeMultiple` with `BEDROCK`, `JAVA` or `NETWORK`. They take and return the same `TreeRoot` and `Tag` objects |
| `CacheableNbt`, forwarding tile NBT unchanged | `Nbt::transcode()` converts encodings without building objects. `Nbt::length()` validates and measures |

## Packets in Quark

Quark uses field arrays end to end. BedrockProtocol is still a dependency for game constants and a few value objects (`ItemStack`, `SkinData`, `AbilitiesData`), but none of its packet classes encode or decode anything.

- `build/codegen/protocol-packets.php` reads `Protocol::schema()` and generates `Packets`: a PHPStan type alias for every packet and protocol type, a factory per packet, the serverbound handler map and `SCHEMA_HASH`. A unit test fails when the loaded extension's schema no longer matches the generated file.
- `quark\network\mcpe\protocol\Packet` wraps one packet. It keeps whichever form it has, fields or encoded bytes, and produces the other only when asked, so a received packet nobody reads is never decoded, and a packet broadcast to many sessions is encoded once.
- Handlers take the field array: `handleText(array $packet)`, typed with `@phpstan-param TextFields $packet`. `PacketHandlerInspector` maps them to packet IDs, and packets without a handler are dropped before decoding, as before.
- `DataPacketReceiveEvent` and `DataPacketSendEvent` carry `Packet` objects. A plugin that replaces received fields gets them re-encoded and decoded, so handlers only ever see values a client could have sent.
- Received packets decode with a value budget (`Protocol::decode($bytes, 65536)`), so a small packet cannot expand into a huge array. Collection limits from the schema are enforced by the decoder, and Quark's stricter ones (50 transaction actions, 80 item stack requests, 60 actions per request) by the handlers, before any part of the packet is applied.
- A session's queued packets are encoded together with one `Protocol::encodeBatch()` call when it flushes.
- `Fields` converts between field arrays and Quark's vectors, item stacks, skins and abilities. `EntityMetadata` replaces `EntityMetadataCollection` with the same API.

Field names follow protocol-zig and the protocol docs in snake_case, not BedrockProtocol's camelCase. The generated [packet reference](packets.md) lists them.

`DataPacketDecodeEvent`, which lets plugins skip decoding, runs on the packet ID before anything is decoded.

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
- Protocol: packet serialization in `axolotl-pm/bedrock-protocol` is no longer used. Its constants, item and skin value objects are, so the package stays until those have their own home.
- NBT: `pocketmine/nbt` serializers can delegate to `Bedwire\Nbt`. Keep the tag classes, since the extension builds those objects.

## Not covered yet

- Quark's `bedwire` transport (`src/network/mcpe/bedwire`) is the adapter. `zig build join` installs `bedwire-join`, an offline client that spawns in it end to end.
- Vanilla client interoperability, including native verification of Xbox logins, still needs a live test.
