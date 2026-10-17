--TEST--
Blocked addresses are dropped until unblocked
--EXTENSIONS--
bedwire
--FILE--
<?php
$server = new Bedwire\Server("127.0.0.1", 0, "MCPE;phpt;2193;1.0;0;10;1;w;Survival;1;19132;19133;", ["raw_prefixes" => ["\xfe\xfd"]]);
$client = stream_socket_client("udp://127.0.0.1:" . $server->getPort());

$server->blockAddress("127.0.0.1", 60);
usleep(50000);
fwrite($client, "\xfe\xfdblocked");
var_dump($server->poll(16, 200));

$server->unblockAddress("127.0.0.1");
usleep(50000);
fwrite($client, "\xfe\xfdallowed");
$events = [];
$deadline = microtime(true) + 5;
while (!$events && microtime(true) < $deadline) {
    $events = $server->poll(16, 100);
}
var_dump(substr($events[2][2], 2));
var_dump($server->getStatistics()["blocked_dropped"]);
$server->stop(0);
?>
--EXPECT--
array(0) {
}
string(7) "allowed"
int(1)
