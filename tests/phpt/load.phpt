--TEST--
Extension loads and exposes its classes and generated constants
--EXTENSIONS--
bedwire
--FILE--
<?php
var_dump(extension_loaded('bedwire'));
foreach (['Bedwire\Server', 'Bedwire\Protocol', 'Bedwire\PacketId', 'Bedwire\Nbt', 'Bedwire\Exception', 'Bedwire\BackpressureException', 'Bedwire\PacketException', 'Bedwire\NbtException'] as $class) {
    var_dump(class_exists($class));
}
var_dump(is_subclass_of('Bedwire\Exception', 'RuntimeException'));
var_dump(is_subclass_of('Bedwire\PacketException', 'Bedwire\Exception'));
var_dump(Bedwire\Server::EVENT_PACKET, Bedwire\Server::REASON_AUTHENTICATION, Bedwire\Nbt::NETWORK);
var_dump(Bedwire\PacketId::LOGIN, Bedwire\PacketId::TEXT, Bedwire\PacketId::PLAYER_AUTH_INPUT);
var_dump(is_int(Bedwire\Protocol::VERSION), is_string(Bedwire\Protocol::MINECRAFT_VERSION));
var_dump(count((new ReflectionClass('Bedwire\PacketId'))->getConstants()) > 200);
var_dump((new ReflectionClass('Bedwire\Server'))->isFinal());
foreach (['Bedwire\Nbt', 'Bedwire\Protocol'] as $class) {
    try {
        new $class();
    } catch (Error $e) {
        echo get_class($e), "\n";
    }
}
?>
--EXPECT--
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
int(3)
int(5)
int(2)
int(1)
int(9)
int(144)
bool(true)
bool(true)
bool(true)
bool(true)
Error
Error
