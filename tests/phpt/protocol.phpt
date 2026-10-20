--TEST--
Packets are looked up, decoded, modified and encoded through protocol-zig
--EXTENSIONS--
bedwire
--FILE--
<?php
use Bedwire\{PacketId, Protocol, PacketException};

var_dump(Protocol::id("text") === PacketId::TEXT, Protocol::name(PacketId::TEXT), Protocol::name(1023));
var_dump(Protocol::direction("text") === Protocol::BIDIRECTIONAL, Protocol::direction(PacketId::RESOURCE_PACKS_READY_FOR_VALIDATION) === Protocol::SERVERBOUND);

$text = [
    "localize" => false,
    "body" => ["author_and_message" => ["message_type" => 1, "player_name" => "Steve", "message" => "hello"]],
    "senders_xuid" => "123",
    "platform_id" => "",
    "filtered_message" => null,
];
$bytes = Protocol::encode("text", $text, 1, 2);
var_dump(Protocol::header($bytes), Protocol::packetId($bytes) === PacketId::TEXT);
$decoded = Protocol::decode($bytes);
var_dump($decoded === $text);
$decoded["body"]["author_and_message"]["message"] = "edited";
unset($decoded["filtered_message"]);
var_dump(Protocol::decode(Protocol::encode(PacketId::TEXT, $decoded))["body"]["author_and_message"]["message"]);

$move = Protocol::decode(Protocol::encode("set_time", ["time" => -5]));
var_dump($move);
var_dump(Protocol::decode("\xff\x07"), Protocol::decode(chr(0x7f) . chr(0x07) . "x"));

function attempt(callable $call): void {
    try {
        $call();
        echo "ok\n";
    } catch (Throwable $e) {
        echo get_class($e), ": ", $e->getMessage(), "\n";
    }
}
attempt(fn() => Protocol::id("nope"));
attempt(fn() => Protocol::direction(9999));
attempt(fn() => Protocol::encode("text", $text, 4));
attempt(fn() => Protocol::encode("text", ["localize" => 1] + $text));
attempt(fn() => Protocol::encode("text", array_diff_key($text, ["platform_id" => 1])));
attempt(fn() => Protocol::encode("text", $text + ["extra" => 1]));
attempt(fn() => Protocol::encode("text", ["body" => ["shout" => []]] + $text));
attempt(fn() => Protocol::encode("text", ["body" => ["author_and_message" => ["message_type" => 1, "player_name" => "Steve", "message" => ""]]] + $text));
attempt(fn() => Protocol::encode("set_time", ["time" => PHP_INT_MAX]));
attempt(fn() => Protocol::decode(""));
attempt(fn() => Protocol::decode(Protocol::encode("set_time", ["time" => 1]) . "trailing"));
attempt(fn() => Protocol::decodeMany(["\x09", 5]));
attempt(fn() => Protocol::encodeMany([["text"]]));
?>
--EXPECT--
bool(true)
string(4) "text"
NULL
bool(true)
bool(true)
array(3) {
  [0]=>
  int(9)
  [1]=>
  int(1)
  [2]=>
  int(2)
}
bool(true)
bool(true)
string(6) "edited"
array(1) {
  ["time"]=>
  int(-5)
}
NULL
NULL
ValueError: Bedwire\Protocol::id(): Argument #1 ($name) must be a known packet name
ValueError: Bedwire\Protocol::direction(): Argument #1 ($packet) must be a known packet ID
ValueError: Bedwire\Protocol::encode(): Argument #3 ($senderSubClient) must be between 0 and 3
ValueError: Bedwire\Protocol::encode(): Argument #2 ($fields) localize must be of type bool, int given
ValueError: Bedwire\Protocol::encode(): Argument #2 ($fields) platform_id is missing
ValueError: Bedwire\Protocol::encode(): Argument #2 ($fields) extra is not a field
ValueError: Bedwire\Protocol::encode(): Argument #2 ($fields) body has an unknown variant
ValueError: Bedwire\Protocol::encode(): Argument #2 ($fields) violates a protocol bound of text
ValueError: Bedwire\Protocol::encode(): Argument #2 ($fields) time is out of range for i32
Bedwire\PacketException: malformed packet: EndOfStream
Bedwire\PacketException: malformed packet: TrailingData
Bedwire\PacketException: malformed packet: EndOfStream
TypeError: Bedwire\Protocol::encodeMany(): Argument #1 ($packets) must contain [packet, fields] pairs
