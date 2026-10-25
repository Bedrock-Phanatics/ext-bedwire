--TEST--
NBT documents are read into and written from pocketmine/nbt tag trees in one call
--EXTENSIONS--
bedwire
--FILE--
<?php
require __DIR__ . '/pocketmine_nbt.inc';

use Bedwire\Nbt;
use pocketmine\nbt\TreeRoot;
use pocketmine\nbt\tag\{ByteArrayTag, ByteTag, CompoundTag, DoubleTag, FloatTag, IntArrayTag, IntTag, ListTag, LongTag, ShortTag, StringTag};

$items = new ListTag([new IntTag(1), new IntTag(-2)], 3);
$root = (new CompoundTag())
    ->setTag("byte", new ByteTag(-5))
    ->setTag("short", new ShortTag(300))
    ->setTag("long", new LongTag(PHP_INT_MIN))
    ->setTag("float", new FloatTag(1.5))
    ->setTag("double", new DoubleTag(-0.25))
    ->setTag("string", new StringTag("h\xffi"))
    ->setTag("bytes", new ByteArrayTag("\x00\x01"))
    ->setTag("ints", new IntArrayTag([1, -1]))
    ->setTag("list", $items)
    ->setTag("empty", new ListTag())
    ->setTag("123", (new CompoundTag())->setTag("inner", new IntTag(7)));

foreach ([Nbt::JAVA, Nbt::BEDROCK, Nbt::NETWORK] as $format) {
    $bytes = Nbt::write(new TreeRoot($root, "level"), $format);
    $back = Nbt::read($bytes, $format);
    var_dump($back->getName(), Nbt::write($back, $format) === $bytes);
    $tag = $back->getTag();
    $values = $tag->getValue();
    echo implode(",", array_keys($values)), "\n";
    var_dump($values["byte"]->getValue(), $values["long"]->getValue() === PHP_INT_MIN, $values["string"]->getValue() === "h\xffi");
    var_dump($values["ints"]->getValue());
    var_dump($values["list"]->getTagType(), count($values["list"]->getValue()), $values[123]->getValue()["inner"]->getValue());
}

$network = Nbt::write(new TreeRoot($root), Nbt::NETWORK);
[$first, $end] = Nbt::readAt($network . $network, Nbt::NETWORK, strlen($network));
var_dump($end === 2 * strlen($network), $first instanceof TreeRoot);
var_dump(count(Nbt::readMultiple($network . $network . $network, Nbt::NETWORK)));
var_dump(Nbt::writeMultiple([new TreeRoot($root), new TreeRoot($root)], Nbt::NETWORK) === $network . $network);

$headless = Nbt::writeHeadless($items, Nbt::BEDROCK);
echo bin2hex($headless), "\n";
var_dump(Nbt::readHeadless($headless, Nbt::BEDROCK, 9)->getValue()[1]->getValue());
[$list, $end] = Nbt::readHeadlessAt("xx" . $headless . "yy", Nbt::BEDROCK, 9, 2);
var_dump($list->getTagType(), $end === 2 + strlen($headless));
var_dump(Nbt::transcode(Nbt::write(new TreeRoot($root), Nbt::BEDROCK), Nbt::BEDROCK, Nbt::NETWORK) === $network);

foreach ([
    fn() => Nbt::write(new TreeRoot(new ListTag([new IntTag(1)], 8)), Nbt::BEDROCK),
    fn() => Nbt::write(new TreeRoot(new StringTag(str_repeat("a", 40000))), Nbt::BEDROCK),
    fn() => Nbt::read("\x0a\x00\x00\x01", Nbt::BEDROCK),
    fn() => Nbt::read(str_repeat("\x0a\x00\x00", 10) . str_repeat("\x00", 10), Nbt::BEDROCK, 0, 3),
    fn() => Nbt::writeMultiple([1], Nbt::BEDROCK),
] as $call) {
    try {
        $call();
        echo "accepted\n";
    } catch (Bedwire\NbtException $e) {
        echo $e->getMessage(), "\n";
    }
}
$cycle = new CompoundTag();
$cycle->setTag("self", $cycle);
try {
    Nbt::write(new TreeRoot($cycle), Nbt::BEDROCK);
} catch (Bedwire\NbtException $e) {
    echo $e->getMessage(), "\n";
}
?>
--EXPECT--
string(5) "level"
bool(true)
byte,short,long,float,double,string,bytes,ints,list,empty,123
int(-5)
bool(true)
bool(true)
array(2) {
  [0]=>
  int(1)
  [1]=>
  int(4294967295)
}
int(3)
int(2)
int(7)
string(5) "level"
bool(true)
byte,short,long,float,double,string,bytes,ints,list,empty,123
int(-5)
bool(true)
bool(true)
array(2) {
  [0]=>
  int(1)
  [1]=>
  int(4294967295)
}
int(3)
int(2)
int(7)
string(5) "level"
bool(true)
byte,short,long,float,double,string,bytes,ints,list,empty,123
int(-5)
bool(true)
bool(true)
array(2) {
  [0]=>
  int(1)
  [1]=>
  int(-1)
}
int(3)
int(2)
int(7)
bool(true)
bool(true)
int(3)
bool(true)
030200000001000000feffffff
int(-2)
int(3)
bool(true)
bool(true)
invalid NBT: TypeMismatch
invalid NBT: SizeLimitExceeded
invalid NBT: UnexpectedEndOfInput
invalid NBT: DepthLimitExceeded
expected a pocketmine\nbt\TreeRoot
tags nest deeper than 512 levels
