--TEST--
Unknown, stale and malformed session IDs are refused without side effects
--EXTENSIONS--
bedwire
--FILE--
<?php
$server = new Bedwire\Server("127.0.0.1", 0, ["authentication" => false]);
$text = Bedwire\Protocol::encode("text", [
    "localize" => false,
    "body" => ["message_only" => ["message_type" => 0, "message" => "hi"]],
    "senders_xuid" => "",
    "platform_id" => "",
]);
$results = [];
foreach ([0, 1, 1 << 16, (5 << 16) | 3, -1, PHP_INT_MAX, PHP_INT_MIN] as $id) {
    $results[] = $server->send($id, "\x01\x02");
    $results[] = $server->sendBatch($id, ["\x01", "\x02"]);
    $results[] = $server->sendPackets($id, [["text", Bedwire\Protocol::decode($text)]]);
    $results[] = $server->disconnect($id);
    $results[] = $server->acceptLogin($id, "der");
    $results[] = $server->sendRawBatch($id, "	");
    $results[] = $server->sendUnreliable($id, "");
}
var_dump(count($results), array_unique($results, SORT_REGULAR));
var_dump($server->poll(16, 20));
var_dump($server->getStatistics()["sessions"]);
$server->stop(0);
?>
--EXPECT--
int(49)
array(1) {
  [0]=>
  bool(false)
}
array(0) {
}
int(0)
