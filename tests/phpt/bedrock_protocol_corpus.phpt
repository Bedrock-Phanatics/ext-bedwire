--TEST--
protocol-zig's corpus round trips through pmmp/BedrockProtocol, apart from known modelling differences
--EXTENSIONS--
bedwire
--SKIPIF--
<?php
$autoload = getenv("BEDROCK_PROTOCOL_AUTOLOAD");
if ($autoload === false || !is_file($autoload)) die("skip BEDROCK_PROTOCOL_AUTOLOAD is not set");
require $autoload;
if (!class_exists(pmmp\encoding\ByteBufferReader::class)) die("skip ext-encoding is not loaded");
?>
--FILE--
<?php
use pmmp\encoding\{ByteBufferReader, ByteBufferWriter};
use pocketmine\network\mcpe\protocol\{PacketPool, ProtocolInfo};

require getenv("BEDROCK_PROTOCOL_AUTOLOAD");

// Generated corpus values are often outside what BedrockProtocol accepts, and it normalises fields
// vanilla never sets, so only a changed list of differing packets needs a closer look.
$same = 0;
$other = [];
foreach (file(__DIR__ . '/../fixtures/corpus.txt', FILE_IGNORE_NEW_LINES) as $line) {
    if ($line === '' || $line[0] === '#') continue;
    [, $id, $hex] = explode(' ', $line);
    $bytes = hex2bin($hex);
    $packet = PacketPool::getInstance()->getPacket($bytes);
    if ($packet === null) {
        $other[] = "$id unknown";
        continue;
    }
    try {
        $reader = new ByteBufferReader($bytes);
        $packet->decode($reader);
        $writer = new ByteBufferWriter();
        $packet->encode($writer);
        $status = $reader->getUnreadLength() !== 0 ? "unread" : ($writer->getData() === $bytes ? null : "differs");
    } catch (Throwable) {
        $status = "rejected";
    }
    if ($status === null) $same++;
    else $other[] = "$id {$packet->getName()} $status";
}
var_dump(ProtocolInfo::CURRENT_PROTOCOL === Bedwire\Protocol::VERSION, $same);
echo implode("\n", array_unique($other)), "\n";
?>
--EXPECT--
bool(true)
int(287)
1 LoginPacket rejected
12 AddPlayerPacket differs
30 InventoryTransactionPacket rejected
39 SetActorDataPacket differs
52 CraftingDataPacket rejected
65 LegacyTelemetryEventPacket unread
67 ClientboundMapItemDataPacket rejected
82 ResourcePackDataInfoPacket rejected
90 StructureBlockUpdatePacket rejected
93 PlayerSkinPacket rejected
124 LevelEventGenericPacket rejected
133 StructureTemplateDataResponsePacket rejected
144 PlayerAuthInputPacket rejected
184 RequestAbilityPacket differs
185 RequestPermissionsPacket rejected
187 UpdateAbilitiesPacket rejected
315 ServerboundDiagnosticsPacket rejected
318 MovementEffectPacket rejected
322 ClientMovementPredictionSyncPacket differs
324 PlayerVideoCapturePacket rejected
328 PrimitiveShapesPacket rejected
336 ClientboundTextureShiftPacket rejected
342 PartyChangedPacket rejected
345 ClientboundAttributeLayerSyncPacket rejected
348 ClientboundUpdateSoundDataPacket differs
