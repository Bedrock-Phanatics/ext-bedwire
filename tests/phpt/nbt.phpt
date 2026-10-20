--TEST--
NBT transcoding and length scanning validate input and round trip between formats
--EXTENSIONS--
bedwire
--FILE--
<?php
use Bedwire\Nbt;

$disk = "\x0a\x00\x00" . "\x03\x01\x00a" . pack("V", 5) . "\x08\x01\x00s\x02\x00hi" . "\x00";
$network = Nbt::transcode($disk, Nbt::BEDROCK, Nbt::NETWORK);
echo bin2hex($network), "\n";
var_dump(Nbt::transcode($network, Nbt::NETWORK, Nbt::BEDROCK) === $disk);
$java = Nbt::transcode($disk, Nbt::BEDROCK, Nbt::JAVA);
echo bin2hex($java), "\n";
var_dump(Nbt::transcode($java, Nbt::JAVA, Nbt::BEDROCK) === $disk);

foreach (["", "\x0a", $disk . "\x00", "\x63\x00\x00"] as $bad) {
    try {
        Nbt::transcode($bad, Nbt::BEDROCK, Nbt::NETWORK);
        echo "accepted\n";
    } catch (Bedwire\NbtException $e) {
        echo "rejected\n";
    }
}

$deep = str_repeat("\x0a\x00\x00", 100) . str_repeat("\x00", 100);
try {
    Nbt::transcode($deep, Nbt::BEDROCK, Nbt::NETWORK, 16);
} catch (Bedwire\NbtException $e) {
    echo "too deep\n";
}
var_dump(strlen(Nbt::transcode($deep, Nbt::BEDROCK, Nbt::NETWORK, 128)) > 0);
var_dump(strlen(Nbt::transcode($deep, Nbt::BEDROCK, Nbt::NETWORK)) > 0);

var_dump(Nbt::length($disk . "trailing", Nbt::BEDROCK) === strlen($disk));
var_dump(Nbt::length("xx" . $network, Nbt::NETWORK, 2) === strlen($network));
try {
    Nbt::length(substr($disk, 0, -1), Nbt::BEDROCK);
} catch (Bedwire\NbtException $e) {
    echo $e->getMessage(), "\n";
}

foreach ([fn() => Nbt::transcode($disk, 9, 1), fn() => Nbt::transcode($disk, 1, 1, -1), fn() => Nbt::length($disk, 1, 99)] as $call) {
    try {
        $call();
    } catch (ValueError $e) {
        echo $e->getMessage(), "\n";
    }
}
?>
--EXPECT--
0a000301610a08017302686900
bool(true)
0a00000300016100000005080001730002686900
bool(true)
rejected
rejected
rejected
rejected
too deep
bool(true)
bool(true)
bool(true)
bool(true)
invalid NBT: UnexpectedEndOfInput
Bedwire\Nbt::transcode(): Argument #2 ($from) must be a Bedwire\Nbt format
Bedwire\Nbt::transcode(): Argument #4 ($maxDepth) must not be negative
Bedwire\Nbt::length(): Argument #3 ($offset) is past the end of the data
