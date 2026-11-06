--TEST--
Extension loads and exposes its classes and constants
--EXTENSIONS--
bedwire
--FILE--
<?php
var_dump(extension_loaded('bedwire'));
foreach (['Bedwire\Server', 'Bedwire\Nbt', 'Bedwire\Exception', 'Bedwire\BackpressureException', 'Bedwire\NbtException'] as $class) {
    var_dump(class_exists($class));
}
foreach (['Bedwire\Protocol', 'Bedwire\PacketId', 'Bedwire\PacketException'] as $class) {
    var_dump(class_exists($class));
}
var_dump(method_exists('Bedwire\Server', 'sendPackets'));
var_dump(is_subclass_of('Bedwire\Exception', 'RuntimeException'));
var_dump(Bedwire\Server::EVENT_PACKET, Bedwire\Server::REASON_AUTHENTICATION, Bedwire\Nbt::NETWORK);
var_dump((new ReflectionClass('Bedwire\Server'))->isFinal());
try {
    new Bedwire\Nbt();
} catch (Error $e) {
    echo get_class($e), "\n";
}
?>
--EXPECT--
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
bool(false)
bool(false)
bool(false)
bool(false)
bool(true)
int(3)
int(5)
int(2)
bool(true)
Error
