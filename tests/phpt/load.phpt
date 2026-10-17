--TEST--
Extension loads and exposes its classes
--EXTENSIONS--
bedwire
--FILE--
<?php
var_dump(extension_loaded('bedwire'));
foreach (['Bedwire\Server', 'Bedwire\Nbt', 'Bedwire\Exception', 'Bedwire\BackpressureException'] as $class) {
    var_dump(class_exists($class));
}
var_dump(is_subclass_of('Bedwire\Exception', 'RuntimeException'));
var_dump(is_subclass_of('Bedwire\BackpressureException', 'Bedwire\Exception'));
var_dump(Bedwire\Server::EVENT_PACKET, Bedwire\Server::REASON_SHUTDOWN, Bedwire\Nbt::NETWORK);
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
bool(true)
int(3)
int(4)
int(2)
bool(true)
Error
