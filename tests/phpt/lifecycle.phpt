--TEST--
Servers start, stop idempotently and release everything when destroyed
--EXTENSIONS--
bedwire
--FILE--
<?php
const AD = "MCPE;phpt;2193;1.0;0;10;1;w;Survival;1;19132;19133;";

$server = new Bedwire\Server("127.0.0.1", 0, AD, ["max_sessions" => 4]);
var_dump($server->isRunning());
$port = $server->getPort();
var_dump($port > 0);

$server->stop(100);
$server->stop(100);
var_dump($server->isRunning());
var_dump($server->getPort() === $port);
var_dump($server->poll());
var_dump($server->send(1 << 16, "\x01"));
try {
    $server->setAdvertisement(AD);
} catch (Bedwire\Exception $e) {
    echo $e->getMessage(), "\n";
}

$again = new Bedwire\Server("127.0.0.1", $port, AD);
var_dump($again->getPort() === $port);
unset($again);

for ($i = 0; $i < 25; $i++) {
    $cycle = new Bedwire\Server("127.0.0.1", 0, AD, ["max_sessions" => 2]);
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
server is stopped
bool(true)
cycles done
