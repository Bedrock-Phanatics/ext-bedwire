--TEST--
Every packet in protocol-zig's corpus decodes to PHP and encodes back to identical bytes
--EXTENSIONS--
bedwire
--FILE--
<?php
use Bedwire\Protocol;

$kinds = [];
$failures = 0;
$lines = 0;
foreach (file(__DIR__ . '/../fixtures/corpus.txt', FILE_IGNORE_NEW_LINES) as $line) {
    if ($line === '' || $line[0] === '#') {
        continue;
    }
    [$sender, $id, $hex] = explode(' ', $line);
    $bytes = hex2bin($hex);
    $lines++;
    $kinds[(int) $id] = true;
    $fields = Protocol::decode($bytes);
    [$headerId, $from, $to] = Protocol::header($bytes);
    $direction = Protocol::direction((int) $id);
    $allowed = $sender === 'client' ? Protocol::SERVERBOUND : Protocol::CLIENTBOUND;
    if ($fields === null || $headerId !== (int) $id || ($direction & $allowed) === 0) {
        echo "decode failed for $id\n";
        $failures++;
        continue;
    }
    $again = Protocol::encode((int) $id, $fields, $from, $to);
    $byName = Protocol::encode(Protocol::name((int) $id), $fields, $from, $to);
    if ($again !== $bytes || $byName !== $bytes) {
        echo "round trip mismatch for $id\n";
        $failures++;
    }
}
$all = array_values(array_filter(array_map(fn($line) => $line !== '' && $line[0] !== '#' ? hex2bin(explode(' ', $line)[2]) : null, file(__DIR__ . '/../fixtures/corpus.txt', FILE_IGNORE_NEW_LINES))));
$decoded = Protocol::decodeMany($all);
$encoded = Protocol::encodeMany(array_map(fn($bytes, $fields) => [Protocol::packetId($bytes), $fields], $all, $decoded));
var_dump($encoded === $all);
var_dump($failures, count($kinds) === count((new ReflectionClass('Bedwire\PacketId'))->getConstants()), $lines > 300);
?>
--EXPECT--
bool(true)
int(0)
bool(true)
bool(true)
