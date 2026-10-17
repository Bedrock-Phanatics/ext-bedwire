--TEST--
Raw prefixed datagrams are drained as events and answered with sendRaw
--EXTENSIONS--
bedwire
--FILE--
<?php
$server = new Bedwire\Server("127.0.0.1", 0, "MCPE;phpt;2193;1.0;0;10;1;w;Survival;1;19132;19133;", ["raw_prefixes" => ["\xfe\xfd"]]);
$client = stream_socket_client("udp://127.0.0.1:" . $server->getPort());
$local = stream_socket_get_name($client, false);
$localPort = (int) substr($local, strrpos($local, ":") + 1);

$start = hrtime(true);
var_dump($server->poll(16, 50));
var_dump((hrtime(true) - $start) / 1e6 >= 40);

for ($i = 0; $i < 3; $i++) {
    fwrite($client, "\xfe\xfdquery$i");
}
fwrite($client, "\x00\x00not-raw");

$events = [];
$deadline = microtime(true) + 5;
while (count($events) < 9 && microtime(true) < $deadline) {
    array_push($events, ...$server->poll(16, 100));
}
var_dump(count($events));
for ($i = 0; $i < count($events); $i += 3) {
    [$address, $port, $payload] = $events[$i + 2];
    var_dump($events[$i] === Bedwire\Server::EVENT_RAW, $events[$i + 1], $address, $port === $localPort, substr($payload, 2));
}

$server->sendRaw("127.0.0.1", $localPort, "reply");
stream_set_timeout($client, 5);
var_dump(fread($client, 64));
$server->stop(0);
?>
--EXPECT--
array(0) {
}
bool(true)
int(9)
bool(true)
int(0)
string(9) "127.0.0.1"
bool(true)
string(6) "query0"
bool(true)
int(0)
string(9) "127.0.0.1"
bool(true)
string(6) "query1"
bool(true)
int(0)
string(9) "127.0.0.1"
bool(true)
string(6) "query2"
string(5) "reply"
