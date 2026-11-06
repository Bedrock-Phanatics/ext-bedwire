--TEST--
Servers start, stop idempotently and release everything when destroyed
--EXTENSIONS--
bedwire
--FILE--
<?php
require __DIR__ . '/server.inc';
const SERVER = ["max_sessions" => 4] + OPTIONS;

$server = new Bedwire\Server("127.0.0.1", 0, SERVER);
var_dump($server->isRunning());
$port = $server->getPort();
var_dump($port > 0);
$server->setStatus("phpt", "world", 4);

$server->stop(100);
$server->stop(100);
var_dump($server->isRunning());
var_dump($server->getPort() === $port);
var_dump($server->poll());
var_dump($server->send(1 << 16, "\x01"));

$again = new Bedwire\Server("127.0.0.1", $port, SERVER);
var_dump($again->getPort() === $port);
unset($again);

for ($i = 0; $i < 10; $i++) {
    $cycle = new Bedwire\Server("127.0.0.1", 0, ["max_sessions" => 2] + OPTIONS);
    if ($i % 2 === 0) {
        $cycle->stop(0);
    }
}
unset($cycle);
echo "cycles done\n";

?>
--EXPECT--
bool(true)
bool(true)
bool(false)
bool(true)
array(0) {
}
bool(false)
bool(true)
cycles done
