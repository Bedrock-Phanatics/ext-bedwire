--TEST--
Protocol bounds on fields clients send are enforced when encoding and decoding
--EXTENSIONS--
bedwire
--FILE--
<?php
use Bedwire\{PacketException, PacketId, Protocol};

function attempt(callable $fn): void{
    try{
        $fn();
        echo "ok\n";
    }catch(Throwable $e){
        echo get_class($e), ": ", $e->getMessage(), "\n";
    }
}

$emote = fn(string $id) => ["actor_runtime_id" => 1, "emote_id" => $id, "emote_length_ticks" => 20, "xuid" => "", "platform_id" => "", "flags" => 0];
$bytes = Protocol::encode(PacketId::EMOTE, $emote(str_repeat("a", 64)));
var_dump(Protocol::decode($bytes)["emote_id"] === str_repeat("a", 64));
attempt(fn() => Protocol::encode(PacketId::EMOTE, $emote(str_repeat("a", 65))));

//the emote ID follows the packet header and the actor ID, behind its varint length of 64
$tooLong = str_replace("\x40" . str_repeat("a", 64), "\x41" . str_repeat("a", 65), $bytes);
attempt(fn() => Protocol::decode($tooLong));
?>
--EXPECT--
bool(true)
ValueError: Bedwire\Protocol::encode(): Argument #2 ($fields) violates a protocol bound of emote
Bedwire\PacketException: malformed packet: InvalidValue
