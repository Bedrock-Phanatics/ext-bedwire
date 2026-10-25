--TEST--
Batches, sub-client IDs, the decode value limit and the schema
--EXTENSIONS--
bedwire
--FILE--
<?php
use Bedwire\{PacketId, Protocol, PacketException};

function attempt(callable $call): void {
    try {
        $call();
        echo "ok\n";
    } catch (Throwable $e) {
        echo get_class($e), ": ", $e->getMessage(), "\n";
    }
}

function split(string $batch): array {
    $packets = [];
    for ($offset = 0, $end = strlen($batch); $offset < $end;) {
        $length = 0;
        for ($shift = 0; ; $shift += 7) {
            $byte = ord($batch[$offset++]);
            $length |= ($byte & 0x7f) << $shift;
            if ($byte < 0x80) break;
        }
        $packets[] = substr($batch, $offset, $length);
        $offset += $length;
    }
    return $packets;
}

$time = Protocol::encode("set_time", ["time" => 7]);
$long = Protocol::encode("modal_form_request", ["form_id" => 1, "form_ui_json" => str_repeat("x", 300)]);
$batch = Protocol::encodeBatch([$time, [PacketId::SET_TIME, ["time" => 8]], ["text", [
    "localize" => false,
    "body" => ["message_only" => ["message_type" => 0, "message" => "hi"]],
    "senders_xuid" => "",
    "platform_id" => "",
], 1, 2], $long]);
$packets = split($batch);
var_dump(count($packets), $packets[0] === $time, $packets[3] === $long);
var_dump(Protocol::decode($packets[1]), Protocol::header($packets[2]));
var_dump(Protocol::encodeBatch([]) === "");
var_dump(Protocol::encodeMany([["set_time", ["time" => 1], 3]])[0] === Protocol::encode("set_time", ["time" => 1], 3));

attempt(fn() => Protocol::encodeBatch([""]));
attempt(fn() => Protocol::encodeBatch([5]));
attempt(fn() => Protocol::encodeBatch([["set_time", ["time" => 1], 4]]));
attempt(fn() => Protocol::encodeBatch([["set_time", ["time" => 1], "a"]]));
attempt(fn() => Protocol::encodeBatch([["set_time", ["time" => 1], 0, 0, 0]]));
attempt(fn() => Protocol::encodeBatch([["set_time", ["time" => "a"]]]));

$entries = [];
for ($i = 0; $i < 100; $i++) $entries[] = ["min_value" => 0.0, "max_value" => 1.0, "current_value" => 0.5, "default_min_value" => 0.0, "default_max_value" => 1.0, "default_value" => 0.5, "name" => "attribute$i", "modifiers" => []];
$attributes = Protocol::encode("update_attributes", ["target_runtime_id" => 1, "attribute_list" => $entries, "tick" => 0]);
var_dump(count(Protocol::decode($attributes)["attribute_list"]));
var_dump(count(Protocol::decode($attributes, 903)["attribute_list"]));
attempt(fn() => Protocol::decode($attributes, 902));
attempt(fn() => Protocol::decodeMany([$time, $attributes], 100));
attempt(fn() => Protocol::decode($attributes, -1));
var_dump(Protocol::decode($time, 1));

$schema = Protocol::schema();
var_dump($schema["protocol"] === Protocol::VERSION, $schema["minecraft"] === Protocol::MINECRAFT_VERSION);
var_dump(count($schema["packets"]) === count((new ReflectionClass(PacketId::class))->getConstants()));
var_dump($schema["packets"]["set_time"]);
var_dump($schema["types"]["Vec3f"]);
foreach ($schema["packets"] as $name => $packet) {
    if (Protocol::id($name) !== $packet["id"] || Protocol::direction($name) !== $packet["direction"]) echo "mismatch $name\n";
}
$unresolved = 0;
$check = function(mixed $type) use (&$check, $schema, &$unresolved): void {
    if (is_string($type)) {
        if (!in_array($type, ["bool", "int", "float", "string", "null"], true)) $unresolved++;
        return;
    }
    match ($type[0]) {
        "type" => isset($schema["types"][$type[1]]) || $unresolved++,
        "optional", "list" => $check($type[1]),
        "bytes", "bits" => null,
    };
};
foreach ($schema["packets"] as $packet) foreach ($packet["fields"] as $field) $check($field);
foreach ($schema["types"] as $type) foreach ($type["fields"] ?? $type["variants"] ?? [] as $field) $check($field);
var_dump($unresolved);
?>
--EXPECT--
int(4)
bool(true)
bool(true)
array(1) {
  ["time"]=>
  int(8)
}
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
ValueError: Bedwire\Protocol::encodeBatch(): Argument #1 ($packets) must not contain empty packets
TypeError: Bedwire\Protocol::encodeBatch(): Argument #1 ($packets) must contain [packet, fields] pairs
ValueError: Bedwire\Protocol::encodeBatch(): Argument #1 ($packets) must use sub-client IDs between 0 and 3
TypeError: Bedwire\Protocol::encodeBatch(): Argument #1 ($packets) must use int sub-client IDs
TypeError: Bedwire\Protocol::encodeBatch(): Argument #1 ($packets) must contain [packet, fields] pairs
ValueError: Bedwire\Protocol::encodeBatch(): Argument #1 ($packets) time must be of type int, string given
int(100)
int(100)
Bedwire\PacketException: malformed packet: TooManyValues
Bedwire\PacketException: malformed packet: TooManyValues
ValueError: Bedwire\Protocol::decode(): Argument #2 ($maxValues) must not be negative
array(1) {
  ["time"]=>
  int(7)
}
bool(true)
bool(true)
bool(true)
array(4) {
  ["id"]=>
  int(10)
  ["direction"]=>
  int(1)
  ["fields"]=>
  array(1) {
    ["time"]=>
    string(3) "int"
  }
  ["omittable"]=>
  array(0) {
  }
}
array(3) {
  ["kind"]=>
  string(6) "struct"
  ["fields"]=>
  array(3) {
    ["x"]=>
    string(5) "float"
    ["y"]=>
    string(5) "float"
    ["z"]=>
    string(5) "float"
  }
  ["omittable"]=>
  array(0) {
  }
}
int(0)
